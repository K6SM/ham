;;; ham-rig-tests.el --- Tests for ham-rig.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 K6SM

;; This file is not part of GNU Emacs.

;;; Commentary:

;; No radio and no rigctld.  Replies are fed in as Hamlib writes them,
;; and capabilities as `\dump_caps' prints them, so the parsers and the
;; panels are exercised without anything being connected.
;;
;; The capability fixtures matter more than they look: everything the
;; controls panel shows is discovered from them, so a change in what
;; Hamlib reports shows up here as a failing test rather than as an
;; empty panel on somebody's radio.

;;; Code:

(require 'ert)
(require 'ham-rig)

(defun ham-rig-tests--response (lines &optional rc)
  "Build a response from LINES as `ham-rig--parse-response' would.
RC defaults to zero."
  (ham-rig--parse-response lines (or rc 0)))

(defmacro ham-rig-tests--with-caps (caps &rest body)
  "Run BODY with CAPS as the rig's reported capabilities.
CAPS is the text of a \\dump_caps reply."
  (declare (indent 1) (debug t))
  `(let* ((lines (split-string ,caps "\n"))
          (response (ham-rig-tests--response lines))
          (ham-rig--caps (ham-rig-response-alist response))
          (ham-rig--caps-raw lines)
          (ham-rig--levels (make-hash-table :test #'equal))
          (ham-rig--funcs (make-hash-table :test #'equal))
          (ham-rig-controls-exclude nil))
     ,@body))

(defconst ham-rig-tests--caps
  "Model name:\tFTDX-10
Mfg name:\tYaesu
Max IF-SHIFT: -10.0kHz/+10.0kHz
Preamp: 10dB 20dB
Attenuator: 6dB 12dB 18dB
AGC levels: 0=OFF 1=FAST 2=SLOW 3=AUTO
Get level: SWR(0..0/0) ALC(0..0/0) STRENGTH(0..0/0)
Set level: PREAMP(10..20/10) ATT(12..12/0) IF(-1200..1200/20) RFPOWER(0.05..1/0.01) AGC(0..0/0) MICGAIN(0..1/0.01) RF(0..1/0.00392157) METER(0..0/0)
Set functions: TUNER VOX NB
Extra levels:
\tROOFINGFILTER
\t\tType: COMBO
\t\tDefault:
\t\tLabel: Roofing filter
\t\tTooltip: Roofing filter
\t\tValues: 0=\"AUTO\" 1=\"12 kHz\" 2=\"3 kHz\" 3=\"500 Hz\"
\tCONTOUR
\t\tType: CHECKBUTTON
\t\tDefault:
\t\tLabel: Contour
\t\tTooltip: Contour on/off
\tCONTOUR_FREQ
\t\tType: NUMERIC
\t\tDefault:
\t\tLabel: Contour frequency
\t\tTooltip: Contour frequency
\t\tRange: 10.000000..3200.000000/1.000000
Get parameters:
Mode list: AM CW USB LSB RTTY FM CWR RTTYR
"
  "A \\dump_caps reply in the shape Hamlib prints one.
Trimmed to what the controls panel reads, and carrying the block of
extension levels that a Yaesu reports and a dummy rig does not.")


;;;; Response parsing

(ert-deftest ham-rig-test-labelled-values-become-an-alist ()
  "A \"Key: value\" line is readable by name."
  (let ((r (ham-rig-tests--response '("Frequency: 14074000"))))
    (should (equal (ham-rig--val r "Frequency") "14074000"))
    (should (= (ham-rig--num r "Frequency") 14074000))))

(ert-deftest ham-rig-test-key-matching-ignores-case ()
  "Label spelling varies between Hamlib versions; matching should not."
  (let ((r (ham-rig-tests--response '("Passband: 2400"))))
    (should (= (ham-rig--labelled-num r "passband") 2400))))

(ert-deftest ham-rig-test-a-bare-number-is-read-positionally ()
  "`l STRENGTH' answers with a number and no label at all."
  (let ((r (ham-rig-tests--response '("-30"))))
    (should (= (ham-rig--num r "STRENGTH") -30))))

(ert-deftest ham-rig-test-an-ambiguous-response-is-not-guessed-at ()
  "Several unlabelled values and no matching key is not a reading.

Guessing would reintroduce exactly the misattribution that extended
response mode exists to prevent."
  (let ((r (ham-rig-tests--response '("1" "2"))))
    (should-not (ham-rig--val r "Anything"))))

(ert-deftest ham-rig-test-mode-and-passband-are-both-read ()
  "`m' answers with two labelled lines and both are wanted."
  (let ((r (ham-rig-tests--response '("Mode: USB" "Passband: 2400"))))
    (should (equal (ham-rig--labelled-val r "Mode") "USB"))
    (should (= (ham-rig--labelled-num r "Passband") 2400))))


;;;; Controls discovered from the rig

(ert-deftest ham-rig-test-only-writable-levels-are-offered ()
  "The meters are readable and not settable, and stay out of the panel."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((names (mapcar #'ham-rig--control-name (ham-rig--control-list))))
      (should (member "RFPOWER" names))
      (should (member "MICGAIN" names))
      (dolist (meter '("SWR" "ALC" "STRENGTH"))
        (should-not (member meter names))))))

(ert-deftest ham-rig-test-functions-are-offered-as-switches ()
  "Every writable function becomes a switch."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((funcs (cl-remove-if-not
                  (lambda (c) (eq (ham-rig--control-kind c) 'func))
                  (ham-rig--control-list))))
      (should (equal (sort (mapcar #'ham-rig--control-name funcs) #'string<)
                     '("NB" "TUNER" "VOX"))))))

(ert-deftest ham-rig-test-excluded-controls-stay-out ()
  "`ham-rig-controls-exclude' removes a control by name."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((ham-rig-controls-exclude '("RFPOWER")))
      (should-not (member "RFPOWER"
                          (mapcar #'ham-rig--control-name
                                  (ham-rig--control-list)))))))

(ert-deftest ham-rig-test-preamp-and-attenuator-are-switch-positions ()
  "Hamlib describes them as a range and as a list; the list is truer.

A preamp is a switch, not a slider, and off is a position it has."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((preamp (ham-rig-tests--control "PREAMP"))
          (att (ham-rig-tests--control "ATT")))
      (should (equal (ham-rig--control-discrete-values preamp) '(0 10 20)))
      (should (equal (ham-rig--control-discrete-values att) '(0 6 12 18))))))

(defun ham-rig-tests--control (name)
  "Return the control called NAME from the current capabilities."
  (cl-find name (ham-rig--control-list)
           :key #'ham-rig--control-name :test #'equal))


;;;; AGC

(ert-deftest ham-rig-test-agc-settings-come-from-the-rig ()
  "The rig lists its own AGC positions and what to call them."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (should (equal (ham-rig--agc-settings)
                   '((0 . "OFF") (1 . "FAST") (2 . "SLOW") (3 . "AUTO"))))))

(ert-deftest ham-rig-test-agc-is-offered-despite-its-empty-range ()
  "AGC arrives as 0..0/0 and is perfectly settable.

It takes one of a named set rather than a number, and dropping it as a
control with no usable range cost an AGC on every radio that has one."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((agc (ham-rig-tests--control "AGC")))
      (should agc)
      (should-not (ham-rig--control-degenerate-p agc))
      (should (equal (ham-rig--control-discrete-values agc) '(0 1 2 3)))
      (should (equal (ham-rig--control-value-label agc 2) "SLOW")))))

(ert-deftest ham-rig-test-a-level-with-no-range-and-no-positions-is-dropped ()
  "Something reported as 0..0/0 and described no other way cannot be set."
  (ham-rig-tests--with-caps "Set level: MYSTERY(0..0/0)\nGet parameters: \n"
    (should-not (ham-rig-tests--control "MYSTERY"))))

(ert-deftest ham-rig-test-a-single-valued-range-is-kept ()
  "An attenuator of 12..12 has one position, which is still a position."
  (ham-rig-tests--with-caps "Set level: ATT(12..12/0)\nGet parameters: \n"
    (should (ham-rig-tests--control "ATT"))))


;;;; Extension levels

(ert-deftest ham-rig-test-extension-levels-are-read ()
  "Hamlib's standard levels are not all of them.

The backend's own live under \"Extra levels\", and that is where a
roofing filter and a contour are: reading only \"Set level\" left every
one of them invisible."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((names (mapcar #'ham-rig--control-name (ham-rig--ext-levels))))
      (should (equal names '("ROOFINGFILTER" "CONTOUR" "CONTOUR_FREQ"))))))

(ert-deftest ham-rig-test-a-combo-carries-its-positions-and-their-names ()
  "The rig says which filters are fitted and what they are called."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((roof (ham-rig-tests--control "ROOFINGFILTER")))
      (should roof)
      (should (eq (ham-rig--control-kind roof) 'ext))
      (should (equal (ham-rig--control-label roof) "Roofing filter"))
      (should (equal (ham-rig--control-discrete-values roof) '(0 1 2 3)))
      (should (equal (ham-rig--control-value-label roof 3) "500 Hz")))))

(ert-deftest ham-rig-test-a-checkbutton-reads-as-a-switch ()
  "An extension level with no range and no values is on or off."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((contour (ham-rig-tests--control "CONTOUR")))
      (should (equal (ham-rig--control-values contour) '((0 . "off") (1 . "on")))))))

(ert-deftest ham-rig-test-a-numeric-extension-level-keeps-its-range ()
  "A contour frequency is a number in hertz, with ends."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((freq (ham-rig-tests--control "CONTOUR_FREQ")))
      (should (= (ham-rig--control-min freq) 10))
      (should (= (ham-rig--control-max freq) 3200))
      (should (= (ham-rig--control-step freq) 1)))))

(ert-deftest ham-rig-test-the-parser-takes-lines-or-text ()
  "The reply arrives as a list of lines; a string is easier to write.

Expecting only a string is what made this throw on the first real
connection after it was written, because the fixture was a string and
the radio was not."
  (let* ((text (concat "Extra levels:\n\tKEYER\n\t\tType: CHECKBUTTON\n"
                       "\t\tLabel: Keyer\nGet parameters: \n"))
         (from-string (ham-rig--parse-ext-levels text))
         (from-lines (ham-rig--parse-ext-levels (split-string text "\n"))))
    (should (= (length from-string) 1))
    (should (equal (mapcar #'ham-rig--control-name from-string)
                   (mapcar #'ham-rig--control-name from-lines)))))

(ert-deftest ham-rig-test-no-extension-levels-is-not-an-error ()
  "Most backends declare none, and the block is then empty."
  (should-not (ham-rig--parse-ext-levels "Extra levels:\nGet parameters: \n"))
  (should-not (ham-rig--parse-ext-levels nil)))


;;;; Filter width

(ert-deftest ham-rig-test-width-is-a-range-not-a-short-list ()
  "The radio accepts any width and settles on the nearest it has.

Offering a handful of named filters hid every filter between them, and
the Yaesu backends declare RIG_FLT_ANY for SSB and CW -- Hamlib saying
in so many words that any width goes."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((ham-rig--state (make-hash-table :test #'eq)))
      (ham-rig--set 'mode "USB")
      (let ((width (ham-rig-tests--control "WIDTH")))
        (should width)
        (should (eq (ham-rig--control-kind width) 'width))
        ;; A range with a step, like RFPOWER, rather than a value list.
        (should-not (ham-rig--control-discrete-values width))
        (should (= (ham-rig--control-min width) 200))
        (should (= (ham-rig--control-max width) 4000))
        (should (= (ham-rig--control-usable-step width) 50))
        (should (ham-rig--control-integral-p width))))))

(ert-deftest ham-rig-test-width-follows-the-mode ()
  "CW is not tuned the way SSB is, and the range says so."
  (let ((ham-rig--state (make-hash-table :test #'eq))
        (ham-rig--caps nil))
    (ham-rig--set 'mode "CW")
    (should (equal (ham-rig-passband-range) '(50 3000 50)))
    (ham-rig--set 'mode "USB")
    (should (equal (ham-rig-passband-range) '(200 4000 50)))
    (ham-rig--set 'mode "FM")
    (should (equal (ham-rig-passband-range) '(9000 16000 1000)))))

(ert-deftest ham-rig-test-an-unknown-mode-still-has-a-range ()
  "A mode nobody listed is still a mode the operator is in."
  (let ((ham-rig--state (make-hash-table :test #'eq))
        (ham-rig--caps nil))
    (ham-rig--set 'mode "PKTFM")
    (should (ham-rig-passband-range))))

(ert-deftest ham-rig-test-a-reported-filter-list-widens-but-never-narrows ()
  "A backend naming three SSB filters names the common ones, not the only ones."
  (ham-rig-tests--with-caps
      "Set level: IF(-1200..1200/1)\nFilters: USB: 1800 2400 5000\nGet parameters: \n"
    (let ((ham-rig--state (make-hash-table :test #'eq)))
      (ham-rig--set 'mode "USB")
      (let ((range (ham-rig-passband-range)))
        ;; The reported 5000 pushes the top out; the reported 1800 does
        ;; not pull the bottom up from 200.
        (should (= (nth 0 range) 200))
        (should (= (nth 1 range) 5000))))))

(ert-deftest ham-rig-test-width-sits-before-if-shift ()
  "It is the knob next to IF shift on the radio, and goes there."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((ham-rig--state (make-hash-table :test #'eq)))
      (ham-rig--set 'mode "USB")
      (let* ((levels (cl-remove-if-not
                      (lambda (c) (memq (ham-rig--control-kind c)
                                        '(level width)))
                      (ham-rig--control-list)))
             (names (mapcar #'ham-rig--control-name levels)))
        (should (member "WIDTH" names))
        (should (= (1+ (cl-position "WIDTH" names :test #'equal))
                   (cl-position "IF" names :test #'equal)))))))

(ert-deftest ham-rig-test-width-without-if-shift-goes-last ()
  "A radio with no IF shift still gets a width."
  (ham-rig-tests--with-caps "Set level: RFPOWER(0..1/0.01)\nGet parameters: \n"
    (let ((ham-rig--state (make-hash-table :test #'eq)))
      (ham-rig--set 'mode "USB")
      (should (ham-rig-tests--control "WIDTH")))))

(ert-deftest ham-rig-test-no-mode-no-width ()
  "Before the rig has said what mode it is in there is nothing to offer."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((ham-rig--state (make-hash-table :test #'eq)))
      (should-not (ham-rig--width-control)))))


;;;; What value actually reaches the rig

;; Everything here is about the number sent, not the control offered.
;; The panel listed the preamp's three positions and the attenuator's
;; four for a long time while being unable to send most of them,
;; because nothing checked what a write turned into.

(ert-deftest ham-rig-test-a-switch-is-held-to-its-positions ()
  "And not to the range Hamlib declares for it.

For a switch those are different things.  An FTDX10 declares
PREAMP(10..20/10) while the preamp has three positions -- off, 10 dB
and 20 dB -- so the range does not contain off at all, and clamping to
it meant the preamp could be switched on and never back off."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((preamp (ham-rig-tests--control "PREAMP")))
      (should (equal (ham-rig--control-discrete-values preamp) '(0 10 20)))
      (should (= (ham-rig--acceptable-value preamp 0) 0))
      (should (= (ham-rig--acceptable-value preamp 10) 10))
      (should (= (ham-rig--acceptable-value preamp 20) 20)))))

(ert-deftest ham-rig-test-every-attenuator-position-can-be-sent ()
  "The FTDX10 declares ATT(12..12/0) and has four positions.

Clamped to that range every one of them became 12 dB: the panel showed
off, 6, 12 and 18 and sent 12 whichever was chosen."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((att (ham-rig-tests--control "ATT")))
      (should (equal (ham-rig--control-discrete-values att) '(0 6 12 18)))
      (dolist (position '(0 6 12 18))
        (should (= (ham-rig--acceptable-value att position) position))))))

(ert-deftest ham-rig-test-every-agc-setting-can-be-sent ()
  "AGC is declared 0..0 with its settings in a line of their own.

Clamped to that range every setting became zero, which is OFF -- so
asking for SLOW switched the AGC off instead, on a radio where that is
a real operating mistake."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((agc (ham-rig-tests--control "AGC")))
      (dolist (setting (ham-rig--control-discrete-values agc))
        (should (= (ham-rig--acceptable-value agc setting) setting))))))

(ert-deftest ham-rig-test-a-value-off-the-list-snaps-to-the-nearest ()
  "A typed value, or one left over from another radio, goes to the
position closest to it rather than being refused or sent as it is."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((att (ham-rig-tests--control "ATT")))
      (should (= (ham-rig--acceptable-value att 5) 6))
      (should (= (ham-rig--acceptable-value att 100) 18))
      (should (= (ham-rig--acceptable-value att -5) 0)))))

(ert-deftest ham-rig-test-a-level-with-a-real-range-is-still-clamped ()
  "The change is for switches.  A slider still may not be sent past
either end of itself."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((power (ham-rig-tests--control "RFPOWER")))
      (should (= (ham-rig--acceptable-value power 2.0) 1))
      (should (= (ham-rig--acceptable-value power 0.0) 0.05))
      (should (= (ham-rig--acceptable-value power 0.5) 0.5)))))

(ert-deftest ham-rig-test-a-range-that-says-nothing-clamps-nothing ()
  "Hamlib writes 0..0 for a level it knows the name of and nothing
else about.  Clamping to that sends zero for ever."
  (let ((control (ham-rig--control-create :kind 'level :name "MYSTERY"
                                          :min 0 :max 0 :step 0)))
    (should (= (ham-rig--acceptable-value control 42) 42))))


;;;; A step the eye can see

(ert-deftest ham-rig-test-a-normalised-level-steps-by-a-whole-percent ()
  "Hamlib reports the step of these as one 255th, because that is what
fits in the byte the radio is sent.  Four tenths of a percent rounds to
the number already on the screen, so the key appeared to do nothing on
a control that was working perfectly."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((rf (ham-rig-tests--control "RF")))
      (should (ham-rig--control-percent-p rf))
      (should (< (ham-rig--control-step rf) 0.005))
      (should (>= (ham-rig--control-usable-step rf) 0.01)))))

(ert-deftest ham-rig-test-one-press-changes-the-reading ()
  "Which is the whole point of the floor: a press that does not change
what is printed is a press that looks broken."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let* ((rf (ham-rig-tests--control "RF"))
           (from 0.5)
           (to (+ from (ham-rig--control-usable-step rf))))
      (should-not (equal (ham-rig--format-level rf from)
                         (ham-rig--format-level rf to))))))

(ert-deftest ham-rig-test-a-coarser-step-is-left-alone ()
  "The floor raises a step that is too fine; it does not lower one that
the rig asked for."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((power (ham-rig-tests--control "RFPOWER")))
      (should (= (ham-rig--control-usable-step power) 0.01)))))

(ert-deftest ham-rig-test-the-fixture-is-the-radio ()
  "The ranges here are an FTDX10's own, from `rigctl -m 1042 -u'.

They were the dummy backend's for a while -- PREAMP(0..0/0) and
ATT(0..0/0) -- and every test passed while the panel could not work the
preamp, because 0..0 clamps to the value these tests happened to ask
for.  A fixture that is not the radio proves nothing about the radio."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((preamp (ham-rig-tests--control "PREAMP"))
          (att (ham-rig-tests--control "ATT")))
      (should (= (ham-rig--control-min preamp) 10))
      (should (= (ham-rig--control-max preamp) 20))
      (should (= (ham-rig--control-min att) 12))
      (should (= (ham-rig--control-max att) 12)))))


;;;; How a reading is written out

(ert-deftest ham-rig-test-width-reads-in-hertz-and-kilohertz ()
  "500 and 2.4 k are how a radio marks its filters."
  (should (equal (ham-rig--format-hz 500) "500 Hz"))
  (should (equal (ham-rig--format-hz 2400) "2.4 kHz"))
  (should (equal (ham-rig--format-hz 3000) "3 kHz")))

(ert-deftest ham-rig-test-decibels-belong-to-the-preamp-and-attenuator ()
  "A stepped control is not automatically in decibels.

That branch was written for the preamp and the attenuator, and was
right until AGC, a roofing filter and a filter width joined them."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((att (ham-rig-tests--control "ATT"))
          (agc (ham-rig-tests--control "AGC"))
          (roof (ham-rig-tests--control "ROOFINGFILTER")))
      (should (equal (ham-rig--format-level att 12) "12 dB"))
      (should (equal (ham-rig--format-level att 0) "off"))
      ;; These carry their own words and never reach the decibel branch.
      (should (equal (ham-rig--format-level agc 1) "FAST"))
      (should (equal (ham-rig--format-level roof 2) "3 kHz")))))

(ert-deftest ham-rig-test-a-normalised-level-reads-as-a-percentage ()
  "Hamlib flattens a good many controls to zero through one."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((mic (ham-rig-tests--control "MICGAIN")))
      (should (ham-rig--control-percent-p mic))
      (should (equal (ham-rig--format-level mic 0.35) "35%")))))

(ert-deftest ham-rig-test-width-is-never-a-percentage ()
  "Its range starts well above one, but the kind settles it either way."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((ham-rig--state (make-hash-table :test #'eq)))
      (ham-rig--set 'mode "USB")
      (should-not (ham-rig--control-percent-p (ham-rig-tests--control "WIDTH"))))))


;;;; The panel

(ert-deftest ham-rig-test-status-line-opens-with-the-radio ()
  "The rig is named first, the way the controls panel names it."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((line (substring-no-properties (ham-rig--status-line))))
      (should (string-prefix-p "FTDX-10" line))
      (should (string-match-p "not connected" line)))))

(ert-deftest ham-rig-test-status-line-falls-back-before-caps-arrive ()
  "Until the rig describes itself there is no model to name."
  (let ((ham-rig--caps nil))
    (should (string-prefix-p "Rig" (substring-no-properties
                                    (ham-rig--status-line))))))

(ert-deftest ham-rig-test-status-line-carries-no-frequency-or-mode ()
  "Both are drawn in full a line below.

A reading shown twice in one small buffer is two things to keep in
step, and a chance for them to disagree."
  (let ((ham-rig--state (make-hash-table :test #'eq))
        (ham-rig--caps nil))
    (ham-rig--set 'frequency 14074000)
    (ham-rig--set 'mode "USB")
    (let ((line (substring-no-properties (ham-rig--status-line))))
      (should-not (string-match-p "14" line))
      (should-not (string-match-p "USB" line)))))

(ert-deftest ham-rig-test-the-controls-panel-has-three-sections ()
  "Standard levels, standard switches, and the backend's own."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((ham-rig--state (make-hash-table :test #'eq)))
      (ham-rig--set 'mode "USB")
      (let ((text (substring-no-properties (ham-rig--render-controls))))
        (should (string-match-p "LEVELS" text))
        (should (string-match-p "FUNCTIONS" text))
        (should (string-match-p "THIS RADIO" text))
        (should (string-match-p "Roofing filter" text))
        (should (string-match-p "Filter width" text))))))

(ert-deftest ham-rig-test-the-panel-draws-without-a-connection ()
  "Opening the panel before connecting must not signal."
  (let ((ham-rig--caps nil)
        (ham-rig--state (make-hash-table :test #'eq)))
    (should (stringp (ham-rig--render)))
    (should (stringp (ham-rig--render-controls)))))


;;;; The key list

(ert-deftest ham-rig-test-aliases-share-a-row ()
  "The page keys and the meta arrows do the same thing."
  (let* ((rows (ham-key-rows ham-rig-mode-map))
         (fast (assq 'ham-rig-tune-up-fast rows)))
    (should fast)
    (should (member "<prior>" (cdr fast)))
    (should (member "M-<up>" (cdr fast)))))

(ert-deftest ham-rig-test-the-keyless-list-is-worked-out ()
  "It was written by hand and had drifted.

Six of the eleven commands on it had keys, so the help offered
`M-x ham-rig-connect' to an operator who could have pressed `c'."
  (let ((keyless (ham-rig--keyless-commands)))
    (dolist (bound '(ham-rig-connect ham-rig-disconnect ham-rig-controls
                                     ham-rig-show-stats ham-rig-panic-unkey
                                     ham-rig-set-tuning-step
                                     ham-rig-show-capabilities))
      (should-not (memq bound keyless)))
    ;; And what it does list is reachable only by name.
    (should (memq 'ham-rig-power-on keyless))
    ;; A major mode and a menu are commands to Emacs, not to an operator.
    (should-not (memq 'ham-rig-mode keyless))
    (should-not (memq 'ham-rig-mode-menu keyless))))

(ert-deftest ham-rig-test-every-key-runs-a-real-command ()
  "A keymap entry pointing at nothing is a key that errors when pressed."
  (dolist (map (list ham-rig-mode-map ham-rig-controls-mode-map))
    (map-keymap (lambda (_event definition)
                  (when (symbolp definition)
                    (should (fboundp definition))))
                map)))

(ert-deftest ham-rig-test-width-has-a-key ()
  "The filter width is reachable from the panel."
  (should (eq (lookup-key ham-rig-mode-map "w") 'ham-rig-set-passband)))

(ert-deftest ham-rig-test-the-help-buffer-lists-both-panels ()
  "Both keymaps and the commands with no key."
  (save-window-excursion (ham-rig-help))
  (unwind-protect
      (with-current-buffer "*ham-rig-help*"
        (let ((text (substring-no-properties (buffer-string))))
          (should (string-match-p "Rig panel" text))
          (should (string-match-p "Controls panel" text))
          (should (string-match-p "Commands with no key" text))
          ;; The frequency prompt reads kHz, and used to claim hertz.
          (should (string-match-p "kHz" text))))
    (kill-buffer "*ham-rig-help*")))


;;;; Queue behaviour

(ert-deftest ham-rig-test-a-poll-is-dropped-when-the-queue-is-full ()
  "The next poll asks the same question a moment later.

Letting them pile up delays the operator's own commands behind stale
ones."
  (let ((ham-rig--queue nil)
        (ham-rig--inflight t)
        (ham-rig-max-queue 2))
    (ham-rig--enqueue "f" nil 'poll)
    (ham-rig--enqueue "m" nil 'poll)
    (ham-rig--enqueue "v" nil 'poll)
    (should (= (length ham-rig--queue) 2))))

(ert-deftest ham-rig-test-a-user-request-is-never-dropped ()
  "Backpressure falls on polls, not on what the operator asked for."
  (let ((ham-rig--queue nil)
        (ham-rig--inflight t)
        (ham-rig-max-queue 1))
    (ham-rig--enqueue "f" nil 'poll)
    (ham-rig--enqueue "F 14074000" nil 'user)
    (should (= (length ham-rig--queue) 2))))


;;;; A change the rig refuses

;; Hamlib 4.5.x sends an FTDX10 a broken RF gain command -- a NUL where
;; the VFO digit belongs -- and the radio refuses it.  rigctld said so
;; with RPRT -5, eight seconds later, and nothing was listening: the
;; panel showed the new value until the read-back brought the old one
;; home, which looked like the panel was broken.

(defmacro ham-rig-tests--with-link (&rest body)
  "Run BODY with a pretend rigctld link.
Everything sent is pushed onto `sent', newest first, and every message
onto `messages'.  Replies are fed in with `ham-rig--on-line'."
  (declare (indent 0) (debug t))
  `(let ((sent nil)
         (messages nil)
         (ham-rig--queue nil)
         (ham-rig--inflight nil)
         (ham-rig--resp-lines nil)
         (ham-rig--owed nil)
         (ham-rig--stats (ham-rig--fresh-stats))
         (ham-rig--control-failures (make-hash-table :test #'equal))
         (ham-rig--state (make-hash-table :test #'eq)))
     (cl-letf (((symbol-function 'ham-connection-live-p) (lambda (_) t))
               ((symbol-function 'ham-connection-send)
                (lambda (_ text) (push text sent) t))
               ((symbol-function 'ham-rig--schedule-redisplay) #'ignore)
               ((symbol-function 'ham-rig--schedule-controls-redisplay) #'ignore)
               ((symbol-function 'message)
                (lambda (format &rest args)
                  (push (apply #'format-message format args) messages))))
       ,@body)))

(defun ham-rig-tests--reply (&rest lines)
  "Feed LINES to the link as though rigctld had sent them."
  (mapc #'ham-rig--on-line lines))

(defun ham-rig-tests--give-up ()
  "Let the request in flight time out."
  (let ((ham-rig-request-timeout -1))
    (ham-rig--check-timeout)))

(ert-deftest ham-rig-test-a-refused-change-is-reported ()
  "RPRT -5 after a set means the rig did not change, and says why."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (ham-rig-tests--with-link
      (ham-rig--write-control (ham-rig-tests--control "RF") 0.5)
      (should (equal (car (last sent)) "+L RF 0.500000"))
      (ham-rig-tests--reply "set_level: RF 0.500000" "RPRT -5")
      (should (string-match-p "timed out"
                              (gethash "RF" ham-rig--control-failures)))
      (should (cl-some (lambda (m) (string-match-p "RF was not set to 50%" m))
                       messages)))))

(ert-deftest ham-rig-test-a-refused-function-is-reported ()
  "A switch the rig will not throw is reported the same way."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (ham-rig-tests--with-link
      (ham-rig--write-control (ham-rig-tests--control "TUNER") t)
      (ham-rig-tests--reply "set_func: TUNER 1" "RPRT -9")
      (should (string-match-p "rejected"
                              (gethash "TUNER" ham-rig--control-failures)))
      (should (cl-some (lambda (m) (string-match-p "was not set to on" m))
                       messages)))))

(ert-deftest ham-rig-test-a-change-that-works-clears-the-report ()
  "The note stays until the control is changed successfully."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (ham-rig-tests--with-link
      (puthash "RF" "timed out waiting for the rig (RPRT -5)"
               ham-rig--control-failures)
      (ham-rig--write-control (ham-rig-tests--control "RF") 0.5)
      (ham-rig-tests--reply "set_level: RF 0.500000" "RPRT 0")
      (should-not (gethash "RF" ham-rig--control-failures))
      (should-not messages))))

(ert-deftest ham-rig-test-a-late-refusal-is-still-reported ()
  "Hamlib retries a refused command for longer than we wait for it.

The answer to a change is the one most likely to arrive after the
request has been given up on, so it must not be thrown away with the
stale readings.  And since the read-back sent meanwhile cannot have
seen it, the control is read again."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (ham-rig-tests--with-link
      (ham-rig--write-control (ham-rig-tests--control "RF") 0.5)
      (ham-rig-tests--give-up)
      ;; The read-back went out in its place.
      (should (equal (car sent) "+l RF"))
      (should (= (length ham-rig--owed) 1))
      (ham-rig-tests--reply "set_level: RF 0.500000" "RPRT -5")
      (should (gethash "RF" ham-rig--control-failures))
      (should-not ham-rig--owed)
      ;; The read-back is answered, and another read is waiting.
      (ham-rig-tests--reply "get_level: RF" "1.000000" "RPRT 0")
      (should (= (gethash "RF" ham-rig--levels) 1.0))
      (should (equal (car sent) "+l RF"))
      (should (= (cl-count "+l RF" sent :test #'equal) 2)))))

(ert-deftest ham-rig-test-a-late-reading-is-still-thrown-away ()
  "Only a change has a use for its late answer.  A reading arriving
late is stale, and must neither reach its callback nor be taken for
the answer to the next request."
  (ham-rig-tests--with-link
    (let ((called nil))
      (ham-rig--enqueue "l RF" (lambda (_) (setq called t)))
      (ham-rig-tests--give-up)
      (should (= (length ham-rig--owed) 1))
      (ham-rig--enqueue "f" (lambda (r) (setq called (ham-rig--val r "Frequency"))))
      (ham-rig-tests--reply "get_level: RF" "1.000000" "RPRT 0")
      (should-not called)
      (ham-rig-tests--reply "get_freq:" "Frequency: 14074000" "RPRT 0")
      (should (equal called "14074000")))))

(ert-deftest ham-rig-test-a-panic-unkey-reply-is-still-discarded ()
  "The unkey sent past the queue owes a reply with nothing waiting
for it, and it is discarded in its turn."
  (ham-rig-tests--with-link
    (cl-letf (((symbol-function 'ham-rig--verify-unkey) #'ignore))
      (ham-rig--enqueue "l RF" #'ignore)
      (ham-rig-panic-unkey)
      (should (equal ham-rig--owed '(nil nil)))
      (ham-rig-tests--reply "RPRT 0" "RPRT 0")
      (should-not ham-rig--owed))))

(ert-deftest ham-rig-test-the-panel-shows-a-refused-change ()
  "On the control's own line, so it is not lost with the echo area."
  (ham-rig-tests--with-caps ham-rig-tests--caps
    (let ((ham-rig--control-failures (make-hash-table :test #'equal))
          (rf (ham-rig-tests--control "RF")))
      (should-not (string-match-p "not set" (ham-rig--render-control rf)))
      (puthash "RF" "timed out waiting for the rig (RPRT -5)"
               ham-rig--control-failures)
      (should (string-match-p "not set: timed out"
                              (ham-rig--render-control rf))))))

(ert-deftest ham-rig-test-return-codes-are-described ()
  "rigctld's numbers, in words."
  (should (string-match-p "timed out" (ham-rig--describe-rc -5)))
  (should (string-match-p "rejected" (ham-rig--describe-rc -9)))
  (should (string-match-p "not available" (ham-rig--describe-rc -11)))
  (should (equal (ham-rig--describe-rc -99) "error -99")))


;;;; The other VFO

(defconst ham-rig-tests--vfo-caps
  "Model name:\tFTDX-10
Has targetable VFO: Y
Targetable features: FREQ MODE TONE FUNC LEVEL RITXIT PTT MEM BANK
VFO list: VFOA VFOB MEM
Set level: RF(0..1/0.00392157)
"
  "Capabilities as Hamlib 4.7 prints them for an FTDX10.")

(defun ham-rig-tests--vfo-info (name hz mode)
  "Return rigctld's lines for `\\get_vfo_info NAME' at HZ in MODE."
  (list (concat "get_vfo_info: " name)
        (format "Freq: %d" hz) (concat "Mode: " mode)
        "Width: 1950" "Split: 0" "SatMode: 0"))

(ert-deftest ham-rig-test-the-other-vfo-is-the-one-not-in-use ()
  "B while on A, A while on B, and B before the rig has said."
  (ham-rig-tests--with-caps ham-rig-tests--vfo-caps
    (let ((ham-rig--state (make-hash-table :test #'eq)))
      (should (equal (ham-rig--other-vfo-name) "VFOB"))
      (ham-rig--set 'vfo "VFOA")
      (should (equal (ham-rig--other-vfo-name) "VFOB"))
      (ham-rig--set 'vfo "VFOB")
      (should (equal (ham-rig--other-vfo-name) "VFOA")))))

(ert-deftest ham-rig-test-the-other-vfo-is-spelt-the-rigs-way ()
  "Hamlib answers a name it does not know with the current VFO, so a rig
with two receivers must be asked for Sub, not VFOB."
  (ham-rig-tests--with-caps "VFO list: Main Sub MEM\n"
    (let ((ham-rig--state (make-hash-table :test #'eq)))
      (ham-rig--set 'vfo "Main")
      (should (equal (ham-rig--other-vfo-name) "Sub"))
      (ham-rig--set 'vfo "Sub")
      (should (equal (ham-rig--other-vfo-name) "Main")))))

(ert-deftest ham-rig-test-a-rig-with-one-vfo-has-no-other ()
  "Nothing to show, so nothing is asked for."
  (ham-rig-tests--with-caps "VFO list: VFOA MEM\nHas targetable VFO: Y\n"
    (let ((ham-rig--state (make-hash-table :test #'eq)))
      (should-not (ham-rig--other-vfo-name))
      (should-not (ham-rig--other-vfo-wanted-p))
      (should (equal (ham-rig--render-other-vfo) "")))))

(ert-deftest ham-rig-test-targetable-frequency-from-either-hamlib ()
  "4.6 and later list the features; 4.5 only says whether there are any."
  (ham-rig-tests--with-caps ham-rig-tests--vfo-caps
    (should (ham-rig--targetable-frequency-p)))
  (ham-rig-tests--with-caps "Has targetable VFO: Y\nTargetable features: MODE\n"
    (should-not (ham-rig--targetable-frequency-p)))
  (ham-rig-tests--with-caps "Has targetable VFO: Y\n"
    (should (ham-rig--targetable-frequency-p)))
  (ham-rig-tests--with-caps "Has targetable VFO: N\n"
    (should-not (ham-rig--targetable-frequency-p))))

(ert-deftest ham-rig-test-a-rig-that-must-switch-is-left-alone ()
  "Reading the other VFO on such a rig flips the radio to it and back
every second.  Only asking for it outright does that."
  (ham-rig-tests--with-caps "VFO list: VFOA VFOB\nHas targetable VFO: N\n"
    (let ((ham-rig--state (make-hash-table :test #'eq)))
      (let ((ham-rig-show-other-vfo 'auto))
        (should-not (ham-rig--other-vfo-wanted-p)))
      (let ((ham-rig-show-other-vfo t))
        (should (ham-rig--other-vfo-wanted-p)))))
  (ham-rig-tests--with-caps ham-rig-tests--vfo-caps
    (let ((ham-rig--state (make-hash-table :test #'eq))
          (ham-rig-show-other-vfo nil))
      (should-not (ham-rig--other-vfo-wanted-p)))))

(ert-deftest ham-rig-test-the-other-vfo-is-read-and-shown ()
  "Its frequency, band, name and mode, on a line of its own."
  (ham-rig-tests--with-caps ham-rig-tests--vfo-caps
    (let ((ham-rig--state (make-hash-table :test #'eq)))
      (ham-rig--set 'vfo "VFOA")
      (ham-rig--note-other-vfo
       "VFOB" (ham-rig-tests--response
               (ham-rig-tests--vfo-info "VFOB" 7074000 "USB")))
      (should (equal (ham-rig-other-vfo) '("VFOB" 7074000 "USB")))
      (let ((line (substring-no-properties (ham-rig--render-other-vfo))))
        (should (string-match-p "7\\.074\\.000" line))
        (should (string-match-p "40m" line))
        (should (string-match-p "VFOB USB" line))
        (should-not (string-match-p "TX" line))))))

(ert-deftest ham-rig-test-the-transmitting-vfo-is-marked-in-split ()
  "In split the other VFO is usually the one that transmits."
  (ham-rig-tests--with-caps ham-rig-tests--vfo-caps
    (let ((ham-rig--state (make-hash-table :test #'eq)))
      (ham-rig--set 'vfo "VFOA")
      (ham-rig--set 'split t)
      (ham-rig--set 'split-vfo "VFOB")
      (ham-rig--set 'other-vfo '("VFOB" 14025000 "CW"))
      (should (string-match-p "TX" (ham-rig--render-other-vfo))))))

(ert-deftest ham-rig-test-a-reading-for-the-wrong-vfo-is-not-shown ()
  "Just after a swap the stored reading is of the VFO now in use.  Shown
underneath, the main frequency would appear twice."
  (ham-rig-tests--with-caps ham-rig-tests--vfo-caps
    (let ((ham-rig--state (make-hash-table :test #'eq)))
      (ham-rig--set 'vfo "VFOB")
      (ham-rig--set 'other-vfo '("VFOB" 7074000 "USB"))
      (should-not (ham-rig-other-vfo))
      (should (string-match-p "---" (ham-rig--render-other-vfo))))))

(ert-deftest ham-rig-test-no-vfo-info-command-stops-the-asking ()
  "rigctld before 4.1 has no get_vfo_info.  A timeout, on the other
hand, is no reason to give up."
  (ham-rig-tests--with-caps ham-rig-tests--vfo-caps
    (let ((ham-rig--state (make-hash-table :test #'eq))
          (ham-rig--other-vfo-unavailable nil))
      (cl-letf (((symbol-function 'ham-rig--schedule-redisplay) #'ignore))
        (ham-rig--note-other-vfo "VFOB" (ham-rig-tests--response nil -5))
        (should (ham-rig--other-vfo-wanted-p))
        (ham-rig--note-other-vfo "VFOB" (ham-rig-tests--response nil -11))
        (should-not (ham-rig--other-vfo-wanted-p))))))

(ert-deftest ham-rig-test-the-poll-asks-for-the-vfo-the-rig-just-named ()
  "Swap VFOs at the radio and the next poll asks for the right one: the
question waits for the answer to `v' rather than going out beside it."
  (ham-rig-tests--with-caps ham-rig-tests--vfo-caps
    (ham-rig-tests--with-link
      (let ((ham-rig--other-vfo-unavailable nil))
        (ham-rig--set 'vfo "VFOA")
        (cl-letf (((symbol-function 'ham-rig--should-poll-p) (lambda () t))
                  ((symbol-function 'ham-rig--poll-controls) #'ignore))
          (ham-rig--poll-slow))
        (should-not (cl-find-if (lambda (s) (string-match-p "get_vfo_info" s))
                                sent))
        (ham-rig-tests--reply "get_mode:" "Mode: USB" "Passband: 1950" "RPRT 0")
        (ham-rig-tests--reply "get_vfo:" "VFO: VFOB" "RPRT 0")
        (ham-rig-tests--reply "get_split_vfo:" "Split: 0" "TX VFO: VFOA" "RPRT 0")
        (should (equal (car sent) "+\\get_vfo_info VFOA"))
        (apply #'ham-rig-tests--reply
               (append (ham-rig-tests--vfo-info "VFOA" 14074000 "USB")
                       '("RPRT 0")))
        (should (equal (ham-rig-other-vfo) '("VFOA" 14074000 "USB")))))))

(provide 'ham-rig-tests)
;;; ham-rig-tests.el ends here
