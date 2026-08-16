;;; ham-rig.el --- Transceiver control via rigctld -*- lexical-binding: t; -*-

;; Copyright (C) 2026 K6SM

;; Author: K6SM
;; Version: 0.1.2
;; Package-Requires: ((emacs "29.1") (ham "0.1.0"))
;; Keywords: comm, hardware
;; URL: https://github.com/K6SM/ham

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Control a transceiver from Emacs by speaking to Hamlib's `rigctld'
;; over TCP.
;;
;; The single arbiter rule: rigctld owns the serial port, and every
;; client -- this package, Fldigi, WSJT-X, your logger -- talks to
;; rigctld.  Never open the rig's serial port directly from Emacs; you
;; will lock out every other program on the station.
;;
;;     rigctld -m <model> -r /dev/ttyUSB0 -s 38400 -t 4532
;;
;; Find your model number with `rigctl -l'.  For development without
;; hardware, `rigctld -m 1' is Hamlib's dummy rig and this package
;; drives it happily.
;;
;; Because wfview provides rigctld emulation, pointing `ham-rig-port' at
;; wfview instead gets you LAN remote operation with audio handled by a
;; program qualified to handle audio.  Nothing here changes.
;;
;; Design notes:
;;
;; * No hardcoded rig model.  Capabilities are discovered at connect
;;   time via \dump_caps, so an FTDX10 and an IC-7300 are the same code
;;   path.
;;
;; * Extended response mode.  Commands are prefixed with `+', making
;;   replies self-describing and terminated by RPRT.  This eliminates
;;   the desync failure where one dropped reply silently misattributes
;;   every subsequent value.
;;
;; * One request in flight at a time, behind a bounded queue.  On
;;   localhost a round trip is well under a millisecond, so this costs
;;   nothing and removes a whole class of correlation bugs.  Poll
;;   requests are dropped under backpressure; user requests never are.
;;
;; * Polling is decoupled from redisplay.  The panel repaints only when
;;   a value actually changed, coalesced through an idle timer, and
;;   polling suspends entirely when nothing needs the data.
;;
;; Response formats, verified against Hamlib 4.5.5:
;;
;;   +f              get_freq:            Frequency: 145000000
;;   +t              get_ptt:             PTT: 0
;;   +m              get_mode:            Mode: USB / Passband: 2400
;;   +v              get_vfo:             VFO: VFOA
;;   +s              get_split_vfo:       Split: 0 / TX VFO: VFOA
;;   +l STRENGTH     get_level: STRENGTH  -48
;;   +\chk_vfo       (no echo)            ChkVFO: 0
;;   +\dump_caps     dump_caps:           Model name:<TAB>Dummy
;;
;; Three of those bite:
;;
;; * Levels answer with a bare number.  There is no "Level Value:"
;;   label, so `l STRENGTH', `l SWR' and `l ALC' are read positionally.
;;
;; * `\chk_vfo' is not terminated by RPRT.  It needs its own terminator
;;   or it holds the single in-flight slot until the request times out.
;;
;; * Hamlib does not echo back the VFO name that was set.  Ask for VFOB
;;   and a rig with two receivers reports Sub, so VFO identity is
;;   compared by side rather than by name.

;;; Code:

(require 'ham)
(require 'cl-lib)
(require 'subr-x)
(require 'text-property-search)

(defgroup ham-rig nil
  "Transceiver control through Hamlib rigctld."
  :group 'ham
  :prefix "ham-rig-")


;;;; Options

(defcustom ham-rig-host "localhost"
  "Host running rigctld."
  :type 'string
  :group 'ham-rig)

(defcustom ham-rig-port 4532
  "TCP port of rigctld."
  :type 'integer
  :group 'ham-rig)

(defcustom ham-rig-fast-interval 0.2
  "Seconds between fast tier polls: frequency, PTT, signal strength.
Below about 0.1 you are asking the serial link for more than it can
give and will only add latency."
  :type 'number
  :group 'ham-rig)

(defcustom ham-rig-slow-interval 1.0
  "Seconds between slow tier polls: mode, VFO, split, SWR, ALC."
  :type 'number
  :group 'ham-rig)

(defcustom ham-rig-request-timeout 2.0
  "Seconds before an unanswered request is abandoned."
  :type 'number
  :group 'ham-rig)

(defcustom ham-rig-max-queue 12
  "Maximum queued requests before poll requests are dropped."
  :type 'integer
  :group 'ham-rig)

(defcustom ham-rig-poll-when-hidden nil
  "When non-nil, keep polling even with no panel visible and no subscribers.
Leave this off.  The default already keeps polling whenever another
package has subscribed to rig events."
  :type 'boolean
  :group 'ham-rig)

(defcustom ham-rig-tx-timeout 180
  "Seconds after which a keyed transmitter is unkeyed automatically.
Set to nil to disable, though you should not.  This is a backstop
against a stuck PTT, not a substitute for the transceiver's own TX
timeout timer, which you should also enable."
  :type '(choice integer (const nil))
  :group 'ham-rig)

(defcustom ham-rig-smeter-width 22
  "Width in characters of the signal strength bar."
  :type 'integer
  :group 'ham-rig)

(defcustom ham-rig-buffer-name "*ham-rig*"
  "Name of the rig control panel buffer."
  :type 'string
  :group 'ham-rig)

(defcustom ham-rig-modes
  '("LSB" "USB" "CW" "CWR" "AM" "FM" "PKTLSB" "PKTUSB" "PKTFM" "RTTY" "RTTYR")
  "Fallback mode list, used when the rig reports none."
  :type '(repeat string)
  :group 'ham-rig)

(defcustom ham-rig-tuning-steps
  '(1 10 50 100 500 1000 2500 5000 10000 100000 1000000)
  "Tuning steps in Hz, smallest first, cycled through with left and right."
  :type '(repeat integer)
  :group 'ham-rig)

(defcustom ham-rig-default-tuning-step 1000
  "Tuning step in Hz selected at startup.
Rounded to the nearest entry of `ham-rig-tuning-steps'."
  :type 'integer
  :group 'ham-rig)

(defcustom ham-rig-controls-buffer-name "*ham-rig-controls*"
  "Name of the buffer listing the levels and functions the rig reports."
  :type 'string
  :group 'ham-rig)

(defcustom ham-rig-controls-poll-batch 4
  "How many controls to refresh on each slow poll.
Controls are refreshed round robin rather than all at once: a rig can
report forty writable controls, and a serial link cannot carry forty
extra requests a second on top of the frequency and meter polls."
  :type 'integer
  :group 'ham-rig)

(defcustom ham-rig-controls-exclude nil
  "Names of levels and functions to leave out of the controls panel."
  :type '(repeat string)
  :group 'ham-rig)

(defcustom ham-rig-controls-meter-width 10
  "Width in characters of the bar beside each level."
  :type 'integer
  :group 'ham-rig)

(defcustom ham-rig-tx-meters
  '(("RFPOWER_METER_WATTS" . "PWR")
    ("RFPOWER_METER" . "PWR")
    ("ALC" . "ALC")
    ("COMP_METER" . "COMP")
    ("SWR" . "SWR")
    ("VD_METER" . "VDD")
    ("ID_METER" . "ID"))
  "Meters to show while transmitting, as (HAMLIB-LEVEL . LABEL).

Only those the rig actually reports under \"Get level\" appear, so this
is a preference rather than a promise and the same setting suits any
radio.  Where a rig offers both, RFPOWER_METER_WATTS is shown in place
of the normalised RFPOWER_METER."
  :type '(alist :key-type string :value-type string)
  :group 'ham-rig)

(defcustom ham-rig-tx-meters-per-poll 2
  "How many transmit meters to read on each fast poll.
Read round robin, for the same reason the controls are: a handful of
extra requests several times a second is all a serial link has spare."
  :type 'integer
  :group 'ham-rig)

(defcustom ham-rig-meter-zones
  '(("SWR" (2.0 . ham-rig-meter-warn) (3.0 . ham-rig-meter-danger)))
  "Readings at which a meter changes colour, as (NAME (VALUE . FACE)...).

The bar is drawn in the face of the highest reading it has passed, so
SWR runs in the ordinary meter face to 2:1, amber from 2:1 to 3:1 and
red beyond.  Values are in the units the meter reads in."
  :type '(alist :key-type string
                :value-type (alist :key-type number :value-type face))
  :group 'ham-rig)

(defcustom ham-rig-meter-units
  '(("COMP_METER" "dB" 25.0)
    ("VD_METER" "V" 16.0)
    ("ID_METER" "A" 25.0))
  "Units to read a normalised meter in, as (NAME UNIT FULL-SCALE).

Hamlib reports several meters as a fraction of full scale without saying
what full scale is.  Compression is the one that matters: the radio
shows decibels, so the reading is multiplied by FULL-SCALE and labelled
UNIT.

FULL-SCALE is a property of the radio that Hamlib does not report, so
the default is an estimate.  A transceiver whose compression meter ends
somewhere other than 25 dB wants that number changed here; nothing else
in this package needs to know about it."
  :type '(alist :key-type string
                :value-type (list (string :tag "Unit")
                                  (number :tag "Full scale")))
  :group 'ham-rig)

(defcustom ham-rig-meters-without-value '("ALC")
  "Meters shown as a bar with no number beside it.
ALC by default: it is a relative indication, and the figure Hamlib
reports for it means nothing in particular."
  :type '(repeat string)
  :group 'ham-rig)

(defcustom ham-rig-control-labels nil
  "Display names for controls, as (HAMLIB-NAME . LABEL).
For example (\"NR\" . \"DNR\") for a radio whose front panel uses a
different word for the same control."
  :type '(alist :key-type string :value-type string)
  :group 'ham-rig)

(defcustom ham-rig-control-value-labels nil
  "Names for particular control values, as (HAMLIB-NAME (VALUE . LABEL)...).

For a Yaesu whose preamp positions are marked IPO, AMP1 and AMP2 rather
than by their gain:

    ((\"PREAMP\" (0 . \"IPO\") (10 . \"AMP1\") (20 . \"AMP2\")))

This is configuration rather than code on purpose: the values come from
the rig, and only the words for them are local to a model."
  :type '(alist :key-type string
                :value-type (alist :key-type number :value-type string))
  :group 'ham-rig)


;;;; Faces

(defface ham-rig-frequency
  '((t :inherit default :weight bold :height 1.4))
  "Face for the main frequency readout."
  :group 'ham-rig)

(defface ham-rig-label
  '((t :inherit shadow))
  "Face for field labels."
  :group 'ham-rig)

(defface ham-rig-tx
  '((t :inherit error :weight bold))
  "Face for transmit indication."
  :group 'ham-rig)

(defface ham-rig-rx
  '((t :inherit success))
  "Face for receive indication."
  :group 'ham-rig)

(defface ham-rig-meter
  '((t :inherit font-lock-keyword-face))
  "Face for the filled portion of meters."
  :group 'ham-rig)

(defface ham-rig-meter-warn
  '((((class color) (min-colors 88)) :foreground "goldenrod")
    (((class color)) :foreground "yellow")
    (t :inherit warning))
  "Face for the part of a meter that has reached a cautionary reading."
  :group 'ham-rig)

(defface ham-rig-meter-danger
  '((((class color) (min-colors 88)) :foreground "red")
    (((class color)) :foreground "red")
    (t :inherit error))
  "Face for the part of a meter that has reached a bad reading."
  :group 'ham-rig)


;;;; Event topics

(defconst ham-rig-topic-frequency 'ham-rig-frequency-changed
  "Published with the new frequency in Hz.")
(defconst ham-rig-topic-mode 'ham-rig-mode-changed
  "Published with the new mode string and passband in Hz.")
(defconst ham-rig-topic-ptt 'ham-rig-ptt-changed
  "Published with t or nil.")
(defconst ham-rig-topic-vfo 'ham-rig-vfo-changed
  "Published with the new VFO name.")
(defconst ham-rig-topic-split 'ham-rig-split-changed
  "Published with t or nil.")
(defconst ham-rig-topic-connection 'ham-rig-connection-changed
  "Published with a state symbol and an optional detail string.")


;;;; Internal state

(defvar ham-rig--connection nil)
(defvar ham-rig--state (make-hash-table :test #'eq))
(defvar ham-rig--caps nil
  "Alist of capability strings from \\dump_caps.")
(defvar ham-rig--vfo-mode nil
  "Non-nil if rigctld was started with -o and demands a VFO argument.")
(defvar ham-rig--queue nil)
(defvar ham-rig--inflight nil)
(defvar ham-rig--resp-lines nil)
(defvar ham-rig--dirty nil)
(defvar ham-rig--last-render nil)
(defvar ham-rig--fast-timer nil)
(defvar ham-rig--slow-timer nil)
(defvar ham-rig--redisplay-timer nil)
(defvar ham-rig--step-index nil
  "Index into `ham-rig-tuning-steps', or nil until first needed.")
(defvar ham-rig--levels (make-hash-table :test #'equal)
  "Cached level values, keyed by Hamlib level name.")
(defvar ham-rig--funcs (make-hash-table :test #'equal)
  "Cached function states, keyed by Hamlib function name.")
(defvar ham-rig--controls-dirty nil)
(defvar ham-rig--controls-cursor 0)
(defvar ham-rig--controls-last-render nil)
(defvar ham-rig--controls-redisplay-timer nil)
(defvar ham-rig--power-watts nil
  "Transmit power setting in watts, as converted by the rig.")
(defvar ham-rig--tx-meter-cursor 0)
(defvar ham-rig--tx-timer nil)
(defvar ham-rig--tx-started-at nil)
(defvar ham-rig--unkey-on-reconnect nil)
(defvar ham-rig--owed 0
  "How many replies are still owed for requests that timed out.")
(defun ham-rig--fresh-stats ()
  "Return a zeroed link statistics plist.
One definition, so that a caller building its own cannot leave out a
key and make an increment fail inside a process filter."
  (list :requests 0 :timeouts 0 :errors 0 :discarded 0
        :latency-sum 0.0 :latency-max 0.0))

(defvar ham-rig--stats (ham-rig--fresh-stats))

(cl-defstruct (ham-rig--request (:constructor ham-rig--request-create)
                                (:copier nil))
  command callback kind sent-at terminator)

(cl-defstruct (ham-rig-response (:constructor ham-rig--response-create)
                                (:copier nil))
  rc alist values raw)


;;;; Response parsing

(defun ham-rig--parse-response (lines rc)
  "Build a `ham-rig-response' from LINES with return code RC.

Lines of the form \"Key: value\" become alist entries and contribute
their value to the ordered value list.  Keys are trimmed, because
`\\dump_caps' indents continuation blocks with tabs.

Some responses carry no label at all.  `l STRENGTH' answers with a bare
number on a line of its own, so an unlabelled line contributes to the
ordered value list and nothing else.

The command echo that opens an extended response is discarded: real
labels are capitalised, echoes are the lowercase internal command name
such as \"get_freq\" or \"get_level\".

That distinction is case sensitive, so `case-fold-search' is bound off
here.  Left at its default of t, the lowercase character class matches
capitalised labels too and every value in the response is silently
thrown away."
  (let ((case-fold-search nil)
        alist values)
    (dolist (line lines)
      (if (string-match "\\`\\([^:]+\\): ?\\(.*\\)\\'" line)
          ;; Both groups are taken before either is trimmed: `string-trim'
          ;; matches internally and would clobber the match data.
          (let ((key (match-string 1 line))
                (val (match-string 2 line)))
            (setq key (string-trim key)
                  val (string-trim val))
            (unless (string-match-p "\\`[\\\\a-z_]" key)
              (push (cons key val) alist)
              (unless (string-empty-p val) (push val values))))
        (let ((v (string-trim line)))
          (unless (string-empty-p v) (push v values)))))
    (ham-rig--response-create :rc rc
                              :alist (nreverse alist)
                              :values (nreverse values)
                              :raw lines)))

(defun ham-rig--labelled-val (response &rest keys)
  "Return the value RESPONSE labels with the first matching of KEYS.

Unlike `ham-rig--val' this never falls back to an unlabelled value, and
so it is what every reading whose label Hamlib always sends should use.
PTT is the one that matters: a level or function reply is a bare number
on a line of its own, so were a stray one ever attributed to the PTT
poll it would be read as a value, and any value but the string \"0\" --
including the \"0.000000\" that an unset level answers with -- means
transmitting.  The panel would announce a transmission that is not
happening."
  (cl-loop for key in keys
           thereis (cdr (cl-assoc key (ham-rig-response-alist response)
                                  :test #'cl-equalp))))

(defun ham-rig--val (response &rest keys)
  "Return the value for the first of KEYS present in RESPONSE.
Key matching is case insensitive, which absorbs label differences
between Hamlib versions.

When no key matches, fall back to the sole unlabelled value, but only
when the response carries exactly one.  A response with several values
and no matching label is ambiguous, and guessing at it would reintroduce
exactly the misattribution that extended response mode exists to
prevent."
  (or (cl-loop for key in keys
               thereis (cdr (cl-assoc key (ham-rig-response-alist response)
                                      :test #'cl-equalp)))
      (let ((values (ham-rig-response-values response)))
        (and (null (cdr values)) (car values)))))

(defun ham-rig--num (response &rest keys)
  "Return the numeric value for the first of KEYS in RESPONSE, or nil."
  (let ((v (apply #'ham-rig--val response keys)))
    (and v (string-match-p "\\`-?[0-9.]+\\'" v) (string-to-number v))))

(defun ham-rig--labelled-num (response &rest keys)
  "Return the numeric value RESPONSE labels with one of KEYS, or nil.
Like `ham-rig--num' but never falls back to an unlabelled value."
  (let ((v (apply #'ham-rig--labelled-val response keys)))
    (and v (string-match-p "\\`-?[0-9.]+\\'" v) (string-to-number v))))


;;;; Request queue

(defun ham-rig--enqueue (command &optional callback kind terminator)
  "Queue COMMAND, calling CALLBACK with a `ham-rig-response'.
KIND is `poll' or `user'.  Poll requests are dropped when the queue is
backed up; user requests are always queued.

TERMINATOR is an optional regexp matching a line that ends the response
in place of RPRT.  It exists for `\\chk_vfo', which rigctld answers
without a trailing RPRT; without it that request would occupy the link
until it timed out, delaying everything queued behind it."
  (let ((kind (or kind 'user)))
    (if (and (eq kind 'poll)
             (>= (length ham-rig--queue) ham-rig-max-queue))
        (ham-log "ham-rig: dropped poll %s (queue full)" command)
      (setq ham-rig--queue
            (append ham-rig--queue
                    (list (ham-rig--request-create
                           :command command :callback callback :kind kind
                           :terminator terminator))))
      (ham-rig--pump))))

(defun ham-rig--enqueue-urgent (command &optional callback)
  "Queue COMMAND ahead of everything else waiting, calling CALLBACK.

Keying and unkeying go this way.  A dozen polls can be queued at any
moment, and on a serial link that is most of a second between pressing
the key and the transmitter coming up.  The request still goes through
the queue, so replies stay matched to their requests; it simply does not
wait its turn."
  (setq ham-rig--queue
        (cons (ham-rig--request-create
               :command command :callback callback :kind 'user)
              ham-rig--queue))
  (ham-rig--pump))

(defun ham-rig--pump ()
  "Send the next queued request if the link is idle."
  (when (and (null ham-rig--inflight)
             ham-rig--queue
             (ham-connection-live-p ham-rig--connection))
    (let* ((req (pop ham-rig--queue))
           (cmd (ham-rig--request-command req)))
      (setf (ham-rig--request-sent-at req) (float-time))
      (setq ham-rig--inflight req
            ham-rig--resp-lines nil)
      (cl-incf (plist-get ham-rig--stats :requests))
      (unless (ham-connection-send ham-rig--connection (concat "+" cmd))
        (setq ham-rig--inflight nil)))))

(defun ham-rig--check-timeout ()
  "Abandon the in-flight request if it has gone unanswered.

The abandoned reply is still coming: rigctld answers everything, in
order, so a request that is merely late arrives after we have given up
on it.  Note that its reply is still owed, so that it can be discarded
when it turns up rather than being read as the answer to whatever was
sent next.  Without this a slow reply silently shifts every later
reading by one, which reads a level or function value as a PTT state,
a frequency, or a mode."
  (when (and ham-rig--inflight
             (> (- (float-time) (ham-rig--request-sent-at ham-rig--inflight))
                ham-rig-request-timeout))
    (ham-log "ham-rig: timeout on %s" (ham-rig--request-command ham-rig--inflight))
    (cl-incf (plist-get ham-rig--stats :timeouts))
    (ham-rig--abandon-inflight)
    (ham-rig--pump)))

(defun ham-rig--abandon-inflight ()
  "Give up on the in-flight request, noting that its reply is still owed."
  (when ham-rig--inflight
    ;; A request with its own terminator may never produce an RPRT at
    ;; all, so there would be nothing to discard and counting it would
    ;; swallow the next reply instead.
    (unless (ham-rig--request-terminator ham-rig--inflight)
      (cl-incf ham-rig--owed))
    (setq ham-rig--inflight nil
          ham-rig--resp-lines nil)))

(defun ham-rig--complete (rc)
  "Finish the in-flight request with return code RC."
  (let ((req ham-rig--inflight)
        (lines (nreverse ham-rig--resp-lines)))
    (setq ham-rig--inflight nil
          ham-rig--resp-lines nil)
    (when req
      (let ((elapsed (- (float-time) (ham-rig--request-sent-at req))))
        (cl-incf (plist-get ham-rig--stats :latency-sum) elapsed)
        (when (> elapsed (plist-get ham-rig--stats :latency-max))
          (plist-put ham-rig--stats :latency-max elapsed)))
      (unless (zerop rc)
        (cl-incf (plist-get ham-rig--stats :errors))
        (ham-log "ham-rig: %s returned RPRT %d"
                 (ham-rig--request-command req) rc))
      (when (ham-rig--request-callback req)
        (with-demoted-errors "ham-rig: callback error: %S"
          (funcall (ham-rig--request-callback req)
                   (ham-rig--parse-response lines rc)))))
    (ham-rig--schedule-redisplay)
    (ham-rig--pump)))

(defun ham-rig--terminator-p (line)
  "Return non-nil if LINE ends the in-flight request in place of RPRT."
  (let ((terminator (and ham-rig--inflight
                         (ham-rig--request-terminator ham-rig--inflight))))
    (and terminator
         (let ((case-fold-search t))
           (string-match-p terminator line)))))

(defun ham-rig--on-line (line)
  "Accumulate LINE and complete the in-flight request when it ends.
A response ends at RPRT, or at the in-flight request's terminator for
the commands rigctld answers without one.

While replies are owed for requests that timed out, everything arriving
belongs to those and is thrown away, one whole response per RPRT, until
the stream has caught up with us again."
  (cond
   ((string-match "\\`RPRT \\(-?[0-9]+\\)" line)
    (if (> ham-rig--owed 0)
        (progn
          (cl-decf ham-rig--owed)
          (cl-incf (plist-get ham-rig--stats :discarded))
          (ham-log "ham-rig: discarded a late reply")
          (setq ham-rig--resp-lines nil))
      (ham-rig--complete (string-to-number (match-string 1 line)))))
   ((> ham-rig--owed 0) nil)
   ((ham-rig--terminator-p line)
    (push line ham-rig--resp-lines)
    (ham-rig--complete 0))
   (t (push line ham-rig--resp-lines))))


;;;; State with change detection

(defun ham-rig--set (key value)
  "Store VALUE for KEY, publishing an event only if it changed."
  (let ((old (gethash key ham-rig--state)))
    (unless (equal old value)
      (puthash key value ham-rig--state)
      (setq ham-rig--dirty t)
      (pcase key
        ('frequency (ham-publish ham-rig-topic-frequency value))
        ('mode (ham-publish ham-rig-topic-mode value
                            (gethash 'passband ham-rig--state)))
        ('vfo (ham-publish ham-rig-topic-vfo value))
        ('split (ham-publish ham-rig-topic-split value))
        ('ptt
         (ham-publish ham-rig-topic-ptt value)
         (if value (ham-rig--start-tx-watchdog) (ham-rig--cancel-tx-watchdog)))
        (_ nil)))))

(defun ham-rig-get (key)
  "Return the cached rig state for KEY."
  (gethash key ham-rig--state))

(defun ham-rig-frequency () "Return the current frequency in Hz, or nil."
       (ham-rig-get 'frequency))
(defun ham-rig-current-mode () "Return the current mode string, or nil."
       (ham-rig-get 'mode))
(defun ham-rig-ptt-p () "Return non-nil if the rig is transmitting."
       (ham-rig-get 'ptt))
(defun ham-rig-connected-p () "Return non-nil if rigctld is connected."
       (ham-connection-live-p ham-rig--connection))


;;;; Polling

(defun ham-rig--panel-visible-p ()
  "Return non-nil if the rig panel is displayed on some frame."
  (let ((buf (get-buffer ham-rig-buffer-name)))
    (and buf (get-buffer-window buf t) t)))

(defun ham-rig--should-poll-p ()
  "Return non-nil if anything actually needs fresh rig data.
Polling a rig nobody is looking at wastes serial bandwidth that other
station software could be using."
  (and (ham-connection-live-p ham-rig--connection)
       (or ham-rig-poll-when-hidden
           (ham-rig--panel-visible-p)
           (ham-rig--controls-visible-p)
           (ham-rig-ptt-p)
           (ham-has-subscribers-p ham-rig-topic-frequency)
           (ham-has-subscribers-p ham-rig-topic-ptt))))

(defun ham-rig--poll-fast ()
  "Poll frequency, PTT and signal strength."
  (ham-rig--check-timeout)
  (when (ham-rig--should-poll-p)
    (ham-rig--enqueue
     "f" (lambda (r) (when-let ((hz (ham-rig--labelled-num r "Frequency")))
                       (ham-rig--set 'frequency (round hz))))
     'poll)
    (ham-rig--enqueue
     "t" (lambda (r) (let ((v (ham-rig--labelled-val r "PTT")))
                       (ham-rig--set 'ptt (and v (not (equal v "0"))))))
     'poll)
    (if (ham-rig-ptt-p)
        (progn
          ;; The elapsed time is worked out as the panel is drawn, so
          ;; without this the clock stops whenever no reading changes.
          (setq ham-rig--dirty t)
          (ham-rig--schedule-redisplay)
          (ham-rig--poll-tx-meters))
      (ham-rig--enqueue
       "l STRENGTH"
       (lambda (r) (ham-rig--set 'strength (ham-rig--num r "Strength")))
       'poll))))

(defun ham-rig--poll-tx-meters ()
  "Read a couple of the transmit meters, round robin.

Reading every meter on every fast tick would be six extra requests five
times a second, which is more than a serial link has to give while it is
also carrying frequency and PTT."
  (let* ((meters (ham-rig--tx-meters))
         (total (length meters)))
    (when (> total 0)
      (dotimes (_ (min ham-rig-tx-meters-per-poll total))
        (let ((control (car (nth (mod ham-rig--tx-meter-cursor total) meters))))
          (cl-incf ham-rig--tx-meter-cursor)
          (ham-rig--read-control control 'poll))))))

(defun ham-rig--poll-slow ()
  "Poll mode, VFO, split and, while transmitting, SWR and ALC."
  (when (ham-rig--should-poll-p)
    (ham-rig--enqueue
     "m" (lambda (r)
           (ham-rig--set 'passband (ham-rig--labelled-num r "Passband"))
           (ham-rig--set 'mode (ham-rig--labelled-val r "Mode")))
     'poll)
    (ham-rig--enqueue
     "v" (lambda (r) (ham-rig--set 'vfo (ham-rig--labelled-val r "VFO")))
     'poll)
    (ham-rig--enqueue
     "s" (lambda (r)
           (ham-rig--set 'split-vfo (ham-rig--labelled-val r "TX VFO"))
           (let ((v (ham-rig--labelled-val r "Split")))
             (ham-rig--set 'split (and v (not (equal v "0"))))))
     'poll))
  (ham-rig--poll-controls))

(defun ham-rig--start-timers ()
  "Start the fast and slow poll timers."
  (ham-rig--stop-timers)
  (setq ham-rig--fast-timer
        (run-at-time ham-rig-fast-interval ham-rig-fast-interval
                     #'ham-rig--poll-fast)
        ham-rig--slow-timer
        (run-at-time ham-rig-slow-interval ham-rig-slow-interval
                     #'ham-rig--poll-slow)))

(defun ham-rig--stop-timers ()
  "Cancel the poll timers."
  (when ham-rig--fast-timer (cancel-timer ham-rig--fast-timer))
  (when ham-rig--slow-timer (cancel-timer ham-rig--slow-timer))
  (setq ham-rig--fast-timer nil ham-rig--slow-timer nil))


;;;; Transmit safety

(defun ham-rig--start-tx-watchdog ()
  "Arm the transmit timeout."
  (ham-rig--cancel-tx-watchdog)
  (setq ham-rig--tx-started-at (float-time))
  (when (and ham-rig-tx-timeout (> ham-rig-tx-timeout 0))
    (setq ham-rig--tx-timer
          (run-at-time ham-rig-tx-timeout nil #'ham-rig-panic-unkey))))

(defun ham-rig--cancel-tx-watchdog ()
  "Disarm the transmit timeout."
  (when ham-rig--tx-timer (cancel-timer ham-rig--tx-timer))
  (setq ham-rig--tx-timer nil ham-rig--tx-started-at nil))

;;;###autoload
(defun ham-rig-panic-unkey ()
  "Unkey the transmitter immediately, bypassing the request queue."
  (interactive)
  (setq ham-rig--queue nil)
  (ham-rig--cancel-tx-watchdog)
  (if (ham-connection-live-p ham-rig--connection)
      (progn
        ;; Sent past the queue on purpose, so an unkey never waits behind
        ;; anything.  That leaves two replies nobody is expecting, in
        ;; this order: whatever was already in flight, then the unkey's
        ;; own.  Both are owed, and discarding them in order is what
        ;; keeps the one after them from being read as an answer to the
        ;; wrong request.
        (ham-rig--abandon-inflight)
        (when (ham-connection-send ham-rig--connection "+T 0")
          (cl-incf ham-rig--owed))
        (message "ham-rig: unkeyed"))
    (setq ham-rig--unkey-on-reconnect t)
    (display-warning
     'ham-rig
     "Cannot unkey: rigctld is not connected. If the rig is still keyed,
unkey it at the front panel now. Enable the transceiver's own TX
timeout timer so that a lost control link cannot hold the rig in
transmit."
     :emergency)))

(defun ham-rig--kill-emacs-unkey ()
  "Unkey on exit.  Blocking briefly here is the correct trade."
  (when (and (ham-connection-live-p ham-rig--connection) (ham-rig-ptt-p))
    (ham-connection-send ham-rig--connection "+T 0")
    (accept-process-output (ham-connection-process ham-rig--connection) 0.5)))

(add-hook 'kill-emacs-hook #'ham-rig--kill-emacs-unkey)


;;;; Connection lifecycle

(defun ham-rig--on-status (state detail)
  "React to connection STATE with DETAIL."
  (ham-publish ham-rig-topic-connection state detail)
  (setq ham-rig--dirty t)
  (pcase state
    ('connected
     (setq ham-rig--inflight nil ham-rig--queue nil ham-rig--resp-lines nil
           ham-rig--owed 0)
     ;; Anything cached from a previous session describes a rig that may
     ;; no longer be the one on the other end of the port.
     (clrhash ham-rig--levels)
     (clrhash ham-rig--funcs)
     (setq ham-rig--controls-dirty t ham-rig--controls-last-render nil)
     (when (or ham-rig--unkey-on-reconnect (ham-rig-ptt-p))
       (setq ham-rig--unkey-on-reconnect nil)
       (ham-rig--enqueue "T 0"))
     (ham-rig--discover)
     (ham-rig--start-timers))
    ('disconnected
     (ham-rig--stop-timers)
     (setq ham-rig--inflight nil ham-rig--queue nil)
     (when (ham-rig-ptt-p)
       (ham-rig--cancel-tx-watchdog)
       (setq ham-rig--unkey-on-reconnect t)
       (display-warning
        'ham-rig
        "Control link lost while transmitting. The rig may still be keyed.
Check the front panel."
        :emergency))))
  (ham-rig--schedule-redisplay))

(defun ham-rig--chk-vfo-on-p (response)
  "Return non-nil if RESPONSE to \\chk_vfo reports VFO mode.
Hamlib labels this \"ChkVFO: 1\" in extended mode, but older releases
answer with a bare \"CHKVFO 1\", so read the trailing flag rather than
comparing the whole value."
  (let ((v (ham-rig--val response "ChkVFO" "Check VFO")))
    (and v (string-match "\\([01]\\)[ \t]*\\'" v)
         (equal (match-string 1 v) "1"))))

(defun ham-rig--discover ()
  "Query rigctld for VFO mode and rig capabilities."
  (ham-rig--enqueue
   "\\chk_vfo"
   (lambda (r)
     (setq ham-rig--vfo-mode (ham-rig--chk-vfo-on-p r))
     (when ham-rig--vfo-mode
       (display-warning
        'ham-rig
        "rigctld appears to be in VFO mode (started with -o). ham-rig
does not yet pass explicit VFO arguments. Restart rigctld without -o."
        :warning)))
   'user "\\`[ \t]*chk_?vfo")
  (ham-rig--enqueue
   "\\dump_caps"
   (lambda (r)
     (setq ham-rig--caps (ham-rig-response-alist r))
     (setq ham-rig--dirty t ham-rig--controls-dirty t)
     ;; The controls panel cannot know what to show until the rig has
     ;; described itself, so fill it as soon as it has.
     (when (and (ham-rig--controls-visible-p) (ham-rig-connected-p))
       (ham-rig-controls-refresh))
     (ham-log "ham-rig: model %s" (or (ham-rig--val r "Model name") "unknown")))))

;;;###autoload
(defun ham-rig-connect ()
  "Connect to rigctld."
  (interactive)
  (when ham-rig--connection (ham-connection-close ham-rig--connection))
  (setq ham-rig--connection
        (ham-connection-make :name "ham-rig"
                             :host ham-rig-host
                             :port ham-rig-port
                             :on-line #'ham-rig--on-line
                             :on-status #'ham-rig--on-status))
  (ham-connection-open ham-rig--connection)
  (message "ham-rig: connecting to %s:%d" ham-rig-host ham-rig-port))

(defun ham-rig-disconnect ()
  "Disconnect from rigctld."
  (interactive)
  (ham-rig--stop-timers)
  (ham-rig--cancel-tx-watchdog)
  (when ham-rig--connection (ham-connection-close ham-rig--connection))
  (setq ham-rig--connection nil ham-rig--queue nil ham-rig--inflight nil
        ham-rig--owed 0)
  (ham-rig--schedule-redisplay)
  (message "ham-rig: disconnected"))


;;;; Control commands

(defun ham-rig-set-frequency (hz)
  "Set the transceiver frequency to HZ.
Interactively, prompt.  Accepts 14074, 14.074 or 14.074.000."
  (interactive (list (ham-parse-frequency
                      (read-string "Frequency: " nil nil
                                   (when (ham-rig-frequency)
                                     (ham-format-frequency (ham-rig-frequency)))))))
  (ham-rig--enqueue (format "F %d" (round hz)))
  (ham-rig--enqueue "f" (lambda (r)
                          (when-let ((f (ham-rig--num r "Frequency")))
                            (ham-rig--set 'frequency (round f))))))

(defun ham-rig--enqueue-latest (match command &optional callback)
  "Queue COMMAND, first dropping any queued request that MATCH supersedes.

A queued request is superseded when its command is MATCH exactly, or
begins with MATCH followed by a space.  Requiring that space matters:
plain prefix matching would let \"l RFPOWER\" also discard a queued
\"l RFPOWER_METER\", which is a different reading entirely.

Adjusting a control generates a request per keypress and only the last
one matters.  A held-down key would otherwise pile up hundreds of sets
that the link has to work through long after the operator stopped."
  (let ((space (concat match " ")))
    (setq ham-rig--queue
          (cl-remove-if (lambda (request)
                          (let ((queued (ham-rig--request-command request)))
                            (or (equal queued match)
                                (string-prefix-p space queued))))
                        ham-rig--queue)))
  (ham-rig--enqueue command callback))

(defun ham-rig-tuning-step ()
  "Return the current tuning step in Hz."
  (unless ham-rig--step-index
    (setq ham-rig--step-index
          (or (cl-position ham-rig-default-tuning-step ham-rig-tuning-steps)
              (1- (length ham-rig-tuning-steps)))))
  (setq ham-rig--step-index
        (max 0 (min ham-rig--step-index (1- (length ham-rig-tuning-steps)))))
  (nth ham-rig--step-index ham-rig-tuning-steps))

(defun ham-rig-set-tuning-step (hz)
  "Set the tuning step to HZ, which must be in `ham-rig-tuning-steps'."
  (interactive
   (list (string-to-number
          (completing-read "Step (Hz): "
                           (mapcar #'number-to-string ham-rig-tuning-steps)
                           nil t))))
  (let ((index (cl-position hz ham-rig-tuning-steps)))
    (unless index (user-error "No such tuning step: %s" hz))
    (setq ham-rig--step-index index))
  (setq ham-rig--dirty t)
  (ham-rig--schedule-redisplay)
  (message "ham-rig: step %s Hz" (ham-rig-tuning-step)))

(defun ham-rig-step-larger ()
  "Select the next larger tuning step."
  (interactive)
  (ham-rig-tuning-step)
  (ham-rig-set-tuning-step
   (nth (min (1+ ham-rig--step-index) (1- (length ham-rig-tuning-steps)))
        ham-rig-tuning-steps)))

(defun ham-rig-step-smaller ()
  "Select the next smaller tuning step."
  (interactive)
  (ham-rig-tuning-step)
  (ham-rig-set-tuning-step
   (nth (max (1- ham-rig--step-index) 0) ham-rig-tuning-steps)))

(defun ham-rig-tune (multiplier)
  "Move the frequency by MULTIPLIER times the tuning step.

The displayed frequency moves at once rather than waiting for the next
poll, so that holding an arrow key feels like turning a knob.  The poll
that follows replaces it with whatever the rig actually settled on,
which is what corrects for a rig that quantises to its own step."
  (let ((current (ham-rig-frequency)))
    (unless current
      (user-error "Frequency unknown: not connected, or nothing read yet"))
    (unless (ham-rig-connected-p)
      (user-error "Not connected to rigctld"))
    (let ((target (max 0 (+ current (* multiplier (ham-rig-tuning-step))))))
      (ham-rig--set 'frequency target)
      (ham-rig--enqueue-latest "F" (format "F %d" target)))))

(defun ham-rig-tune-up ()
  "Move up one tuning step."
  (interactive)
  (ham-rig-tune 1))

(defun ham-rig-tune-down ()
  "Move down one tuning step."
  (interactive)
  (ham-rig-tune -1))

(defun ham-rig-tune-up-fast ()
  "Move up by ten times the tuning step."
  (interactive)
  (ham-rig-tune 10))

(defun ham-rig-tune-down-fast ()
  "Move down by ten times the tuning step."
  (interactive)
  (ham-rig-tune -10))

(defun ham-rig-set-mode (mode &optional passband)
  "Set the transceiver to MODE with optional PASSBAND in Hz."
  (interactive
   (list (completing-read "Mode: " (ham-rig--available-modes) nil t)))
  (ham-rig--enqueue (format "M %s %d" mode (or passband 0))))

(defun ham-rig--available-modes ()
  "Return the mode list reported by the rig, or the fallback list."
  (let ((s (cdr (cl-assoc "Mode list" ham-rig--caps :test #'cl-equalp))))
    (if (and s (not (string-empty-p s)))
        (split-string s "[ \t]+" t)
      ham-rig-modes)))

(defun ham-rig-set-band (band)
  "Move to BAND using `ham-band-default-frequencies'."
  (interactive
   (list (completing-read "Band: " (mapcar #'car ham-band-default-frequencies)
                          nil t)))
  (if-let ((hz (ham-band-default-frequency band)))
      (ham-rig-set-frequency hz)
    (user-error "No default frequency for band %s" band)))

(defun ham-rig--vfo-side (name)
  "Return `a', `b' or nil for the VFO called NAME.

Hamlib does not echo back the name that was set.  A rig with main and
sub receivers answers `v' with Main or Sub whichever way the VFO was
selected, so those have to be recognised as the same side as VFOA and
VFOB.  Comparing the reported name against the name we sent instead
leaves the toggle stuck on one VFO from the second press onwards."
  (let ((case-fold-search t))
    (cond
     ((null name) nil)
     ((string-match-p "\\`\\(vfo\\)?a\\'\\|\\`main" name) 'a)
     ((string-match-p "\\`\\(vfo\\)?b\\'\\|\\`sub" name) 'b))))

(defun ham-rig-toggle-vfo ()
  "Switch between VFO A and VFO B."
  (interactive)
  (let ((target (if (eq (ham-rig--vfo-side (ham-rig-get 'vfo)) 'b)
                    "VFOA" "VFOB")))
    (ham-rig--enqueue (format "V %s" target))
    (ham-rig--enqueue "v" (lambda (r) (ham-rig--set 'vfo (ham-rig--labelled-val r "VFO"))))))

(defun ham-rig-toggle-tuner ()
  "Switch the antenna tuner in or out.

Hamlib exposes the tuner as a function that is either on or off.  There
is no portable way to ask a rig to run a tuning cycle, so on a radio
that starts one from its own front panel you will still start it there."
  (interactive)
  (let ((tuner (cl-find "TUNER" (ham-rig--control-list)
                        :key #'ham-rig--control-name :test #'equal)))
    (unless tuner
      (user-error "This rig reports no tuner, or has not described itself yet"))
    (let ((on (not (eq (ham-rig--control-value tuner) t))))
      (ham-rig--write-control tuner on)
      (message "ham-rig: tuner %s" (if on "in" "out")))))

(defun ham-rig--vfo-ops ()
  "Return the VFO operations the rig reports."
  (split-string (or (ham-rig--caps-value "VFO Ops") "") "[ \t]+" t))

(defun ham-rig-tune-atu ()
  "Start the antenna tuner's tuning cycle.

Hamlib calls this the TUNE VFO operation.  The rig transmits a carrier
while it matches, so it is refused unless the rig reports the operation."
  (interactive)
  (unless (ham-rig-connected-p)
    (user-error "Not connected to rigctld"))
  (unless (member "TUNE" (ham-rig--vfo-ops))
    (user-error "This rig reports no tuning cycle"))
  (ham-rig--enqueue "G TUNE")
  (message "ham-rig: tuning cycle started; the rig will transmit"))

(defun ham-rig-power-state ()
  "Return the cached power state: t, nil, or `unknown'."
  (ham-rig-get 'power))

(defun ham-rig-read-power-state ()
  "Ask the rig whether it is switched on."
  (interactive)
  (ham-rig--enqueue
   "\\get_powerstat"
   (lambda (r)
     (let ((v (ham-rig--labelled-val r "Power Status")))
       (ham-rig--set 'power (cond ((null v) 'unknown)
                                  ((equal v "0") nil)
                                  (t t)))))))

(defun ham-rig-power-on ()
  "Switch the transceiver on."
  (interactive)
  (unless (ham-rig-connected-p)
    (user-error "Not connected to rigctld"))
  (ham-rig--enqueue "\\set_powerstat 1")
  (ham-rig-read-power-state)
  (message "ham-rig: powering on"))

(defun ham-rig-power-off ()
  "Switch the transceiver off, after confirming.

A rig that is off answers nothing, so the panel will go quiet and stay
that way until it is switched on again -- by `ham-rig-power-on' if the
rig still listens while off, and at the radio if it does not."
  (interactive)
  (unless (ham-rig-connected-p)
    (user-error "Not connected to rigctld"))
  (when (yes-or-no-p "Switch the transceiver off? ")
    (ham-rig--enqueue "\\set_powerstat 0")
    (ham-rig--set 'power nil)
    (message "ham-rig: powering off")))

(defun ham-rig-toggle-power ()
  "Switch the transceiver on, or off after confirming."
  (interactive)
  (if (eq (ham-rig-power-state) nil)
      (ham-rig-power-on)
    (ham-rig-power-off)))

(defun ham-rig-toggle-split ()
  "Toggle split operation."
  (interactive)
  (let ((on (if (ham-rig-get 'split) 0 1)))
    (ham-rig--enqueue (format "S %d VFOB" on))))

(defun ham-rig-toggle-ptt ()
  "Key or unkey the transmitter."
  (interactive)
  (if (ham-rig-ptt-p)
      (progn (ham-rig--enqueue-urgent "T 0") (ham-rig--set 'ptt nil))
    (unless (ham-rig-connected-p)
      (user-error "Not connected to rigctld"))
    (ham-rig--enqueue-urgent "T 1")
    (ham-rig--set 'ptt t)))

(defun ham-rig-refresh ()
  "Force an immediate poll of everything."
  (interactive)
  (ham-rig--poll-fast)
  (ham-rig--poll-slow)
  (setq ham-rig--dirty t ham-rig--last-render nil)
  (ham-rig--schedule-redisplay))

(defun ham-rig-show-capabilities ()
  "Display the capabilities reported by the rig."
  (interactive)
  (with-current-buffer (get-buffer-create "*ham-rig-caps*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (if (null ham-rig--caps)
          (insert "No capabilities recorded. Connect first.\n")
        (dolist (entry ham-rig--caps)
          (insert (format "%-40s %s\n" (car entry) (cdr entry)))))
      (goto-char (point-min)))
    (special-mode)
    (pop-to-buffer (current-buffer))))

(defun ham-rig-show-stats ()
  "Report link performance since connection."
  (interactive)
  (let ((n (plist-get ham-rig--stats :requests)))
    (message "ham-rig: %d requests, %d timeouts, %d discarded, %d errors, mean %.1f ms, max %.1f ms, queue %d"
             n
             (plist-get ham-rig--stats :timeouts)
             (plist-get ham-rig--stats :discarded)
             (plist-get ham-rig--stats :errors)
             (if (zerop n) 0.0 (* 1000 (/ (plist-get ham-rig--stats :latency-sum) n)))
             (* 1000 (plist-get ham-rig--stats :latency-max))
             (length ham-rig--queue))))


;;;; Rendering

(defconst ham-rig--partial-blocks ["" "▏" "▎" "▍" "▌" "▋" "▊" "▉"]
  "Eighth-cell block characters for smooth meters in a terminal.")

(defun ham-rig--zone-face (position zones)
  "Return the face for a bar cell at POSITION, given ZONES.
ZONES is a list of (FRACTION . FACE) in ascending order; the face of the
highest fraction the cell has passed wins."
  (or (cl-loop for (start . face) in (reverse zones)
               when (>= position start) return face)
      'ham-rig-meter))

(defun ham-rig--bar (fraction width &optional zones)
  "Return a bar of WIDTH characters filled to FRACTION, 0.0 to 1.0.
ZONES colours the filled part; see `ham-rig--zone-face'."
  (let* ((fraction (max 0.0 (min 1.0 (or fraction 0.0))))
         (unicode (ham-unicode-blocks-p))
         (exact (* fraction width))
         (full (floor exact))
         (part (floor (* 8 (- exact full))))
         (cells nil))
    (dotimes (i full)
      (push (propertize (string (if unicode ?█ ?#))
                        'face (ham-rig--zone-face (/ (+ i 0.5) width) zones))
            cells))
    (when (and unicode (> part 0))
      (push (propertize (aref ham-rig--partial-blocks part)
                        'face (ham-rig--zone-face (/ (+ full 0.5) width) zones))
            cells))
    (let ((used (+ full (if (and unicode (> part 0)) 1 0))))
      (concat (apply #'concat (nreverse cells))
              (propertize (make-string (max 0 (- width used))
                                       (if unicode ?░ ?.))
                          'face 'ham-rig-label)))))

(defun ham-rig--s-label (db)
  "Return an S-meter label for DB relative to S9."
  (cond
   ((null db) "--")
   ((< db 3) (format "S%d" (max 0 (+ 9 (floor db 6)))))
   (t (format "S9+%d" (* 10 (round db 10))))))

(defun ham-rig--meter-fraction (control value)
  "Return where VALUE sits along CONTROL's bar, 0.0 to 1.0, or nil.

Standing wave ratio gets a scale of its own, and it is the one meter
that needs it.  A ratio has no top: it runs from one to infinity, so a
linear bar between the numbers Hamlib reports would put a perfect match
somewhere in the middle and have no room left for a bad one.  Plotting
the reflection coefficient instead, which is what the markings on an SWR
meter follow, puts 1:1 hard left, 3:1 at the centre and an open or
shorted feedline at the right end."
  (when value
    (if (ham-rig--control-swr-p control)
        (let ((swr (max 1.0 value)))
          (/ (- swr 1.0) (+ swr 1.0)))
      (let* ((min (ham-rig--control-min control))
             (span (- (ham-rig--control-max control) min)))
        (and (> span 0) (/ (- value min) (float span)))))))

(defun ham-rig--control-swr-p (control)
  "Return non-nil if CONTROL is the standing wave ratio meter."
  (equal (ham-rig--control-name control) "SWR"))

(defun ham-rig--format-meter (control value)
  "Return VALUE as the reading beside CONTROL's bar, which may be nothing.
Some meters are shown as a bar alone; see `ham-rig-meters-without-value'."
  (let* ((name (ham-rig--control-name control))
         (unit (assoc name ham-rig-meter-units)))
    (cond
     ((member name ham-rig-meters-without-value) "")
     ((null value) "--")
     (unit
      ;; Hamlib reports a fraction of full scale; the radio shows a
      ;; number, so scale it back up.
      (let* ((min (ham-rig--control-min control))
             (span (- (ham-rig--control-max control) min))
             (fraction (if (> span 0) (/ (- value min) (float span)) 0)))
        (format "%d %s" (round (* fraction (nth 2 unit))) (nth 1 unit))))
     (t (ham-rig--format-level control value)))))

(defun ham-rig--meter-zones (control)
  "Return CONTROL's colour zones as (FRACTION . FACE), in bar coordinates."
  (delq nil
        (mapcar (lambda (zone)
                  (let ((fraction (ham-rig--meter-fraction control (car zone))))
                    (and fraction (cons fraction (cdr zone)))))
                (cdr (assoc (ham-rig--control-name control)
                            ham-rig-meter-zones)))))

(defun ham-rig--render-tx-meters ()
  "Return a bar for each transmit meter this rig has, one per line."
  (mapconcat
   (lambda (entry)
     (let* ((control (car entry))
            (label (cdr entry))
            (value (ham-rig--control-value control))
            (zones (ham-rig--meter-zones control)))
       (concat "\n  "
               (propertize (format "%-5s" label) 'face 'ham-rig-label)
               (ham-rig--bar (ham-rig--meter-fraction control value)
                             ham-rig-smeter-width zones)
               ;; A meter shown without a number leaves no trailing gap.
               (let ((reading (ham-rig--format-meter control value)))
                 (if (string-empty-p reading) "" (concat "  " reading))))))
   (ham-rig--tx-meters) ""))

(defun ham-rig--render ()
  "Return the panel contents as a string."
  (let* ((state (if ham-rig--connection
                    (ham-connection-state ham-rig--connection)
                  'disconnected))
         (freq (ham-rig-frequency))
         (band (and freq (ham-band-for-frequency freq)))
         (tx (ham-rig-ptt-p))
         (db (ham-rig-get 'strength))
         (model (cdr (cl-assoc "Model name" ham-rig--caps :test #'cl-equalp))))
    (concat
     "\n  "
     (if model (concat (propertize model 'face 'ham-rig-label) "   ") "")
     (propertize (symbol-name state)
                 'face (if (eq state 'connected) 'ham-rig-rx 'ham-rig-label))
     "   "
     (propertize (format "%s:%d" ham-rig-host ham-rig-port) 'face 'ham-rig-label)
     "\n\n  "
     (propertize (if freq (ham-format-frequency freq) "---.---.---")
                 'face 'ham-rig-frequency)
     "   " (propertize (or band "") 'face 'ham-rig-label)
     (propertize "   STEP " 'face 'ham-rig-label)
     (let ((step (ham-rig-tuning-step)))
       (if (>= step 1000)
           (format "%g k" (/ step 1000.0))
         (format "%d " step)))
     "\n\n  "
     (propertize "VFO " 'face 'ham-rig-label)
     (format "%-6s" (or (ham-rig-get 'vfo) "--"))
     (propertize "  MODE " 'face 'ham-rig-label)
     (format "%-8s" (or (ham-rig-current-mode) "--"))
     (propertize "  BW " 'face 'ham-rig-label)
     (format "%-7s" (if-let ((pb (ham-rig-get 'passband)))
                        (format "%d Hz" pb) "--"))
     (propertize "  SPLIT " 'face 'ham-rig-label)
     (if (ham-rig-get 'split)
         (format "%s" (or (ham-rig-get 'split-vfo) "on"))
       "off")
     "\n\n  "
     (if tx
         (concat (propertize "TX" 'face 'ham-rig-tx)
                 (if ham-rig--tx-started-at
                     (propertize (format "   %ds"
                                         (round (- (float-time)
                                                   ham-rig--tx-started-at)))
                                 'face 'ham-rig-tx)
                   "")
                 (ham-rig--render-tx-meters))
       (concat (propertize "RX" 'face 'ham-rig-rx)
               "  "
               (ham-rig--bar (and db (/ (+ db 54.0) 114.0)) ham-rig-smeter-width)
               "  "
               (format "%-6s" (ham-rig--s-label db))))
     "\n\n  "
     (propertize "up/dn tune  M-up/dn x10  l/r step  f freq  m mode  b band"
                 'face 'ham-rig-label)
     "\n  "
     (propertize "v vfo  s split  t ptt  T unkey  u tuner  A atu  C controls  ? keys"
                 'face 'ham-rig-label)
     "\n")))

(defun ham-rig--redisplay ()
  "Repaint the panel if it is visible and something changed."
  (setq ham-rig--redisplay-timer nil)
  (when (and ham-rig--dirty (ham-rig--panel-visible-p))
    (setq ham-rig--dirty nil)
    (let ((text (ham-rig--render)))
      (unless (equal text ham-rig--last-render)
        (setq ham-rig--last-render text)
        (with-current-buffer (get-buffer-create ham-rig-buffer-name)
          (let ((inhibit-read-only t)
                (line (line-number-at-pos)))
            (erase-buffer)
            (insert text)
            (goto-char (point-min))
            (forward-line (1- line))))))))

(defun ham-rig--schedule-redisplay ()
  "Coalesce repaints onto an idle timer."
  (unless ham-rig--redisplay-timer
    (setq ham-rig--redisplay-timer
          (run-with-idle-timer 0.05 nil #'ham-rig--redisplay))))


;;;; Controls discovered from the rig

;; Everything below is driven by what \dump_caps reports, so there is no
;; list of controls anywhere in this file.  Hamlib describes each level
;; as NAME(MIN..MAX/STEP), which is all a generic control needs, and
;; names the ones that can be written in a separate "Set level" line.  A
;; rig that offers a notch gets a notch; one that does not, does not.

(defconst ham-rig--level-regexp
  "\\([A-Z0-9_]+\\)(\\(-?[0-9]*\\.?[0-9]+\\)\\.\\.\\(-?[0-9]*\\.?[0-9]+\\)\
/\\(-?[0-9]*\\.?[0-9]+\\))"
  "Matches one Hamlib level description, as NAME(MIN..MAX/STEP).")

(cl-defstruct (ham-rig--control (:constructor ham-rig--control-create)
                                (:copier nil))
  kind name min max step)

(defun ham-rig--caps-value (&rest keys)
  "Return the capability string for the first of KEYS reported by the rig."
  (cl-loop for key in keys
           thereis (cdr (cl-assoc key ham-rig--caps :test #'cl-equalp))))

(defun ham-rig--parse-levels (string)
  "Return a list of `ham-rig--control' for the levels described in STRING."
  (let ((start 0) controls)
    (while (and string (string-match ham-rig--level-regexp string start))
      (push (ham-rig--control-create
             :kind 'level
             :name (match-string 1 string)
             :min (string-to-number (match-string 2 string))
             :max (string-to-number (match-string 3 string))
             :step (string-to-number (match-string 4 string)))
            controls)
      (setq start (match-end 0)))
    (nreverse controls)))

(defun ham-rig--parse-functions (string)
  "Return a list of `ham-rig--control' for the functions named in STRING."
  (mapcar (lambda (name)
            (ham-rig--control-create :kind 'func :name name))
          (and string (split-string string "[ \t]+" t))))

(defun ham-rig--control-list ()
  "Return every control this rig accepts, levels first then functions.

Only writable controls are offered.  Hamlib reports the meters -- signal
strength, SWR, ALC and the rest -- under \"Get level\" but not under
\"Set level\", which is exactly the distinction needed to keep read-only
readings out of a panel whose purpose is changing things."
  (let ((levels (ham-rig--parse-levels (ham-rig--caps-value "Set level")))
        (funcs (ham-rig--parse-functions
                (ham-rig--caps-value "Set functions" "Set func"))))
    (cl-remove-if (lambda (control)
                    (or (member (ham-rig--control-name control)
                                ham-rig-controls-exclude)
                        (ham-rig--control-degenerate-p control)))
                  (append levels funcs))))

(defun ham-rig--control-degenerate-p (control)
  "Return non-nil if CONTROL has no usable range and cannot be offered.

Hamlib writes a level it knows of but cannot describe as 0..0/0.  The
FTDX10 reports AGC that way: the rig certainly has one, but it takes
named settings rather than a number, so there is nothing here to slide.
Offering a control that can only ever be set to zero is worse than
leaving it out.  A single-valued range like ATT's 12..12 is different
and is kept."
  (and (eq (ham-rig--control-kind control) 'level)
       (= (ham-rig--control-min control) (ham-rig--control-max control))
       (zerop (ham-rig--control-max control))))

(defun ham-rig--readable-levels ()
  "Return the levels the rig can report, meters included."
  (ham-rig--parse-levels (ham-rig--caps-value "Get level")))

(defun ham-rig--tx-meters ()
  "Return the transmit meters this rig has, as (CONTROL . LABEL).

Built by intersecting `ham-rig-tx-meters' with what the rig says it can
read, so a radio without a drain-current meter simply does not show one.
A label is used once: a rig reporting both RFPOWER_METER_WATTS and
RFPOWER_METER would otherwise show power twice."
  (let ((readable (ham-rig--readable-levels))
        seen meters)
    (dolist (entry ham-rig-tx-meters (nreverse meters))
      (let ((control (cl-find (car entry) readable
                              :key #'ham-rig--control-name :test #'equal)))
        (when (and control (not (member (cdr entry) seen)))
          (push (cdr entry) seen)
          (push (cons control (cdr entry)) meters))))))

(defun ham-rig--control-label (control)
  "Return the name to show for CONTROL."
  (let ((name (ham-rig--control-name control)))
    (or (cdr (assoc name ham-rig-control-labels)) name)))

(defun ham-rig--control-discrete-values (control)
  "Return the discrete values CONTROL accepts, or nil if it is continuous.

Hamlib describes a preamp or attenuator twice over: as a level with a
range, and as a list of the switch positions the rig actually has.  The
list is the truer description -- a preamp is a switch, not a slider --
so it is used when it is there, with zero prepended for off."
  (let* ((name (ham-rig--control-name control))
         (line (cond ((equal name "PREAMP") (ham-rig--caps-value "Preamp"))
                     ((equal name "ATT") (ham-rig--caps-value "Attenuator")))))
    (when line
      (let ((values (cl-loop for token in (split-string line "[ \t]+" t)
                             when (string-match "\\`\\(-?[0-9.]+\\)" token)
                             collect (string-to-number (match-string 1 token)))))
        (when values (cons 0 (sort (delete 0 values) #'<)))))))

(defun ham-rig--control-value-label (control value)
  "Return a configured name for VALUE of CONTROL, or nil."
  (cdr (assoc value (cdr (assoc (ham-rig--control-name control)
                                ham-rig-control-value-labels)))))

(defun ham-rig--control-watts-p (control)
  "Return non-nil if CONTROL is a level whose unit is watts.
Hamlib marks such a level by naming it, RFPOWER_METER_WATTS being the
one a transceiver reports, so the suffix is the test rather than a list
of names."
  (string-suffix-p "_WATTS" (ham-rig--control-name control)))

(defun ham-rig--control-percent-p (control)
  "Return non-nil if CONTROL is one of Hamlib's normalised zero-to-one levels.
Hamlib reports a good many controls that way rather than in the units
printed on the radio, and a percentage at least reads as a proportion."
  (and (eq (ham-rig--control-kind control) 'level)
       (null (ham-rig--control-discrete-values control))
       (>= (ham-rig--control-min control) 0)
       (= (ham-rig--control-max control) 1)))

(defun ham-rig--control-usable-step (control)
  "Return a step for CONTROL that is safe to adjust by.
Hamlib reports a step of zero for some levels, which cannot be used as
an increment."
  (let ((step (ham-rig--control-step control))
        (span (- (or (ham-rig--control-max control) 0)
                 (or (ham-rig--control-min control) 0))))
    (cond
     ((and step (> step 0)) step)
     ((>= span 100) 1)
     ((> span 0) (/ span 100.0))
     (t 1))))

(defun ham-rig--whole-number-p (n)
  "Return non-nil if N has no fractional part.
`truncate' rather than `ftruncate', because Hamlib's ranges parse to
integers as often as to floats and `ftruncate' rejects integers."
  (and (numberp n) (= n (truncate n))))

(defun ham-rig--control-integral-p (control)
  "Return non-nil if CONTROL takes whole numbers only."
  (and (ham-rig--whole-number-p (ham-rig--control-usable-step control))
       (ham-rig--whole-number-p (ham-rig--control-min control))
       (ham-rig--whole-number-p (ham-rig--control-max control))))

(defun ham-rig--control-decimals (control)
  "Return how many decimal places CONTROL's value is worth showing."
  (if (ham-rig--control-integral-p control)
      0
    (min 2 (max 1 (ceiling (- (log (ham-rig--control-usable-step control) 10)))))))

(defun ham-rig--format-level (control value &optional endpoint)
  "Return VALUE formatted for CONTROL, in whatever unit suits it.

With ENDPOINT, format it as one end of the control's range rather than
as a reading.  The difference matters for transmit power: the reading is
the watts the rig converted for us, and printing that for the ends of
the range would label every one of them with the same figure."
  (cond
   ((null value) "--")
   ((and (not endpoint) (ham-rig--control-value-label control value)))
   ((and (not endpoint)
         (equal (ham-rig--control-name control) "RFPOWER")
         ham-rig--power-watts)
    (format "%d W" (round ham-rig--power-watts)))
   ((ham-rig--control-watts-p control) (format "%d W" (round value)))
   ((ham-rig--control-discrete-values control)
    (if (zerop value) "off" (format "%d dB" (round value))))
   ((ham-rig--control-percent-p control) (format "%d%%" (round (* 100 value))))
   ((ham-rig--control-integral-p control) (format "%d" (round value)))
   ;; Emacs `format' has no "%.*f": the precision has to be baked in.
   (t (format (format "%%.%df" (ham-rig--control-decimals control)) value))))

(defun ham-rig--convert-power-to-watts (value)
  "Ask the rig what VALUE of RFPOWER is in watts, and cache the answer.

Hamlib normalises transmit power to a fraction of maximum rather than
reporting watts, but it will convert on request, given the frequency and
mode the power applies at.  That conversion is the rig backend's, so
this reads in watts on any radio that supports it without knowing
anything about the radio."
  (let ((frequency (ham-rig-frequency))
        (mode (ham-rig-current-mode)))
    (when (and frequency mode)
      (ham-rig--enqueue-latest
       "2"
       (format "2 %f %d %s" value frequency mode)
       (lambda (r)
         (let ((mw (ham-rig--labelled-num r "Power mW")))
           (when mw
             (setq ham-rig--power-watts (/ mw 1000.0)
                   ham-rig--controls-dirty t))))))))

(defun ham-rig--control-value (control)
  "Return the cached value of CONTROL, or nil."
  (if (eq (ham-rig--control-kind control) 'func)
      (gethash (ham-rig--control-name control) ham-rig--funcs 'unknown)
    (gethash (ham-rig--control-name control) ham-rig--levels)))

(defun ham-rig--set-control-value (control value)
  "Cache VALUE for CONTROL, marking the panels dirty only if it changed.

Both panels: the transmit meters live in this cache and are drawn on the
main panel, so marking only the controls panel leaves the bars frozen
for the whole of a transmission."
  (let* ((func (eq (ham-rig--control-kind control) 'func))
         (table (if func ham-rig--funcs ham-rig--levels))
         (name (ham-rig--control-name control))
         (old (gethash name table 'none)))
    (unless (equal old value)
      (puthash name value table)
      (setq ham-rig--controls-dirty t
            ham-rig--dirty t)
      (ham-rig--schedule-controls-redisplay)
      (ham-rig--schedule-redisplay))))

(defun ham-rig--read-control (control &optional kind coalesce)
  "Queue a read of CONTROL.  KIND is passed to `ham-rig--enqueue'.
With COALESCE, supersede any read of the same control already queued."
  (let* ((name (ham-rig--control-name control))
         (func (eq (ham-rig--control-kind control) 'func))
         (command (format (if func "u %s" "l %s") name))
         (callback
          (if func
              (lambda (r)
                (let ((v (ham-rig--val r "Func" name)))
                  (ham-rig--set-control-value
                   control (cond ((null v) 'unknown)
                                 ((equal v "0") nil)
                                 (t t)))))
            (lambda (r)
              (let ((value (ham-rig--num r name)))
                (ham-rig--set-control-value control value)
                (when (and value (equal name "RFPOWER"))
                  (ham-rig--convert-power-to-watts value)))))))
    (if coalesce
        (ham-rig--enqueue-latest command command callback)
      (ham-rig--enqueue command callback kind))))

(defun ham-rig--write-control (control value)
  "Send VALUE for CONTROL, then read it back to see what the rig did."
  (unless (ham-rig-connected-p)
    (user-error "Not connected to rigctld"))
  (let ((name (ham-rig--control-name control)))
    (if (eq (ham-rig--control-kind control) 'func)
        (progn
          (ham-rig--set-control-value control (and value t))
          (ham-rig--enqueue-latest (format "U %s" name)
                                   (format "U %s %d" name (if value 1 0))))
      (let ((clamped (max (ham-rig--control-min control)
                          (min (ham-rig--control-max control) value))))
        (ham-rig--set-control-value control clamped)
        (ham-rig--enqueue-latest
         (format "L %s" name)
         (format "L %s %s" name
                 (if (ham-rig--control-integral-p control)
                     (format "%d" (round clamped))
                   (format "%f" clamped))))))
    ;; Read back what the rig actually accepted, coalesced so that
    ;; holding a key does not queue a confirmation per repeat.
    (ham-rig--read-control control nil t)))


;;;; Controls polling

(defun ham-rig--controls-visible-p ()
  "Return non-nil if the controls panel is displayed on some frame."
  (let ((buf (get-buffer ham-rig-controls-buffer-name)))
    (and buf (get-buffer-window buf t) t)))

(defun ham-rig--poll-controls ()
  "Refresh a few controls, round robin.

A rig can report forty writable controls.  Asking for all of them on
every slow tick would swamp a serial link that is also carrying the
frequency and meter polls, so each tick takes the next few and the panel
converges over a second or two."
  (when (and (ham-rig--controls-visible-p)
             (ham-rig-connected-p))
    (let* ((controls (ham-rig--control-list))
           (total (length controls)))
      (when (> total 0)
        (dotimes (_ (min ham-rig-controls-poll-batch total))
          (let ((control (nth (mod ham-rig--controls-cursor total) controls)))
            (cl-incf ham-rig--controls-cursor)
            (ham-rig--read-control control 'poll)))))))

(defun ham-rig-controls-refresh ()
  "Read every control from the rig now.

Requests go in as user requests rather than polls so that none are
dropped for backpressure: the round robin would take the better part of
ten seconds to fill a panel of forty controls, which is too long to
stare at a screen of dashes."
  (interactive)
  (unless (ham-rig-connected-p)
    (user-error "Not connected to rigctld"))
  (dolist (control (ham-rig--control-list))
    (ham-rig--read-control control))
  (setq ham-rig--controls-dirty t
        ham-rig--controls-last-render nil)
  (ham-rig--schedule-controls-redisplay))


;;;; Controls rendering

(defun ham-rig--control-at-point ()
  "Return the control described on the current line, or nil."
  (get-text-property (line-beginning-position) 'ham-rig-control))

(defun ham-rig--render-control (control)
  "Return the panel line for CONTROL."
  (let* ((value (ham-rig--control-value control))
         (line
          (if (eq (ham-rig--control-kind control) 'func)
              (concat
               (format "  %-14s " (ham-rig--control-label control))
               (pcase value
                 ('unknown (propertize "--" 'face 'ham-rig-label))
                 ('nil (propertize "off" 'face 'ham-rig-label))
                 (_ (propertize "on" 'face 'ham-rig-rx))))
            (let* ((discrete (ham-rig--control-discrete-values control))
                   (min (if discrete (car discrete) (ham-rig--control-min control)))
                   (max (if discrete (car (last discrete))
                          (ham-rig--control-max control)))
                   (span (- max min))
                   (fraction (and value (> span 0) (/ (- value min) (float span)))))
              (concat
               (format "  %-14s " (ham-rig--control-label control))
               (ham-rig--bar fraction ham-rig-controls-meter-width)
               " "
               (format "%-8s" (ham-rig--format-level control value))
               (propertize
                ;; A switch is described by its positions; anything else
                ;; by the two ends of its range.
                (if discrete
                    (mapconcat (lambda (v) (ham-rig--format-level control v))
                               discrete "/")
                  (format "%s..%s"
                          (ham-rig--format-level control min t)
                          (ham-rig--format-level control max t)))
                'face 'ham-rig-label))))))
    (propertize (concat line "\n") 'ham-rig-control control)))

(defun ham-rig--render-controls ()
  "Return the controls panel contents as a string."
  (let ((controls (ham-rig--control-list))
        (model (ham-rig--caps-value "Model name")))
    (if (null controls)
        (concat "\n  "
                (if (ham-rig-connected-p)
                    "Waiting for the rig to report its capabilities..."
                  "Not connected. M-x ham-rig-connect")
                "\n")
      (concat
       "\n  "
       (propertize (or model "rig") 'face 'ham-rig-label)
       (propertize "   controls" 'face 'ham-rig-label)
       "\n"
       (let ((levels (cl-remove-if-not
                      (lambda (c) (eq (ham-rig--control-kind c) 'level))
                      controls))
             (funcs (cl-remove-if-not
                     (lambda (c) (eq (ham-rig--control-kind c) 'func))
                     controls)))
         (concat
          (if levels
              (concat "\n  " (propertize "LEVELS" 'face 'ham-rig-label) "\n"
                      (mapconcat #'ham-rig--render-control levels ""))
            "")
          (if funcs
              (concat "\n  " (propertize "FUNCTIONS" 'face 'ham-rig-label) "\n"
                      (mapconcat #'ham-rig--render-control funcs ""))
            "")))
       "\n  "
       (propertize "l/r adjust  L/R x10  RET toggle or set  = value  g refresh  q quit"
                   'face 'ham-rig-label)
       "\n"))))

(defun ham-rig--controls-redisplay ()
  "Repaint the controls panel if it is visible and something changed."
  (setq ham-rig--controls-redisplay-timer nil)
  (when (and ham-rig--controls-dirty (ham-rig--controls-visible-p))
    (setq ham-rig--controls-dirty nil)
    (let ((text (ham-rig--render-controls)))
      (unless (equal text ham-rig--controls-last-render)
        (setq ham-rig--controls-last-render text)
        (with-current-buffer (get-buffer-create ham-rig-controls-buffer-name)
          (let* ((inhibit-read-only t)
                 (previous (ham-rig--control-at-point))
                 (column (current-column)))
            (erase-buffer)
            (insert text)
            (goto-char (point-min))
            ;; Return to the control the cursor was on rather than to a
            ;; line number, so a panel that gains a row underneath does
            ;; not move the selection out from under the operator.
            (when previous
              (let ((target (text-property-search-forward
                             'ham-rig-control previous
                             (lambda (want have)
                               (and have (equal (ham-rig--control-name want)
                                                (ham-rig--control-name have)))))))
                (if target
                    (goto-char (prop-match-beginning target))
                  (goto-char (point-min)))))
            (move-to-column column)))))))

(defun ham-rig--schedule-controls-redisplay ()
  "Coalesce controls repaints onto an idle timer."
  (unless ham-rig--controls-redisplay-timer
    (setq ham-rig--controls-redisplay-timer
          (run-with-idle-timer 0.05 nil #'ham-rig--controls-redisplay))))


;;;; Controls commands

(defun ham-rig--adjust-control-at-point (multiplier)
  "Adjust the control on the current line by MULTIPLIER times its step."
  (let ((control (ham-rig--control-at-point)))
    (unless control (user-error "No control on this line"))
    (if (eq (ham-rig--control-kind control) 'func)
        (ham-rig--write-control control (not (eq (ham-rig--control-value control) t)))
      (let ((value (ham-rig--control-value control))
            (discrete (ham-rig--control-discrete-values control)))
        (unless value
          (user-error "%s has not been read from the rig yet"
                      (ham-rig--control-name control)))
        (ham-rig--write-control
         control
         (if discrete
             ;; A switch moves to its next position rather than by an
             ;; amount, however many steps were asked for.
             (let ((index (or (cl-position value discrete :test #'=) 0)))
               (nth (max 0 (min (1- (length discrete))
                                (+ index (if (> multiplier 0) 1 -1))))
                    discrete))
           (+ value (* multiplier (ham-rig--control-usable-step control)))))))))

(defun ham-rig-control-increase ()
  "Increase the control on the current line, or toggle it if it is a switch."
  (interactive)
  (ham-rig--adjust-control-at-point 1))

(defun ham-rig-control-decrease ()
  "Decrease the control on the current line, or toggle it if it is a switch."
  (interactive)
  (ham-rig--adjust-control-at-point -1))

(defun ham-rig-control-increase-fast ()
  "Increase the control on the current line by ten times its step."
  (interactive)
  (ham-rig--adjust-control-at-point 10))

(defun ham-rig-control-decrease-fast ()
  "Decrease the control on the current line by ten times its step."
  (interactive)
  (ham-rig--adjust-control-at-point -10))

(defun ham-rig-control-set ()
  "Prompt for a value for the control on the current line."
  (interactive)
  (let ((control (ham-rig--control-at-point)))
    (unless control (user-error "No control on this line"))
    (if (eq (ham-rig--control-kind control) 'func)
        (ham-rig--write-control
         control (y-or-n-p (format "Turn %s on? " (ham-rig--control-name control))))
      (let* ((min (ham-rig--control-min control))
             (max (ham-rig--control-max control))
             (value (read-number
                     (format "%s (%s..%s): "
                             (ham-rig--control-name control)
                             (ham-rig--format-level control min)
                             (ham-rig--format-level control max))
                     (ham-rig--control-value control))))
        (ham-rig--write-control control value)))))

(defun ham-rig-control-toggle ()
  "Toggle a function, or prompt for a level, on the current line."
  (interactive)
  (let ((control (ham-rig--control-at-point)))
    (unless control (user-error "No control on this line"))
    (if (eq (ham-rig--control-kind control) 'func)
        (ham-rig--write-control control (not (eq (ham-rig--control-value control) t)))
      (ham-rig-control-set))))

(defvar-keymap ham-rig-controls-mode-map
  :doc "Keymap for `ham-rig-controls-mode'."
  "<right>" #'ham-rig-control-increase
  "<left>" #'ham-rig-control-decrease
  "M-<right>" #'ham-rig-control-increase-fast
  "M-<left>" #'ham-rig-control-decrease-fast
  "+" #'ham-rig-control-increase
  "-" #'ham-rig-control-decrease
  "RET" #'ham-rig-control-toggle
  "SPC" #'ham-rig-control-toggle
  "=" #'ham-rig-control-set
  "g" #'ham-rig-controls-refresh
  "?" #'ham-rig-help
  "h" #'ham-rig-help
  "L" #'ham-show-log)

(define-derived-mode ham-rig-controls-mode special-mode "Rig Controls"
  "Major mode for the rig's levels and functions."
  (setq-local truncate-lines t))

;;;###autoload
(defun ham-rig-controls ()
  "Open the panel of levels and functions the rig reports.

The list comes from the rig itself, so it shows what this radio can do
and nothing it cannot."
  (interactive)
  (let ((buf (get-buffer-create ham-rig-controls-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'ham-rig-controls-mode) (ham-rig-controls-mode)))
    (pop-to-buffer buf)
    (unless (ham-rig-connected-p) (ham-rig-connect))
    (setq ham-rig--controls-dirty t ham-rig--controls-last-render nil)
    (when (and (ham-rig-connected-p) ham-rig--caps)
      (ham-rig-controls-refresh))
    (ham-rig--controls-redisplay)))


;;;; Major mode

(defvar-keymap ham-rig-mode-map
  :doc "Keymap for `ham-rig-mode'."
  "<up>" #'ham-rig-tune-up
  "<down>" #'ham-rig-tune-down
  "M-<up>" #'ham-rig-tune-up-fast
  "M-<down>" #'ham-rig-tune-down-fast
  "<right>" #'ham-rig-step-larger
  "<left>" #'ham-rig-step-smaller
  "<prior>" #'ham-rig-tune-up-fast
  "<next>" #'ham-rig-tune-down-fast
  "." #'ham-rig-set-tuning-step
  "f" #'ham-rig-set-frequency
  "m" #'ham-rig-set-mode
  "b" #'ham-rig-set-band
  "v" #'ham-rig-toggle-vfo
  "s" #'ham-rig-toggle-split
  "t" #'ham-rig-toggle-ptt
  "T" #'ham-rig-panic-unkey
  "g" #'ham-rig-refresh
  "c" #'ham-rig-connect
  "d" #'ham-rig-disconnect
  "?" #'ham-rig-help
  "h" #'ham-rig-help
  "i" #'ham-rig-show-capabilities
  "u" #'ham-rig-toggle-tuner
  "A" #'ham-rig-tune-atu
  "P" #'ham-rig-toggle-power
  "C" #'ham-rig-controls
  "S" #'ham-rig-show-stats
  "L" #'ham-show-log)

(defun ham-rig--keymap-rows (keymap)
  "Return (KEY . SUMMARY) for every command bound in KEYMAP."
  (let (rows)
    (map-keymap
     (lambda (event definition)
       (when (commandp definition)
         (push (cons (key-description (vector event))
                     (let ((doc (documentation definition)))
                       (if doc (car (split-string doc "\n")) "")))
               rows)))
     keymap)
    ;; `map-keymap' walks in reverse insertion order, which is no order
    ;; at all to read a key list in.
    (sort rows (lambda (a b) (string-lessp (car a) (car b))))))

(defun ham-rig--insert-key-table (title keymap)
  "Insert a table of the bindings in KEYMAP under TITLE."
  (insert (propertize (concat title "\n") 'face 'bold))
  (dolist (row (ham-rig--keymap-rows keymap))
    (insert (format "  %-12s %s\n"
                    (propertize (car row) 'face 'ham-rig-meter)
                    (cdr row))))
  (insert "\n"))

;;;###autoload
(defun ham-rig-help ()
  "Show every key the rig panels bind."
  (interactive)
  (with-current-buffer (get-buffer-create "*ham-rig-help*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (ham-rig--insert-key-table "Rig panel" ham-rig-mode-map)
      (ham-rig--insert-key-table "Controls panel" ham-rig-controls-mode-map)
      (insert (propertize "Commands with no key\n" 'face 'bold))
      (dolist (command '(ham-rig ham-rig-controls ham-rig-connect
                                 ham-rig-disconnect ham-rig-power-on
                                 ham-rig-power-off ham-rig-read-power-state
                                 ham-rig-set-tuning-step ham-rig-show-stats
                                 ham-rig-show-capabilities ham-rig-panic-unkey))
        (insert (format "  %-28s %s\n"
                        (symbol-name command)
                        (let ((doc (documentation command)))
                          (if doc (car (split-string doc "\n")) "")))))
      (goto-char (point-min)))
    (special-mode)
    (pop-to-buffer (current-buffer))))

(define-derived-mode ham-rig-mode special-mode "Rig"
  "Major mode for the transceiver control panel."
  (setq-local cursor-type nil
              truncate-lines t))

;;;###autoload
(defun ham-rig ()
  "Open the transceiver control panel, connecting if necessary."
  (interactive)
  (let ((buf (get-buffer-create ham-rig-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'ham-rig-mode) (ham-rig-mode)))
    (pop-to-buffer buf)
    (unless (ham-rig-connected-p) (ham-rig-connect))
    (setq ham-rig--dirty t ham-rig--last-render nil)
    (ham-rig--redisplay)))

(provide 'ham-rig)
;;; ham-rig.el ends here
