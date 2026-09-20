;;; ham-spot.el --- Spots from clusters, reporters and activation programs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 K6SM

;; Author: K6SM
;; Version: 0.4.0
;; Package-Requires: ((emacs "29.1") (ham "0.7.0"))
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

;; Somebody, somewhere, is on the air.  Half a dozen networks will tell
;; you so, and they all say it differently: a DX cluster sends lines of
;; text down a socket, POTA and SOTA answer JSON over HTTPS, PSK
;; Reporter has its own query language, and a DXpedition is an
;; announcement rather than a report at all.
;;
;; What an operator does with any of them is the same.  Read the
;; frequency, decide whether it is worth the trouble, and turn the
;; radio to it.  So that is what this file is: one record, one list,
;; one panel, and one key that puts the radio on the spot under the
;; cursor.  The networks are back ends registered into it.
;;
;; A back end supplies two things: a way to start and stop whatever it
;; needs running, and a way to turn its answers into `ham-spot'
;; records.  It hands each one to `ham-spot-record'.  Everything after
;; that -- ageing, de-duplication, sorting, filtering, drawing, and the
;; radio -- happens here and is the same for all of them.
;;
;; `ham-dxcluster' is the first back end and the reference one.
;;
;; On Windows this needs nothing installed.  A DX cluster is usually
;; reached with telnet, which Windows has not shipped enabled in years,
;; but telnet to a cluster is a plain TCP socket carrying lines of
;; text, and `make-network-process' has been part of Emacs on every
;; platform for a very long time.  The programs that answer over HTTPS
;; go through `url.el' for the same reason.  Nothing here shells out.

;;; Code:

(require 'ham)
(require 'ham-rig)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup ham-spot nil
  "Spots from DX clusters and activation programs."
  :group 'ham
  :prefix "ham-spot-")


;;;; The record

(cl-defstruct (ham-spot (:constructor ham-spot-create)
                        (:copier nil))
  "One report that a station was heard on a frequency.

CALL is who was heard and SPOTTER is who heard them -- the two halves
every one of these networks has, whatever it calls them.  A park or
summit activation is the same shape: the activator is the call, and
the program and its REFERENCE say where they are sitting.

HZ is the frequency in hertz.  Spots arrive in kilohertz, which is how
an operator says a frequency, but the radio is tuned in hertz and a
number that changes units between here and there is a number that will
eventually be wrong by a factor of a thousand.

MODE is what the network said, or what the band plan suggests when it
said nothing, which is most of the time.  WHEN is an Emacs time."
  call spotter hz mode when source
  grid spotter-grid comment reference reference-name snr
  (extra nil))

(defun ham-spot-khz (spot)
  "Return SPOT's frequency in kilohertz."
  (/ (ham-spot-hz spot) 1000.0))

(defun ham-spot-band (spot)
  "Return the band SPOT falls in, or nil."
  (ham-band-for-frequency (ham-spot-hz spot)))

(defun ham-spot-age (spot)
  "Return how long ago SPOT was reported, in seconds."
  (max 0 (floor (float-time (time-subtract (current-time)
                                           (ham-spot-when spot))))))

(defun ham-spot-key (spot)
  "Return the key identifying SPOT as one particular report.

One station on one band.  Two spotters hearing the same operator a
minute apart are not two things to look at, and neither is the same
station drifting fifty hertz between reports, so the band rather than
the frequency is what counts.  Move to another band and that is news
again."
  (cons (upcase (or (ham-spot-call spot) ""))
        (or (ham-spot-band spot) (round (ham-spot-hz spot) 1000000))))


;;;; Feeds

;; A feed is one network; a spot's `source' slot names the feed it came
;; from.  Registering rather than listing them here means a back end is
;; a file that can simply be loaded, and one that is not loaded costs
;; nothing.

(cl-defstruct (ham-spot-feed (:constructor ham-spot-feed-create)
                             (:copier nil))
  "One network that reports spots.

NAME is the symbol the rest of this file knows it by, and the one a
spot carries as its source.  TITLE is what the operator sees.  START
and STOP are called with no arguments when the panel opens and closes.
LIVE-P reports whether it is working.  STATUS returns a short string
for the panel's top line.  REFRESH, when given, is called to ask for an
update now; a feed that is pushed to rather than polled may leave it
out."
  name title start stop live-p status refresh)

(defvar ham-spot--feeds (make-hash-table :test #'eq)
  "Registered feeds, keyed by name.")

(defun ham-spot-register-feed (feed)
  "Register FEED, replacing any of the same name."
  (puthash (ham-spot-feed-name feed) feed ham-spot--feeds)
  (ham-spot-feed-name feed))

(defun ham-spot-feed-named (name)
  "Return the feed called NAME, or nil."
  (gethash name ham-spot--feeds))

(defun ham-spot-feed-names ()
  "Return the names of every registered feed."
  (sort (hash-table-keys ham-spot--feeds)
        (lambda (a b) (string-lessp (symbol-name a) (symbol-name b)))))


;;;; The list

(defcustom ham-spot-max-age 60
  "Minutes after which a spot is dropped.

A spot is a claim that somebody was on a frequency, and it goes stale
quickly: an hour later it says only that the band was open then."
  :type 'integer
  :group 'ham-spot)

(defcustom ham-spot-max-spots 500
  "Most spots to keep, however recent.

A busy cluster with no filters can deliver a spot a second, and
redrawing a list that has grown without limit is the only way this
panel can become slow."
  :type 'integer
  :group 'ham-spot)

(defvar ham-spot--spots nil
  "Every spot currently held, newest last.

One list for every feed.  A panel showing a single feed filters this
rather than keeping a list of its own, so a spot is held once however
many panels are open and cannot go stale in one of them.")

(defvar ham-spot-topic-new 'ham-spot-new
  "Event published with each spot as it is recorded.")

(defvar ham-spot-topic-changed 'ham-spot-changed
  "Event published when the list changes in any way.")

(defun ham-spot-all ()
  "Return every spot held, newest last."
  ham-spot--spots)

(defun ham-spot-clear (&optional source)
  "Discard stored spots, or only those from SOURCE.

Used in a panel showing one feed, it clears that feed alone: the key
does what the panel it was pressed in is about, rather than reaching
over and emptying a cluster the operator cannot even see from here."
  (interactive (list (and (derived-mode-p 'ham-spots-mode)
                          (ham-spot--source))))
  (setq ham-spot--spots
        (if source
            (seq-remove (lambda (s) (eq (ham-spot-source s) source)) ham-spot--spots)
          nil))
  (ham-publish ham-spot-topic-changed)
  (ham-spot--schedule-redisplay))

(defun ham-spot--expired-p (spot &optional now)
  "Return non-nil if SPOT is older than `ham-spot-max-age'.
NOW is the moment to measure from, defaulting to this one."
  (> (float-time (time-subtract (or now (current-time)) (ham-spot-when spot)))
     (* 60 ham-spot-max-age)))

(defun ham-spot-expire (&optional now)
  "Drop spots past their age, and any beyond `ham-spot-max-spots'.
NOW is the moment to measure from.  Return how many were dropped."
  (let* ((before (length ham-spot--spots))
         (kept (seq-remove (lambda (s) (ham-spot--expired-p s now)) ham-spot--spots))
         (excess (- (length kept) ham-spot-max-spots)))
    (when (> excess 0)
      (setq kept (nthcdr excess kept)))
    (setq ham-spot--spots kept)
    (- before (length ham-spot--spots))))

(defun ham-spot-record (spot)
  "Add SPOT to the list, or update the report it supersedes.

Returns the spot if it was new or newer, and nil if it was a repeat of
something already held.  A back end calls this for everything it
receives and lets it decide, rather than trying to work out for itself
whether a report is worth passing on."
  (when (ham-spot--acceptable-p spot)
    (let* ((key (ham-spot-key spot))
           (existing (seq-find (lambda (s) (equal (ham-spot-key s) key))
                               ham-spot--spots)))
      (cond
       ((null existing)
        (setq ham-spot--spots (append ham-spot--spots (list spot)))
        ;; Trimmed after the spot is in rather than before, or the list
        ;; settles one over its limit for ever: every new arrival makes
        ;; room for itself and then adds itself to the space.
        (ham-spot-expire)
        (ham-publish ham-spot-topic-new spot)
        (ham-publish ham-spot-topic-changed)
        (ham-spot--schedule-redisplay)
        spot)
       ;; Same station, same band, and this report is the newer one: it
       ;; replaces rather than joins, so the list holds stations and not
       ;; the history of everyone who heard them.
       ((time-less-p (ham-spot-when existing) (ham-spot-when spot))
        (setq ham-spot--spots
              (append (delq existing ham-spot--spots) (list spot)))
        (ham-spot-expire)
        (ham-publish ham-spot-topic-changed)
        (ham-spot--schedule-redisplay)
        spot)
       (t nil)))))

(defun ham-spot-replace-feed (source spots)
  "Replace everything held from SOURCE with SPOTS.

The other way a feed delivers.  A cluster pushes one spot at a time and
each is news, so it calls `ham-spot-record\='.  A program with an API
answers with the whole current list every time it is asked, and there
the absences matter as much as the arrivals: an activator who has
finished is simply no longer in the answer, and merging would leave
them on the panel until they aged out.  Sixty minutes of a park that is
no longer being activated is worse than nothing, because it reads
exactly like one that is.

Returns how many spots were kept."
  (let ((kept (seq-filter #'ham-spot--acceptable-p spots)))
    (setq ham-spot--spots
          (append (seq-remove (lambda (s) (eq (ham-spot-source s) source))
                              ham-spot--spots)
                  ;; Oldest first, matching the order the list is held in,
                  ;; so the newest of a batch is the newest overall.
                  (sort kept (lambda (a b)
                               (time-less-p (ham-spot-when a)
                                            (ham-spot-when b))))))
    (ham-spot-expire)
    (ham-publish ham-spot-topic-changed)
    (ham-spot--schedule-redisplay)
    (length kept)))

(defun ham-spot-forget (source call)
  "Drop SOURCE's spots for CALL, and return how many went.

For a network that says when somebody has stopped.  Most do not: a spot
is only ever an assertion that a station was heard, and the panel works
out for itself when to stop believing it.  WWBOTA sends a spot marked
QRT when an activator packs up, which is better information than
waiting an hour for the last one to age out."
  (let* ((wanted (upcase (or call "")))
         (before (length ham-spot--spots)))
    (setq ham-spot--spots
          (seq-remove (lambda (spot)
                        (and (eq (ham-spot-source spot) source)
                             (equal (upcase (or (ham-spot-call spot) "")) wanted)))
                      ham-spot--spots))
    (let ((gone (- before (length ham-spot--spots))))
      (when (> gone 0)
        (ham-publish ham-spot-topic-changed)
        (ham-spot--schedule-redisplay))
      gone)))

(defun ham-spot--acceptable-p (spot)
  "Return non-nil if SPOT is worth holding at all."
  (and (ham-spot-p spot)
       (ham-spot-call spot)
       (not (string-empty-p (ham-spot-call spot)))
       (ham-spot-hz spot)
       (> (ham-spot-hz spot) 0)
       (ham-spot-when spot)
       ;; A frequency in no band at all is a misparse rather than a
       ;; rare allocation: the number landed in the wrong field, or the
       ;; units were kHz where hertz were meant.
       (ham-spot-band spot)
       (not (ham-spot--expired-p spot))))

(defun ham-spot-fill-mode (spot)
  "Give SPOT the mode its frequency implies, if it has none.  Return SPOT.

Most spots carry no mode.  A cluster line is a callsign and a
frequency, and the operator is expected to know that 14074 means FT8 --
which is exactly the sort of knowing a program can do."
  (when (or (null (ham-spot-mode spot))
            (string-empty-p (ham-spot-mode spot)))
    (setf (ham-spot-mode spot) (ham-mode-for-frequency (ham-spot-hz spot))))
  spot)


;;;; Polled feeds

;; A cluster pushes and a web service is asked.  The asking is the same
;; every time -- a timer, one request in flight at a time, the answer
;; replacing what that feed had -- so it lives here and a back end
;; supplies only the URL and the way to read one record.

(cl-defstruct (ham-spot-poller (:constructor ham-spot-poller-create)
                               (:copier nil))
  "The state of one feed that is polled rather than pushed to.

SOURCE names the feed.  URL is a function returning what to fetch.
PARSE turns the decoded JSON into a list of spots.  INTERVAL is
seconds between requests.  MINIMUM is the shortest interval the
service permits, which is not the same thing: it is a limit set by
somebody else and is enforced rather than merely defaulted."
  source url parse interval (minimum 60)
  timer in-flight last-attempt last-success last-error (count 0))

(defun ham-spot-poller-status (poller title)
  "Return a status line for POLLER, named TITLE."
  (cond
   ((ham-spot-poller-in-flight poller) (format "%s: fetching" title))
   ((ham-spot-poller-last-error poller)
    (format "%s: %s" title (ham-spot-poller-last-error poller)))
   ((ham-spot-poller-last-success poller)
    (format "%s: %d spots, %s ago" title (ham-spot-poller-count poller)
            (ham-spot--age-label
             (floor (float-time (time-subtract
                                 (current-time)
                                 (ham-spot-poller-last-success poller)))))))
   (t (format "%s: not read yet" title))))

(defun ham-spot-poller-due-p (poller)
  "Return non-nil if POLLER may ask again now.

The minimum is a rule of the service rather than a preference of ours,
so it is applied to a manual refresh as well.  A key that asks a public
API faster than it allows is a key that gets an address blocked."
  (let ((last (ham-spot-poller-last-attempt poller)))
    (and (not (ham-spot-poller-in-flight poller))
         (or (null last)
             (> (float-time (time-subtract (current-time) last))
                (ham-spot-poller-minimum poller))))))

(defun ham-spot-poller-fetch (poller &optional force)
  "Ask POLLER's service for the current list.
FORCE skips the interval but never the service's own minimum."
  (when (or force (ham-spot-poller-due-p poller))
    (if (not (ham-spot-poller-due-p poller))
        (message "ham-spot: %s allows one request every %d seconds"
                 (ham-spot-poller-source poller)
                 (ham-spot-poller-minimum poller))
      (setf (ham-spot-poller-in-flight poller) t
            (ham-spot-poller-last-attempt poller) (current-time))
      (ham-fetch-json
       (funcall (ham-spot-poller-url poller))
       (lambda (data error)
         (setf (ham-spot-poller-in-flight poller) nil)
         (if error
             (progn
               (setf (ham-spot-poller-last-error poller) error)
               (ham-spot--schedule-redisplay))
           (condition-case err
               (let ((spots (funcall (ham-spot-poller-parse poller) data)))
                 (setf (ham-spot-poller-last-error poller) nil
                       (ham-spot-poller-last-success poller) (current-time)
                       (ham-spot-poller-count poller)
                       (ham-spot-replace-feed (ham-spot-poller-source poller)
                                              spots)))
             (error
              (setf (ham-spot-poller-last-error poller)
                    (format "could not read the answer: %s"
                            (error-message-string err)))
              (ham-spot--schedule-redisplay)))))))))

(defun ham-spot-poller-start (poller)
  "Start POLLER, fetching now and then on its interval."
  (ham-spot-poller-stop poller)
  (setf (ham-spot-poller-timer poller)
        (run-at-time 0 (ham-spot-poller-interval poller)
                     (lambda () (ham-spot-poller-fetch poller)))))

(defun ham-spot-poller-stop (poller)
  "Stop POLLER."
  (when (ham-spot-poller-timer poller)
    (cancel-timer (ham-spot-poller-timer poller))
    (setf (ham-spot-poller-timer poller) nil)))

(defun ham-spot-poller-running-p (poller)
  "Return non-nil if POLLER has a timer armed."
  (and (ham-spot-poller-timer poller) t))


;;;; What one panel is showing

;; Every panel has its own view: which feed, which bands, which modes,
;; what it is sorted by.  Held per buffer rather than globally, so two
;; panels on screen are two independent things -- filtering the parks
;; to 20 metres has no business touching the cluster beside it.  The
;; settings below are the defaults a new panel starts from, not the
;; state it goes on using.

(defcustom ham-spot-sort 'age
  "How a new panel orders spots.

`age\=' puts the newest first, whatever feed it came from.  `frequency\='
groups them as they sit on the dial.  `call\=' and `source\=' are
alphabetical."
  :type '(choice (const :tag "Newest first" age)
                 (const :tag "By frequency" frequency)
                 (const :tag "By callsign" call)
                 (const :tag "By source" source))
  :group 'ham-spot)

(defcustom ham-spot-filter nil
  "A regexp a new panel requires every shown spot to match.

Matched against the callsign, the mode, the band, the spotter, the
reference and the comment together, so \"POTA\" or \"K-1\" or \"FT8\"
or \"20m\" all narrow the list to the obvious thing."
  :type '(choice (const :tag "Everything" nil) regexp)
  :group 'ham-spot)

(defcustom ham-spot-exclude nil
  "A regexp a new panel hides every matching spot for.

The other half of the filter, and the one that gets more use: a station
calling on the same frequency all evening, or a mode not being worked
today, is easier to name than everything else is."
  :type '(choice (const :tag "Nothing" nil) regexp)
  :group 'ham-spot)

(defcustom ham-spot-bands nil
  "Bands a new panel shows, or nil for all of them."
  :type '(choice (const :tag "All bands" nil) (repeat string))
  :group 'ham-spot)

(defcustom ham-spot-modes nil
  "Modes a new panel shows, or nil for all of them.

Names from `ham-spot-mode-groups\=' select a whole family, so \"SSB\"
covers USB and LSB as well.  Any other name matches only itself."
  :type '(choice (const :tag "All modes" nil) (repeat string))
  :group 'ham-spot)

(defcustom ham-spot-mode-groups
  '(("CW"    "CW" "CWR" "A1A")
    ("SSB"   "SSB" "USB" "LSB" "PHONE")
    ("PHONE" "SSB" "USB" "LSB" "AM" "FM")
    ("DATA"  "DATA" "DIGI" "FT8" "FT4" "JS8" "JT65" "JT9" "Q65" "RTTY"
     "PSK" "PSK31" "MFSK" "OLIVIA" "CONTESTIA" "WSPR" "PKTUSB" "PKTLSB")
    ("AM"    "AM")
    ("FM"    "FM")
    ("SSTV"  "SSTV"))
  "Families of mode, as (NAME MODE...).

An operator thinks in families -- phone and CW today, nothing digital
-- while a spot carries whatever its network happened to call the
mode.  Asking for SSB should find a spot marked USB, and asking for
DATA should find FT8; asking for FT8 should find only FT8.

A name that is not a family here matches itself and nothing else, so a
mode this list has never heard of is still selectable."
  :type '(alist :key-type string :value-type (repeat string))
  :group 'ham-spot)

(cl-defstruct (ham-spot-view (:constructor ham-spot-view-create)
                             (:copier ham-spot-view-copy))
  "What one panel is showing: its feed, its filters and its order.

SOURCE is the feed this panel is limited to, or nil for all of them.
AGE is how many minutes back to show, or nil for everything held."
  source text exclude bands modes (sort 'age) age)

(defvar-local ham-spot--view nil
  "This panel's view, or nil before one has been made.")

(defun ham-spot-default-view (&optional source)
  "Return the default view for a new panel showing SOURCE."
  (ham-spot-view-create :source source
                        :text ham-spot-filter
                        :exclude ham-spot-exclude
                        :bands ham-spot-bands
                        :modes ham-spot-modes
                        :sort ham-spot-sort))

(defun ham-spot-view ()
  "Return this buffer's view.

A panel owns its view and keeps it, which is what makes two panels
independent.  Anywhere else -- a caller asking what is visible, a
test -- there is nothing to own it, so a fresh default is built each
time and follows the settings as they stand rather than freezing them
at whatever they were the first time somebody asked."
  (if (derived-mode-p 'ham-spots-mode)
      (or ham-spot--view
          (setq ham-spot--view (ham-spot-default-view)))
    (ham-spot-default-view)))

(defun ham-spot--searchable (spot)
  "Return the text of SPOT that a filter regexp is matched against."
  (string-join
   (delq nil (list (ham-spot-call spot)
                   (ham-spot-mode spot)
                   (ham-spot-band spot)
                   (ham-spot-spotter spot)
                   (ham-spot-reference spot)
                   (ham-spot-reference-name spot)
                   (symbol-name (or (ham-spot-source spot) 'unknown))
                   (ham-spot-comment spot)))
   " "))

(defun ham-spot-mode-family (name)
  "Return every mode the name NAME stands for.

A family name from `ham-spot-mode-groups\=' returns its whole family;
anything else returns just itself."
  (let ((family (assoc-string name ham-spot-mode-groups t)))
    (if family (cdr family) (list name))))

(defun ham-spot-mode-matches-p (mode wanted)
  "Return non-nil if MODE is among the modes named by WANTED.

WANTED is a list of names, each either a family or a mode.  A spot with
no mode at all is shown: it is a station on a frequency, and hiding it
because nobody said what it was doing there loses real spots."
  (or (null wanted)
      (null mode)
      (string-empty-p mode)
      (seq-some (lambda (name)
                  (seq-some (lambda (member) (string-equal-ignore-case mode member))
                            (ham-spot-mode-family name)))
                wanted)))

(defun ham-spot-view-matches-p (view spot)
  "Return non-nil if SPOT belongs in VIEW."
  (and (not (ham-spot--expired-p spot))
       (or (null (ham-spot-view-source view))
           (eq (ham-spot-source spot) (ham-spot-view-source view)))
       (or (null (ham-spot-view-age view))
           (<= (ham-spot-age spot) (* 60 (ham-spot-view-age view))))
       (or (null (ham-spot-view-bands view))
           (member (ham-spot-band spot) (ham-spot-view-bands view)))
       (ham-spot-mode-matches-p (ham-spot-mode spot) (ham-spot-view-modes view))
       (let ((case-fold-search t)
             (text (ham-spot--searchable spot)))
         (and (or (null (ham-spot-view-text view))
                  (string-match-p (ham-spot-view-text view) text))
              (or (null (ham-spot-view-exclude view))
                  (not (string-match-p (ham-spot-view-exclude view) text)))))))

(defun ham-spot-visible (&optional view)
  "Return the spots VIEW should show, in order.

Filtered and sorted, and rebuilt from `ham-spot-all\=' every time rather
than kept alongside it, so a filter can never hold onto a spot that has
aged out.  VIEW defaults to this buffer's."
  (let ((view (or view (ham-spot-view))))
    (ham-spot-sorted (seq-filter (lambda (spot) (ham-spot-view-matches-p view spot))
                                 ham-spot--spots)
                     (ham-spot-view-sort view))))

(defun ham-spot-sorted (spots &optional order)
  "Return SPOTS in ORDER, which defaults to `ham-spot-sort'."
  (let ((copy (copy-sequence spots)))
    (pcase (or order ham-spot-sort)
      ('frequency (sort copy (lambda (a b) (< (ham-spot-hz a) (ham-spot-hz b)))))
      ('call (sort copy (lambda (a b) (string-lessp (or (ham-spot-call a) "")
                                                    (or (ham-spot-call b) "")))))
      ('source (sort copy (lambda (a b)
                            (string-lessp
                             (symbol-name (or (ham-spot-source a) 'unknown))
                             (symbol-name (or (ham-spot-source b) 'unknown))))))
      ;; Newest first, by what each spot says its time is.
      ;;
      ;; This used to reverse the held list instead, on the assumption
      ;; that spots are held in the order they happened.  They are not:
      ;; a polled feed replaces its spots as a block, so a POTA answer
      ;; carrying half an hour of activations landed at the end of the
      ;; list and sorted as though all of it were newer than everything
      ;; the cluster had said.  The panel came out in blocks, one per
      ;; feed, which is exactly what a list sorted by age should never
      ;; look like.
      (_ (sort copy (lambda (a b) (time-less-p (ham-spot-when b)
                                               (ham-spot-when a))))))))


;;;; Turning the radio to a spot

(defcustom ham-spot-qsy-sets-mode t
  "Whether tuning to a spot also sets the mode.

The mode is a guess whenever the network did not supply one, and a
guess that changes the radio is worth being able to turn off."
  :type 'boolean
  :group 'ham-spot)

(defun ham-spot-qsy (spot)
  "Tune the radio to SPOT.

Interactively, the spot under the cursor.  This is what the panel is
for: everything else it does is in service of deciding which line to
put the cursor on."
  (interactive (list (ham-spot-at-point)))
  (unless spot
    (user-error "No spot here"))
  (unless (ham-rig-connected-p)
    (user-error "Not connected to rigctld.  M-x ham-rig-connect"))
  (let ((mode (and ham-spot-qsy-sets-mode (ham-spot-mode spot))))
    (ham-rig-tune-to (ham-spot-hz spot) mode)
    (message "ham-spot: %s on %s%s"
             (ham-spot-call spot)
             (ham-format-frequency (ham-spot-hz spot))
             (if mode (format " %s" mode) ""))))

(defun ham-spot-qsy-frequency-only (spot)
  "Tune the radio to SPOT without changing the mode."
  (interactive (list (ham-spot-at-point)))
  (let ((ham-spot-qsy-sets-mode nil))
    (ham-spot-qsy spot)))


;;;; The panel

(defcustom ham-spot-buffer-name "*ham-spots*"
  "Name of the buffer the combined spot panel draws into.

A panel showing one feed gets a buffer of its own named after it, so
that the cluster and the parks can be on screen at once."
  :type 'string
  :group 'ham-spot)

(defcustom ham-spot-separate-buffers nil
  "Whether `ham-spots\=' opens one window per feed rather than one list.

Combined is the shorter answer to \"who is on the air\", and the source
column says where each spot came from.  Separate is the better one when
the feeds are being used for different things -- watching a cluster for
DX while picking parks off a list -- since each panel then keeps its
own filter, sort and position, and a busy cluster cannot push the parks
off the screen."
  :type 'boolean
  :group 'ham-spot)

(defun ham-spot-buffer-name (&optional source)
  "Return the buffer name for the panel showing SOURCE, or the combined one."
  (if source
      (format "*ham-spots: %s*"
              (let ((feed (ham-spot-feed-named source)))
                (or (and feed (ham-spot-feed-title feed))
                    (symbol-name source))))
    ham-spot-buffer-name))

(defcustom ham-spot-comment-width 22
  "Columns given to a spot's comment, or zero to leave it out."
  :type 'integer
  :group 'ham-spot)

(defface ham-spot-new '((t :inherit ham-face-ok))
  "Face for a spot that arrived in the last minute."
  :group 'ham-spot)

(defface ham-spot-call '((t :inherit ham-face-value :weight bold))
  "Face for the callsign that was heard."
  :group 'ham-spot)

(defface ham-spot-frequency '((t :inherit ham-face-value))
  "Face for the frequency."
  :group 'ham-spot)

(defvar ham-spot--redisplay-timer nil)

(defun ham-spot--buffers ()
  "Return every live buffer showing a spot panel."
  (seq-filter (lambda (buffer)
                (with-current-buffer buffer
                  (derived-mode-p 'ham-spots-mode)))
              (buffer-list)))

(defun ham-spot--schedule-redisplay ()
  "Coalesce repaints onto an idle timer.

A cluster delivers spots in bursts, and redrawing per spot means
redrawing a hundred times for one burst."
  (unless ham-spot--redisplay-timer
    (setq ham-spot--redisplay-timer
          (run-with-idle-timer 0.2 nil #'ham-spot--redisplay))))

(defun ham-spot--redisplay ()
  "Repaint every visible spot panel."
  (setq ham-spot--redisplay-timer nil)
  (dolist (buffer (ham-spot--buffers))
    (when (get-buffer-window buffer t)
      (with-current-buffer buffer
        (ham-spot-refresh)))))

(defun ham-spot-at-point ()
  "Return the spot on the current line, or nil."
  (get-text-property (line-beginning-position) 'ham-spot))

(defun ham-spot--age-label (seconds)
  "Return SECONDS as the short age to print in a spot list."
  (cond
   ((< seconds 60) (format "%ds" seconds))
   ((< seconds 3600) (format "%dm" (/ seconds 60)))
   (t (format "%dh" (/ seconds 3600)))))

(defun ham-spot--detail (spot)
  "Return what to print after SPOT's age: where it is, or what was said.

A park or summit leads with its reference, because that is what an
operator writes in the log and what they will be asked for, and follows
it with the name while there is room.  Everything else has only the
spotter's comment."
  (let ((reference (ham-spot-reference spot))
        (name (ham-spot-reference-name spot))
        (comment (ham-spot-comment spot)))
    (cond
     ((and reference name) (format "%s %s" reference name))
     (reference reference)
     (name name)
     (comment comment)
     (t ""))))

(defun ham-spot--line (spot &optional with-source)
  "Return the panel line for SPOT.
WITH-SOURCE includes the column naming which feed it came from, which a
panel showing only one feed does not need."
  (let* ((age (ham-spot-age spot))
         (comment (ham-spot--detail spot))
         (source (symbol-name (or (ham-spot-source spot) 'unknown))))
    (concat
     ham-panel-indent
     (propertize (format "%9.1f" (ham-spot-khz spot)) 'face 'ham-spot-frequency)
     " "
     (propertize (format "%-5s" (or (ham-spot-band spot) "")) 'face 'ham-face-unit)
     (propertize (format "%-5s" (or (ham-spot-mode spot) "")) 'face 'ham-face-unit)
     " "
     (propertize (format "%-11s" (or (ham-spot-call spot) "")) 'face 'ham-spot-call)
     " "
     (propertize (format "%-4s" (ham-spot--age-label age))
                 'face (if (< age 60) 'ham-spot-new 'ham-face-note))
     (if with-source
         (propertize (format "%-10s" source) 'face 'ham-face-note)
       "")
     (if (> ham-spot-comment-width 0)
         ;; A panel showing one feed spends the source column on the
         ;; park or summit instead, which is the thing worth reading.
         (propertize (truncate-string-to-width
                      comment (+ ham-spot-comment-width
                                 (if with-source 0 10)))
                     'face 'ham-face-note)
       ""))))

(defun ham-spot--source ()
  "Return the feed this panel is limited to, or nil."
  (ham-spot-view-source (ham-spot-view)))

(defun ham-spot--shown ()
  "Return the spots to draw here, filtered and ordered by this view."
  (ham-spot-visible (ham-spot-view)))

(defun ham-spot--held ()
  "Return every spot this panel could show, before its filters."
  (let ((source (ham-spot--source)))
    (seq-filter (lambda (spot)
                  (and (not (ham-spot--expired-p spot))
                       (or (null source) (eq (ham-spot-source spot) source))))
                (ham-spot-all))))

(defun ham-spot--feed-lines ()
  "Return a status line for each feed this buffer is showing.

A panel may name a feed that is not registered: a back end that was
loaded when the buffer was opened and is not loaded now, or spots left
over from one.  That is a panel with nothing to say about its feed,
not an error."
  (seq-filter #'identity
              (mapcar (lambda (name)
                        (let ((feed (ham-spot-feed-named name)))
                          (and feed
                               (ham-spot-feed-status feed)
                               (funcall (ham-spot-feed-status feed)))))
                      (if (ham-spot--source)
                          (list (ham-spot--source))
                        (ham-spot-feed-names)))))

(defun ham-spot--title ()
  "Return what this panel is called."
  (let ((source (ham-spot--source)))
    (if source
        (let ((feed (ham-spot-feed-named source)))
          (or (and feed (ham-spot-feed-title feed))
              (symbol-name source)))
      "Spots")))

(defun ham-spot-view-description (view)
  "Return what VIEW is filtering on, as a short string, or nil.

A filter set an hour ago and forgotten looks exactly like a quiet band,
so a panel that is hiding anything says what."
  (let ((parts (delq nil
                     (list (when (ham-spot-view-bands view)
                             (string-join (ham-spot-view-bands view) " "))
                           (when (ham-spot-view-modes view)
                             (string-join (ham-spot-view-modes view) " "))
                           (when (ham-spot-view-age view)
                             (format "last %d min" (ham-spot-view-age view)))
                           (when (ham-spot-view-text view)
                             (format "/%s/" (ham-spot-view-text view)))
                           (when (ham-spot-view-exclude view)
                             (format "not /%s/" (ham-spot-view-exclude view)))
                           (unless (eq (ham-spot-view-sort view) 'age)
                             (format "by %s" (ham-spot-view-sort view)))))))
    (when parts (string-join parts "   "))))

(defun ham-spot--header ()
  "Return the panel's opening lines."
  (let* ((visible (length (ham-spot--shown)))
         (held (length (ham-spot--held)))
         (feeds (ham-spot--feed-lines))
         (filters (ham-spot-view-description (ham-spot-view))))
    (concat
     (ham-panel-header
      (format "%s   %d shown%s"
              (ham-spot--title)
              visible
              (if (= visible held) "" (format " of %d" held)))
      "RET tune  f filter  m mode  b band  s sort  F clear filters  ? keys")
     (if feeds
         (concat ham-panel-indent
                 (ham-note-line (string-join feeds "   ")) "\n")
       "")
     (if filters
         (concat ham-panel-indent
                 (propertize "showing " 'face 'ham-face-note)
                 (propertize filters 'face 'ham-face-label) "\n")
       "")
     (if (or feeds filters) "\n" ""))))

(defun ham-spot-refresh ()
  "Redraw this panel from the current list."
  (interactive)
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (column (current-column)))
    (erase-buffer)
    (insert (ham-spot--header))
    (let ((spots (ham-spot--shown)))
      (if (null spots)
          (insert ham-panel-indent
                  (ham-note-line
                   (if (ham-spot--held)
                       "Nothing matches the current filter."
                     "Waiting for spots."))
                  "\n")
        (dolist (spot spots)
          (let ((start (point)))
            (insert (ham-spot--line spot (null (ham-spot--source))) "\n")
            ;; On the whole line, so the cursor finds the spot wherever
            ;; in the row it happens to sit.
            (put-text-property start (point) 'ham-spot spot)))))
    ;; Column padding leaves trailing spaces on a row with no comment,
    ;; invisible until someone selects a region or diffs a capture.
    (delete-trailing-whitespace)
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column column)))

(defun ham-spot-next ()
  "Move to the next spot."
  (interactive)
  (forward-line 1)
  (when (eobp) (forward-line -1)))

(defun ham-spot-previous ()
  "Move to the previous spot."
  (interactive)
  (forward-line -1))

;; Every one of these changes this panel and no other.  Two windows
;; side by side are two views, and narrowing the parks to 20 metres
;; leaves the cluster beside it showing everything.

(defun ham-spot--blank-p (text)
  "Return non-nil if TEXT is empty or only whitespace."
  (or (null text) (string-empty-p (string-trim text))))

(defun ham-spot-set-filter (regexp)
  "Show only spots matching REGEXP, in this panel.
An empty REGEXP shows everything again."
  (interactive (list (read-string "Show spots matching: "
                                  (ham-spot-view-text (ham-spot-view)))))
  (setf (ham-spot-view-text (ham-spot-view))
        (unless (ham-spot--blank-p regexp) regexp))
  (ham-spot-refresh))

(defun ham-spot-set-exclude (regexp)
  "Hide spots matching REGEXP, in this panel.  Empty hides none."
  (interactive (list (read-string "Hide spots matching: "
                                  (ham-spot-view-exclude (ham-spot-view)))))
  (setf (ham-spot-view-exclude (ham-spot-view))
        (unless (ham-spot--blank-p regexp) regexp))
  (ham-spot-refresh))

(defun ham-spot-set-bands (bands)
  "Show only BANDS in this panel, or all bands if empty."
  (interactive
   (list (completing-read-multiple
          "Bands (empty for all): "
          (mapcar #'car ham-bands) nil t
          (let ((current (ham-spot-view-bands (ham-spot-view))))
            (and current (string-join current ","))))))
  (setf (ham-spot-view-bands (ham-spot-view))
        (let ((wanted (delete "" (or bands nil))))
          (and wanted wanted)))
  (ham-spot-refresh))

(defun ham-spot--mode-candidates ()
  "Return the mode names worth offering.

The families first, then whatever modes the spots actually carry: the
families are how an operator asks for phone or digital, and the rest is
whatever the networks happen to be reporting today."
  (delete-dups
   (append (mapcar #'car ham-spot-mode-groups)
           (sort (delq nil (delete-dups (mapcar #'ham-spot-mode
                                                (ham-spot-all))))
                 #'string-lessp))))

(defun ham-spot-set-modes (modes)
  "Show only MODES in this panel, or every mode if empty.

A family name shows the whole family, so SSB covers USB and LSB and
DATA covers FT8, RTTY and the rest.  Any other name matches only
itself, so FT8 means FT8."
  (interactive
   (list (completing-read-multiple
          "Modes (empty for all): "
          (ham-spot--mode-candidates) nil nil
          (let ((current (ham-spot-view-modes (ham-spot-view))))
            (and current (string-join current ","))))))
  (setf (ham-spot-view-modes (ham-spot-view))
        (let ((wanted (delete "" (or modes nil))))
          (and wanted (mapcar #'upcase wanted))))
  (ham-spot-refresh))

(defun ham-spot-set-sort (order)
  "Order this panel by ORDER."
  (interactive
   (list (intern (completing-read "Sort by: "
                                  '("age" "frequency" "call" "source")
                                  nil t nil nil
                                  (symbol-name (ham-spot-view-sort
                                                (ham-spot-view)))))))
  (setf (ham-spot-view-sort (ham-spot-view)) order)
  (ham-spot-refresh))

(defun ham-spot-set-age (minutes)
  "Show only spots from the last MINUTES in this panel.

Zero, or a number at least as large as `ham-spot-max-age\=', shows
everything held.  The store keeps `ham-spot-max-age\=' minutes for every
panel, so asking one panel for more than that shows no more: it is said
rather than silently ignored."
  (interactive (list (read-number "Show spots from the last how many minutes: "
                                  (or (ham-spot-view-age (ham-spot-view))
                                      ham-spot-max-age))))
  (setf (ham-spot-view-age (ham-spot-view))
        (cond
         ((<= minutes 0) nil)
         ((>= minutes ham-spot-max-age)
          (when (> minutes ham-spot-max-age)
            (message "ham-spot: only %d minutes are kept; raise `ham-spot-max-age' for more"
                     ham-spot-max-age))
          nil)
         (t minutes)))
  (ham-spot-refresh))

(defun ham-spot-reset-filters ()
  "Clear every filter in this panel, keeping its feed and its order."
  (interactive)
  (let ((view (ham-spot-view)))
    (setf (ham-spot-view-text view) nil
          (ham-spot-view-exclude view) nil
          (ham-spot-view-bands view) nil
          (ham-spot-view-modes view) nil
          (ham-spot-view-age view) nil))
  (ham-spot-refresh))

(defun ham-spot-refresh-feeds ()
  "Ask every source that can be asked for an update now."
  (interactive)
  (dolist (name (ham-spot-feed-names))
    (let ((source (ham-spot-feed-named name)))
      (when (ham-spot-feed-refresh source)
        (with-demoted-errors "ham-spot: refresh failed: %S"
          (funcall (ham-spot-feed-refresh source))))))
  (ham-spot-refresh))

(defun ham-spot-show-details ()
  "Describe the spot under the cursor in full."
  (interactive)
  (let ((spot (ham-spot-at-point)))
    (unless spot (user-error "No spot here"))
    (ham-with-help-buffer "*ham-spot-detail*"
        (format "%s on %s" (ham-spot-call spot)
                (ham-format-frequency (ham-spot-hz spot)))
      (dolist (row (list (cons "Call" (ham-spot-call spot))
                         (cons "Frequency" (format "%.1f kHz" (ham-spot-khz spot)))
                         (cons "Band" (ham-spot-band spot))
                         (cons "Mode" (ham-spot-mode spot))
                         (cons "Grid" (ham-spot-grid spot))
                         (cons "Spotted by" (ham-spot-spotter spot))
                         (cons "Spotter grid" (ham-spot-spotter-grid spot))
                         (cons "Reference" (ham-spot-reference spot))
                         (cons "Name" (ham-spot-reference-name spot))
                         (cons "SNR" (and (ham-spot-snr spot)
                                          (format "%s dB" (ham-spot-snr spot))))
                         (cons "Comment" (ham-spot-comment spot))
                         (cons "Source" (symbol-name (or (ham-spot-source spot)
                                                         'unknown)))
                         (cons "Age" (ham-spot--age-label (ham-spot-age spot)))))
        (when (and (cdr row) (not (string-empty-p (format "%s" (cdr row)))))
          (insert ham-panel-indent
                  (propertize (format "%-14s" (car row)) 'face 'ham-face-label)
                  (format "%s" (cdr row)) "\n")))
      (when-let ((distance (ham-spot-distance spot)))
        (insert ham-panel-indent
                (propertize (format "%-14s" "Distance") 'face 'ham-face-label)
                (format "%.0f km, bearing %.0f°" (car distance) (cdr distance))
                "\n")))))

(defun ham-spot-distance (spot)
  "Return (KM . BEARING) from the station to SPOT, or nil.

Needs `ham-station-grid\=' set and a grid on the spot.  A cluster spot
carries no grid, so this is mostly for the activation programs, which
all publish one."
  (let ((here (ham-station-latlon))
        (grid (ham-spot-grid spot)))
    (when (and here grid)
      (ignore-errors
        (let ((there (ham-maidenhead-to-latlon grid)))
          (ham-great-circle (car here) (cdr here) (car there) (cdr there)))))))

;; The keymap comes before the help that lists it: the help reads the
;; keymap to describe itself, so it cannot be written above it.
(defvar-keymap ham-spots-mode-map
  :doc "Keymap for `ham-spots-mode'."
  "RET" #'ham-spot-qsy
  "." #'ham-spot-qsy
  "SPC" #'ham-spot-qsy-frequency-only
  "n" #'ham-spot-next
  "p" #'ham-spot-previous
  "<down>" #'ham-spot-next
  "<up>" #'ham-spot-previous
  "d" #'ham-spot-show-details
  "f" #'ham-spot-set-filter
  "x" #'ham-spot-set-exclude
  "m" #'ham-spot-set-modes
  "b" #'ham-spot-set-bands
  "s" #'ham-spot-set-sort
  "a" #'ham-spot-set-age
  "F" #'ham-spot-reset-filters
  "g" #'ham-spot-refresh-feeds
  "c" #'ham-spot-clear
  "o" #'ham-spot-show-this-feed
  "1" #'ham-spots-combined
  "2" #'ham-spots-separate
  "?" #'ham-spot-help
  "q" #'quit-window)

(defun ham-spot-help ()
  "Describe the spot panel."
  (interactive)
  (ham-with-help-buffer "*ham-spot-help*" "Spot panel"
    (insert ham-panel-indent
            "Spots from every network that is running.  Put the cursor on\n"
            ham-panel-indent
            "one and press RET to turn the radio to it.\n\n")
    (ham-insert-key-table "Keys" ham-spots-mode-map)
    (insert (propertize "Filters belong to one panel\n" 'face 'ham-face-heading))
    (insert ham-panel-indent
            "Each panel keeps its own filters, order and position, so two\n"
            ham-panel-indent
            "windows side by side are two independent things: narrowing the\n"
            ham-panel-indent
            "parks to 20 metres leaves the cluster beside it alone.  The\n"
            ham-panel-indent
            "`ham-spot-filter' settings are what a new panel starts from.\n\n")
    (insert (propertize "Asking for a mode\n" 'face 'ham-face-heading))
    (insert ham-panel-indent
            "`m' takes a family or an exact mode.  SSB finds spots marked\n"
            ham-panel-indent
            "USB and LSB as well; DATA finds FT8, RTTY and the rest; FT8\n"
            ham-panel-indent
            "finds only FT8.  The families are `ham-spot-mode-groups'.  A\n"
            ham-panel-indent
            "spot whose mode nobody reported is always shown: it is still a\n"
            ham-panel-indent
            "station on a frequency.\n\n")
    (let* ((view (ham-spot-view))
           (source (ham-spot-view-source view)))
      (insert (propertize "This panel\n" 'face 'ham-face-heading))
      (insert ham-panel-indent
              (format "Feed     %s\n" (or source "all")))
      (insert ham-panel-indent
              (format "Showing  %s\n" (or (ham-spot-view-description view)
                                          "everything held")))
      (insert ham-panel-indent
              (format "Held     %d minutes, for every panel\n\n"
                      ham-spot-max-age)))
    (insert (propertize "The mode a spot shows\n" 'face 'ham-face-heading))
    (insert ham-panel-indent
            "Most networks report a frequency and nothing else, so the mode\n"
            ham-panel-indent
            "is usually worked out from the band plan rather than reported:\n"
            ham-panel-indent
            "14074 is FT8 because that is what 14074 is for.  Tuning sends\n"
            ham-panel-indent
            "the rig's own name for it -- a spot saying FT8 puts the radio\n"
            ham-panel-indent
            "in PKTUSB -- and a mode the rig does not have is left alone.\n"
            ham-panel-indent
            "See `ham-rig-mode-aliases' and `ham-spot-qsy-sets-mode'.\n\n")
    (ham-insert-legend
     "Colours"
     (list (list "new" 'ham-spot-new "heard in the last minute")
           (list "K6SM" 'ham-spot-call "the station that was heard")
           (list "20m FT8" 'ham-face-unit "band and mode")))))

(easy-menu-define ham-spots-mode-menu ham-spots-mode-map
  "Menu for `ham-spots-mode'."
  '("Spots"
    ["Tune radio to this spot" ham-spot-qsy :keys "RET"]
    ["Tune, keeping the mode" ham-spot-qsy-frequency-only :keys "SPC"]
    ["Describe this spot" ham-spot-show-details :keys "d"]
    "---"
    ["Show only matching" ham-spot-set-filter :keys "f"]
    ["Hide matching" ham-spot-set-exclude :keys "x"]
    ["Modes" ham-spot-set-modes :keys "m"]
    ["Bands" ham-spot-set-bands :keys "b"]
    ["Age" ham-spot-set-age :keys "a"]
    ["Clear every filter" ham-spot-reset-filters :keys "F"]
    ["Sort" ham-spot-set-sort :keys "s"]
    "---"
    ["Refresh" ham-spot-refresh-feeds :keys "g"]
    ["Clear" ham-spot-clear :keys "c"]
    "---"
    ["One list for every feed" ham-spots-combined :keys "1"]
    ["A window for each feed" ham-spots-separate :keys "2"]
    ["Only this spot's feed" ham-spot-show-this-feed :keys "o"]
    "---"
    ["Explain this panel" ham-spot-help :keys "?"]
    ["Customize" (lambda () (interactive) (customize-group 'ham-spot))]
    "---"
    ["Bury panel" quit-window :keys "q"]))

(define-derived-mode ham-spots-mode special-mode "Spots"
  "Major mode listing spots, with a key to tune the radio to one.

\\{ham-spots-mode-map}"
  (buffer-disable-undo)
  (setq-local truncate-lines t)
  (setq-local cursor-type 'box))

(defun ham-spot--panel (source)
  "Return the panel buffer for SOURCE, creating and filling it if need be.

An existing panel keeps the view it has: reopening a window must not
throw away the filters somebody set in it.  Only a new one starts from
the defaults."
  (let ((buffer (get-buffer-create (ham-spot-buffer-name source))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ham-spots-mode) (ham-spots-mode))
      (unless ham-spot--view
        (setq ham-spot--view (ham-spot-default-view source)))
      ;; The feed is the one thing a panel does not get to drift on: the
      ;; buffer is named after it.
      (setf (ham-spot-view-source ham-spot--view) source)
      (ham-spot-refresh))
    buffer))

;;;###autoload
(defun ham-spots (&optional source)
  "Open the spot panel, showing SOURCE only when one is given.

With no source and `ham-spot-separate-buffers\=' set, opens one window
per feed instead of one combined list."
  (interactive)
  (ham-spot-start-feeds)
  (if (and (null source) ham-spot-separate-buffers)
      (ham-spots-separate)
    (pop-to-buffer (ham-spot--panel source))))

;;;###autoload
(defun ham-spots-separate ()
  "Show each feed in a window of its own.

One panel per registered feed, each with its own filter, sort and
position.  A cluster on a contest weekend produces spots faster than
anyone can read them, and in a combined list it buries the handful of
park and summit activations that were the reason for looking."
  (interactive)
  (ham-spot-start-feeds)
  (let ((names (ham-spot-feed-names)))
    (unless names
      (user-error "No spot feeds are loaded.  Try (require 'ham-dxcluster)"))
    (delete-other-windows)
    (let ((first (ham-spot--panel (car names)))
          (placed 1)
          (crowded nil))
      (switch-to-buffer first)
      (dolist (name (cdr names))
        ;; Split the largest window each time, so three feeds divide the
        ;; frame evenly rather than halving the last one repeatedly.
        (select-window (get-largest-window))
        (let ((window (split-window-sensibly)))
          (if (null window)
              ;; No room left.  Switching buffers here would put this
              ;; feed over one already on screen, which looks like the
              ;; panel losing track of itself; the buffer exists either
              ;; way and can be switched to by hand.
              (setq crowded t)
            (select-window window)
            (switch-to-buffer (ham-spot--panel name))
            (setq placed (1+ placed)))))
      (select-window (get-buffer-window first))
      (when crowded
        (message "ham-spot: %d of %d feeds fit; the rest are in buffers"
                 placed (length names)))
      placed)))

;;;###autoload
(defun ham-spots-combined ()
  "Show every feed's spots in one list."
  (interactive)
  (ham-spot-start-feeds)
  (pop-to-buffer (ham-spot--panel nil)))

(defun ham-spot-show-this-feed ()
  "Open a panel showing only the feed the spot under the cursor came from."
  (interactive)
  (let ((spot (ham-spot-at-point)))
    (unless spot (user-error "No spot here"))
    (pop-to-buffer (ham-spot--panel (ham-spot-source spot)))))

(defun ham-spot-start-feeds ()
  "Start every registered feed that is not already running."
  (dolist (name (ham-spot-feed-names))
    (let ((feed (ham-spot-feed-named name)))
      (when (and (ham-spot-feed-start feed)
                 (not (and (ham-spot-feed-live-p feed)
                           (funcall (ham-spot-feed-live-p feed)))))
        (with-demoted-errors "ham-spot: could not start source: %S"
          (funcall (ham-spot-feed-start feed)))))))

(defun ham-spot-stop-feeds ()
  "Stop every registered feed."
  (interactive)
  (dolist (name (ham-spot-feed-names))
    (let ((feed (ham-spot-feed-named name)))
      (when (ham-spot-feed-stop feed)
        (with-demoted-errors "ham-spot: could not stop source: %S"
          (funcall (ham-spot-feed-stop feed)))))))

(provide 'ham-spot)
;;; ham-spot.el ends here
