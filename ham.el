;;; ham.el --- Core library for amateur radio packages -*- lexical-binding: t; -*-

;; Copyright (C) 2026 K6SM

;; Author: K6SM
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1"))
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

;; `ham.el' is the shared foundation for a family of amateur radio
;; packages.  It deliberately contains no user interface.  It provides:
;;
;;   * An event bus, so packages compose without depending on each other.
;;     `ham-rig' publishes frequency changes; a logger, band map or
;;     greyline map subscribes.  Subscribers are isolated: a signalling
;;     handler cannot take down the bus.
;;
;;   * A reusable asynchronous line-oriented TCP transport with a
;;     reconnect backoff.  Used by rigctld, DX cluster telnet, and
;;     anything else that speaks lines over a socket.  Nothing here
;;     blocks the main loop.
;;
;;   * Display capability detection, so each package degrades to the
;;     terminal deliberately rather than by accident.
;;
;;   * Geodesy and band plan helpers: Maidenhead conversion, great
;;     circle distance and bearing, band lookup, frequency formatting.
;;
;; Design rule for the whole family: Emacs is the control surface and
;; the state store, never the signal path.  Anything touching audio
;; samples or needing sub-10ms determinism belongs in an external
;; process.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup ham nil
  "Amateur radio support for Emacs."
  :group 'applications
  :prefix "ham-")


;;;; Shared faces

;; Every face here inherits a standard one, so the panels follow whatever
;; theme is loaded instead of imposing colours of their own.  This is what
;; `adif.el' already does by leaning on font-lock, and it is why a field
;; name in the rig panel, in the QSO form and in an ADIF file all come out
;; the same colour.
;;
;; The NOAA space weather scales are the one deliberate exception: their
;; green to magenta progression is published and carries meaning, so those
;; faces keep literal colours.

(defface ham-face-label '((t :inherit font-lock-keyword-face))
  "Face for field names and row labels."
  :group 'ham)

(defface ham-face-value '((t :inherit default))
  "Face for readings and values."
  :group 'ham)

(defface ham-face-unit '((t :inherit font-lock-string-face))
  "Face for units and the ranges a reading is measured against."
  :group 'ham)

(defface ham-face-note '((t :inherit font-lock-comment-face))
  "Face for the lines at the top of a panel, and for help text."
  :group 'ham)

(defface ham-face-heading '((t :inherit bold))
  "Face for section headings within a panel."
  :group 'ham)

(defface ham-face-ok '((t :inherit success))
  "Face for a good state: connected, receiving, band open."
  :group 'ham)

(defface ham-face-warn '((t :inherit warning))
  "Face for a state worth noticing but not acting on."
  :group 'ham)

(defface ham-face-danger '((t :inherit error))
  "Face for a state needing attention: transmitting, band closed."
  :group 'ham)

(defface ham-face-stale '((t :inherit shadow :slant italic))
  "Face for a reading old enough to be misleading."
  :group 'ham)


;;;; Shared panel furniture

(defconst ham-panel-indent "  "
  "Indentation for the body of a panel, below its opening lines.")

(defun ham-note-line (text)
  "Return TEXT as a quiet line in `ham-face-note'.
The face is appended rather than imposed, so a word TEXT has already
coloured -- a connection state, a band condition -- keeps its own colour
and only the rest of the line goes quiet."
  (let ((line (copy-sequence text)))
    (add-face-text-property 0 (length line) 'ham-face-note t line)
    line))

(defun ham-panel-header (title &optional hints)
  "Return the lines every panel opens with.
TITLE names what is being looked at.  HINTS is a short reminder of the
keys worth knowing, with the full list left to the help buffer."
  (concat (ham-note-line title) "\n"
          (if hints (concat (ham-note-line hints) "\n") "")
          "\n"))

(defun ham-key-rows (keymap)
  "Return (KEY . SUMMARY) for every command bound in KEYMAP, sorted by key."
  (let (rows)
    (map-keymap
     (lambda (event definition)
       (when (commandp definition)
         (push (cons (key-description (vector event))
                     (let ((doc (documentation definition)))
                       (if doc (car (split-string doc "\n")) "")))
               rows)))
     keymap)
    ;; `map-keymap' walks in reverse insertion order, which is no order at
    ;; all to read a key list in.
    (sort rows (lambda (a b) (string-lessp (car a) (car b))))))

(defun ham-insert-key-table (title keymap)
  "Insert a table of the bindings in KEYMAP under TITLE."
  (insert (propertize (concat title "\n") 'face 'ham-face-heading))
  (dolist (row (ham-key-rows keymap))
    (insert (format "%s%-12s %s\n" ham-panel-indent
                    (propertize (car row) 'face 'ham-face-label)
                    (cdr row))))
  (insert "\n"))

(defun ham-insert-legend (title entries)
  "Insert ENTRIES under TITLE as coloured label and explanation pairs.
ENTRIES is a list of (TEXT FACE EXPLANATION), and TEXT is shown in FACE
so the help says what a colour means by showing it."
  (insert (propertize (concat title "\n") 'face 'ham-face-heading))
  (dolist (entry entries)
    (insert (format "%s%s %s\n" ham-panel-indent
                    (propertize (format "%-12s" (nth 0 entry)) 'face (nth 1 entry))
                    (nth 2 entry))))
  (insert "\n"))

(defmacro ham-with-help-buffer (name title &rest body)
  "Render a help buffer called NAME headed by TITLE, running BODY to fill it."
  (declare (indent 2))
  `(with-current-buffer (get-buffer-create ,name)
     (let ((inhibit-read-only t))
       (erase-buffer)
       (insert (ham-panel-header ,title))
       ,@body
       (goto-char (point-min)))
     (special-mode)
     (pop-to-buffer (current-buffer))))


;;;; Event bus

(defvar ham--subscribers (make-hash-table :test #'eq)
  "Map of topic symbol to an alist of (ID . FUNCTION).")

(defun ham-subscribe (topic id function)
  "Subscribe FUNCTION to TOPIC under the symbol ID.
Subscribing again with the same TOPIC and ID replaces the previous
FUNCTION, which makes re-evaluating a subscriber file idempotent.

FUNCTION must not block.  It is called synchronously from whatever
published the event, which may be a process filter."
  (cl-check-type topic symbol)
  (cl-check-type id symbol)
  (let ((alist (gethash topic ham--subscribers)))
    (setf (alist-get id alist) function)
    (puthash topic alist ham--subscribers))
  id)

(defun ham-unsubscribe (topic id)
  "Remove the subscriber registered as ID on TOPIC."
  (let ((alist (gethash topic ham--subscribers)))
    (when alist
      (setf (alist-get id alist nil t) nil)
      (if alist
          (puthash topic alist ham--subscribers)
        (remhash topic ham--subscribers)))))

(defun ham-publish (topic &rest args)
  "Publish an event on TOPIC, calling each subscriber with ARGS.
Errors signalled by a subscriber are demoted to messages so that one
bad handler cannot break the publisher or the other subscribers."
  (dolist (entry (gethash topic ham--subscribers))
    (with-demoted-errors "ham-publish: subscriber error: %S"
      (apply (cdr entry) args))))

(defun ham-has-subscribers-p (topic)
  "Return non-nil if TOPIC has at least one subscriber.
Cheaper than `ham-topics' and safe to call from a poll loop."
  (and (gethash topic ham--subscribers) t))

(defun ham-topics ()
  "Return a list of topics that currently have subscribers."
  (let (topics)
    (maphash (lambda (k _v) (push k topics)) ham--subscribers)
    (nreverse topics)))


;;;; Display capability

(defun ham-display-capability ()
  "Return the richest display capability available: `svg', `image' or `text'.
Packages should branch on this rather than on `display-graphic-p', so
that the terminal path is a designed fallback and not an afterthought."
  (cond
   ((and (display-graphic-p) (image-type-available-p 'svg)) 'svg)
   ((display-images-p) 'image)
   (t 'text)))

(defun ham-unicode-blocks-p ()
  "Return non-nil if block drawing characters are displayable."
  (and (char-displayable-p ?█) (char-displayable-p ?▏)))


;;;; Asynchronous line transport

(defcustom ham-reconnect-initial-delay 1.0
  "Initial delay in seconds before retrying a dropped connection."
  :type 'number
  :group 'ham)

(defcustom ham-reconnect-max-delay 30.0
  "Maximum delay in seconds between reconnection attempts."
  :type 'number
  :group 'ham)

(defcustom ham-connect-timeout 5.0
  "Seconds to allow a connection attempt to be answered.

A host that is switched off or behind a firewall never answers at all.
Opening the socket does not block Emacs, but without a deadline of our
own the attempt sits pending for as long as the operating system keeps
retrying, which can be minutes, and the panel has nothing to say for
the whole of it."
  :type 'number
  :group 'ham)

(defcustom ham-supervise-interval 1.0
  "Seconds between checks on the state of every open connection."
  :type 'number
  :group 'ham)

(cl-defstruct (ham-connection (:constructor ham--connection-create)
                              (:copier nil))
  "A line-oriented asynchronous TCP connection."
  name host port process
  (pending "")
  on-line on-status
  (state 'disconnected)
  (auto-reconnect t)
  (backoff nil)
  (attempt-started nil)
  (next-retry 0)
  (lines-in 0)
  (lines-out 0))

(defun ham-connection-live-p (conn)
  "Return non-nil if CONN has an open process."
  (and conn
       (ham-connection-process conn)
       (process-live-p (ham-connection-process conn))
       (eq (ham-connection-state conn) 'connected)))

(defun ham--connection-set-state (conn state &optional detail)
  "Set CONN state to STATE and notify its status callback with DETAIL."
  (unless (eq (ham-connection-state conn) state)
    (setf (ham-connection-state conn) state)
    (when (ham-connection-on-status conn)
      (with-demoted-errors "ham-connection: status handler error: %S"
        (funcall (ham-connection-on-status conn) state detail)))))

(defun ham--connection-filter (conn chunk)
  "Accumulate CHUNK for CONN and dispatch each complete line."
  (setf (ham-connection-pending conn)
        (concat (ham-connection-pending conn) chunk))
  (let ((start 0)
        (text (ham-connection-pending conn))
        idx)
    (while (setq idx (string-search "\n" text start))
      (let ((line (string-trim-right (substring text start idx) "\r")))
        (cl-incf (ham-connection-lines-in conn))
        (when (ham-connection-on-line conn)
          (with-demoted-errors "ham-connection: line handler error: %S"
            (funcall (ham-connection-on-line conn) line))))
      (setq start (1+ idx)))
    (setf (ham-connection-pending conn) (substring text start))))

(defun ham--connection-socket-busy-p (conn)
  "Return non-nil if CONN's process is open or still connecting.

This asks the process rather than the connection state, because
scheduling a reconnect moves the state to `reconnecting' and so would
make a perfectly good socket look idle to `ham-connection-live-p'."
  (let ((process (ham-connection-process conn)))
    (and process
         (process-live-p process)
         (memq (process-status process) '(open connect))
         t)))

;; Reconnection is supervised rather than chained.  A single repeating
;; timer asks every connection the same question -- are you where you
;; should be? -- and acts on the answer.  The chain of one-shot timers
;; this replaces had a branch that cleared its own timer, found the
;; socket busy but not yet open, and returned having armed nothing.  More
;; generally a pending connect could sit for the length of the kernel's
;; TCP retry with no deadline and no timer, leaving the panel inert with
;; nothing to report.  A supervisor cannot lose track like that:
;; whatever state a connection is left in, the next tick reconsiders it.

(defvar ham--connections nil
  "Connections currently under supervision.")

(defvar ham--supervisor-timer nil
  "The repeating timer that watches every connection, or nil.")

(defun ham--supervisor-ensure ()
  "Make sure the supervisor is running."
  (unless (timerp ham--supervisor-timer)
    (setq ham--supervisor-timer
          (run-at-time ham-supervise-interval ham-supervise-interval
                       #'ham--supervise))))

(defun ham--supervisor-maybe-stop ()
  "Stop the supervisor when it has nothing left to watch."
  (when (and (null ham--connections) (timerp ham--supervisor-timer))
    (cancel-timer ham--supervisor-timer)
    (setq ham--supervisor-timer nil)))

(defun ham--connection-register (conn)
  "Put CONN under supervision."
  (cl-pushnew conn ham--connections :test #'eq)
  (ham--supervisor-ensure))

(defun ham--connection-unregister (conn)
  "Take CONN out of supervision."
  (setq ham--connections (delq conn ham--connections))
  (ham--supervisor-maybe-stop))

(defun ham-connection-retry-in (conn)
  "Return seconds until CONN is next retried, or nil if it is not waiting.

A connection that has been closed is not waiting for anything: it is
disconnected and staying that way, and reporting a countdown of zero
for it would have a panel say it was about to reconnect forever."
  (when (and conn
             (ham-connection-auto-reconnect conn)
             (memq (ham-connection-state conn) '(disconnected reconnecting)))
    (max 0 (- (or (ham-connection-next-retry conn) 0) (float-time)))))

(defun ham--connection-wait (conn detail)
  "Put CONN into the waiting state after DETAIL, backing off each time."
  (let ((delay (or (ham-connection-backoff conn) ham-reconnect-initial-delay)))
    (setf (ham-connection-backoff conn)
          (min ham-reconnect-max-delay (* 2 delay)))
    (setf (ham-connection-next-retry conn) (+ (float-time) delay))
    (setf (ham-connection-attempt-started conn) nil)
    (ham--connection-set-state
     conn 'reconnecting (format "%s, retrying in %.1fs" detail delay))))

(defun ham--connection-supervise (conn)
  "Move CONN towards where it should be, if it is not there already."
  (pcase (ham-connection-state conn)
    ('connecting
     (let ((started (ham-connection-attempt-started conn)))
       (when (and started (> (- (float-time) started) ham-connect-timeout))
         (ham--connection-discard-process conn)
         (ham--connection-wait
          conn (format "no answer within %gs" ham-connect-timeout)))))
    ((or 'disconnected 'reconnecting)
     (cond
      ((not (ham-connection-auto-reconnect conn)) nil)
      ;; A socket that came back on its own is not to be torn down and
      ;; reopened: that deletes a working process and starts the flapping
      ;; this supervisor exists to prevent.
      ((ham--connection-socket-busy-p conn)
       (when (eq (process-status (ham-connection-process conn)) 'open)
         (ham--connection-set-state conn 'connected)))
      ((>= (float-time) (or (ham-connection-next-retry conn) 0))
       (ham-connection-open conn))))
    (_ nil)))

(defun ham--supervise ()
  "Check on every connection under supervision."
  (dolist (conn (copy-sequence ham--connections))
    (with-demoted-errors "ham-connection: supervisor error: %S"
      (ham--connection-supervise conn))))

(defun ham--connection-sentinel (conn event)
  "Handle a process EVENT for CONN."
  (cond
   ((string-prefix-p "open" event)
    (setf (ham-connection-backoff conn) ham-reconnect-initial-delay)
    (setf (ham-connection-attempt-started conn) nil)
    (setf (ham-connection-next-retry conn) 0)
    (ham--connection-set-state conn 'connected))
   ((string-match-p "\\`\\(failed\\|connection broken\\)" event)
    (ham--connection-set-state conn 'disconnected (string-trim event))
    (ham--connection-wait conn (string-trim event)))
   ((string-match-p "\\`\\(deleted\\|finished\\|exited\\|killed\\)" event)
    (ham--connection-set-state conn 'disconnected (string-trim event))
    (ham--connection-wait conn (string-trim event)))))

(cl-defun ham-connection-make (&key name host port on-line on-status
                                    (auto-reconnect t))
  "Create a connection object for HOST and PORT named NAME.
ON-LINE is called with each complete line received.  ON-STATUS is
called with a state symbol and an optional detail string.  The
connection is not opened; call `ham-connection-open'."
  (ham--connection-create :name (or name (format "%s:%s" host port))
                          :host host :port port
                          :on-line on-line :on-status on-status
                          :auto-reconnect auto-reconnect
                          :backoff ham-reconnect-initial-delay))

(defun ham--connection-discard-process (conn)
  "Delete CONN's process, if any, without treating that as a link failure.

The process slot is cleared before the delete so that the resulting
sentinel event is recognised as belonging to a process we have already
abandoned.  Left in place, our own teardown arrives looking exactly like
the remote end hanging up, and the connection schedules a reconnect it
does not need."
  (let ((process (ham-connection-process conn)))
    (when process
      (setf (ham-connection-process conn) nil)
      (ignore-errors (delete-process process)))))

(defun ham-connection-open (conn)
  "Open CONN asynchronously.  Return CONN."
  (ham--connection-discard-process conn)
  (setf (ham-connection-pending conn) "")
  (setf (ham-connection-attempt-started conn) (float-time))
  (ham--connection-register conn)
  (ham--connection-set-state conn 'connecting)
  (condition-case err
      (setf (ham-connection-process conn)
            (make-network-process
             :name (ham-connection-name conn)
             :host (ham-connection-host conn)
             :service (ham-connection-port conn)
             :nowait t
             :noquery t
             :coding 'utf-8-unix
             ;; Both handlers ignore anything from a process that is no
             ;; longer this connection's.  A superseded socket goes on
             ;; delivering events after its replacement is up, and acting
             ;; on those tears down the working link -- which schedules a
             ;; reconnect, which replaces the working process, which
             ;; delivers another stale event.  That loop runs forever at
             ;; the reconnect interval and never backs off, because every
             ;; successful open resets the backoff.
             :filter (lambda (process chunk)
                       (when (eq process (ham-connection-process conn))
                         (ham--connection-filter conn chunk)))
             :sentinel (lambda (process event)
                         (when (eq process (ham-connection-process conn))
                           (ham--connection-sentinel conn event)))))
    (error
     (ham--connection-set-state conn 'disconnected (error-message-string err))
     (ham--connection-wait conn (error-message-string err))))
  conn)

(defun ham-connection-close (conn)
  "Close CONN and stop trying to reach it."
  (setf (ham-connection-auto-reconnect conn) nil)
  (setf (ham-connection-attempt-started conn) nil)
  (ham--connection-unregister conn)
  (ham--connection-discard-process conn)
  (ham--connection-set-state conn 'disconnected "closed"))

(defun ham-connection-send (conn string)
  "Send STRING over CONN.  Return non-nil on success.
A newline is appended if STRING does not already end with one."
  (when (ham-connection-live-p conn)
    (let ((payload (if (string-suffix-p "\n" string) string (concat string "\n"))))
      (cl-incf (ham-connection-lines-out conn))
      (condition-case nil
          (progn (process-send-string (ham-connection-process conn) payload) t)
        (error nil)))))


;;;; Station

(defcustom ham-station-grid nil
  "The operator's Maidenhead locator, or nil if not set.

Shared station identity rather than any one package's setting: a
propagation estimate needs it to place the observer, a logger needs it
to work out bearings and distances, and a greyline map needs it to
centre itself.  Four, six or eight characters."
  :type '(choice (const :tag "Not set" nil) string)
  :group 'ham)

(defun ham-station-latlon ()
  "Return (LATITUDE . LONGITUDE) for `ham-station-grid', or nil.
Returns nil rather than signalling when the grid is unset or malformed,
so a caller can offer to do without a location."
  (when (and ham-station-grid (stringp ham-station-grid))
    (ignore-errors (ham-maidenhead-to-latlon ham-station-grid))))


;;;; Geodesy

(defconst ham-geomagnetic-pole '(80.7 . -72.7)
  "Latitude and longitude of the north geomagnetic pole.
An approximate dipole position.  The pole drifts, so this is accurate
enough for deciding whether a path is a high latitude one and not for
anything that needs the real field.")

(defun ham-geomagnetic-latitude (lat lon)
  "Return the approximate geomagnetic latitude of LAT and LON, in degrees.

Ionospheric behaviour follows the magnetic field rather than geography:
auroral absorption and storm depression of the F2 layer are organised
about the geomagnetic pole, which sits well away from the geographic
one.  A station in Scotland and one at the same geographic latitude in
Siberia do not see the same ionosphere."
  (let* ((rad (/ float-pi 180.0))
         (lat-r (* lat rad))
         (pole-lat (* (car ham-geomagnetic-pole) rad))
         (delta (* (- lon (cdr ham-geomagnetic-pole)) rad)))
    (/ (asin (max -1.0 (min 1.0
                            (+ (* (sin lat-r) (sin pole-lat))
                               (* (cos lat-r) (cos pole-lat) (cos delta))))))
       rad)))

(defun ham-solar-position (&optional time)
  "Return (DECLINATION . EQUATION-OF-TIME) for TIME, in degrees and minutes.
TIME defaults to now.  A standard low precision solar position, good to
a fraction of a degree, which is far finer than an ionospheric estimate
can use."
  (let* ((now (or time (current-time)))
         (day (string-to-number (format-time-string "%j" now t)))
         (rad (/ float-pi 180.0))
         (gamma (* (/ (* 2 float-pi) 365.0) (- day 1)))
         (declination
          (/ (- 0.006918
                (* 0.399912 (cos gamma)) (- (* 0.070257 (sin gamma)))
                (* 0.006758 (cos (* 2 gamma))) (- (* 0.000907 (sin (* 2 gamma))))
                (* 0.002697 (cos (* 3 gamma))) (- (* 0.00148 (sin (* 3 gamma)))))
             rad))
         (equation
          (* 229.18
             (- 0.000075
                (* 0.001868 (cos gamma)) (- (* 0.032077 (sin gamma)))
                (* 0.014615 (cos (* 2 gamma))) (- (* 0.040849 (sin (* 2 gamma))))))))
    (cons declination equation)))

(defun ham-solar-zenith-cosine (lat lon &optional time)
  "Return the cosine of the solar zenith angle at LAT and LON at TIME.
TIME defaults to now.

One is the sun overhead, zero the horizon, negative night.  Ionisation
of both the F2 and D layers follows this closely, so it is the single
most important quantity in any propagation estimate: it is what makes
the difference between a band being open and shut."
  (let* ((solar (ham-solar-position time))
         (declination (car solar))
         (equation (cdr solar))
         (rad (/ float-pi 180.0))
         (minutes (+ (* 60.0 (string-to-number
                              (format-time-string "%H" (or time (current-time)) t)))
                     (string-to-number
                      (format-time-string "%M" (or time (current-time)) t))))
         (true-solar (+ minutes equation (* 4.0 lon)))
         (hour-angle (- (/ true-solar 4.0) 180.0)))
    (max -1.0
         (min 1.0
              (+ (* (sin (* lat rad)) (sin (* declination rad)))
                 (* (cos (* lat rad)) (cos (* declination rad))
                    (cos (* hour-angle rad))))))))

(defun ham-maidenhead-to-latlon (grid)
  "Return (LATITUDE . LONGITUDE) for the centre of Maidenhead GRID.
GRID may be 4, 6 or 8 characters.  Signals an error otherwise."
  (let* ((g (upcase (string-trim grid)))
         (n (length g)))
    (unless (and (memq n '(4 6 8))
                 (string-match-p "\\`[A-R][A-R][0-9][0-9]\\([A-X][A-X]\\([0-9][0-9]\\)?\\)?\\'" g))
      (error "Invalid Maidenhead locator: %s" grid))
    (let ((lon (+ -180.0 (* 20.0 (- (aref g 0) ?A))))
          (lat (+ -90.0 (* 10.0 (- (aref g 1) ?A))))
          (lon-res 2.0)
          (lat-res 1.0))
      (setq lon (+ lon (* 2.0 (- (aref g 2) ?0)))
            lat (+ lat (* 1.0 (- (aref g 3) ?0))))
      (when (>= n 6)
        (setq lon-res (/ 2.0 24.0)
              lat-res (/ 1.0 24.0))
        (setq lon (+ lon (* lon-res (- (aref g 4) ?A)))
              lat (+ lat (* lat-res (- (aref g 5) ?A)))))
      (when (>= n 8)
        (setq lon-res (/ lon-res 10.0)
              lat-res (/ lat-res 10.0))
        (setq lon (+ lon (* lon-res (- (aref g 6) ?0)))
              lat (+ lat (* lat-res (- (aref g 7) ?0)))))
      (cons (+ lat (/ lat-res 2.0))
            (+ lon (/ lon-res 2.0))))))

(defun ham-latlon-to-maidenhead (lat lon &optional precision)
  "Return the Maidenhead locator for LAT and LON.
PRECISION is the number of characters: 4, 6 (default) or 8."
  (setq precision (or precision 6))
  (let* ((lat (+ (float lat) 90.0))
         (lon (+ (float lon) 180.0))
         (out (string (+ ?A (floor lon 20)) (+ ?A (floor lat 10)))))
    (setq lon (mod lon 20.0)
          lat (mod lat 10.0))
    (setq out (concat out (string (+ ?0 (floor lon 2)) (+ ?0 (floor lat 1)))))
    (when (>= precision 6)
      (setq lon (mod lon 2.0)
            lat (mod lat 1.0))
      (setq out (concat out (string (+ ?a (floor (/ lon (/ 2.0 24.0))))
                                    (+ ?a (floor (/ lat (/ 1.0 24.0))))))))
    (when (>= precision 8)
      (setq lon (mod lon (/ 2.0 24.0))
            lat (mod lat (/ 1.0 24.0)))
      (setq out (concat out (string (+ ?0 (floor (/ lon (/ 2.0 240.0))))
                                    (+ ?0 (floor (/ lat (/ 1.0 240.0))))))))
    out))

(defconst ham-earth-radius-km 6371.0
  "Mean Earth radius in kilometres.")

(defun ham-great-circle (lat1 lon1 lat2 lon2)
  "Return (DISTANCE-KM . BEARING-DEGREES) from point 1 to point 2.
Point 1 is LAT1 and LON1, point 2 is LAT2 and LON2, all in decimal
degrees.  BEARING is the initial short path bearing, 0 to 360 degrees
true."
  (let* ((p1 (degrees-to-radians lat1))
         (p2 (degrees-to-radians lat2))
         (dp (degrees-to-radians (- lat2 lat1)))
         (dl (degrees-to-radians (- lon2 lon1)))
         (a (+ (* (sin (/ dp 2)) (sin (/ dp 2)))
               (* (cos p1) (cos p2) (sin (/ dl 2)) (sin (/ dl 2)))))
         (c (* 2 (atan (sqrt a) (sqrt (- 1.0 a)))))
         (y (* (sin dl) (cos p2)))
         (x (- (* (cos p1) (sin p2))
               (* (sin p1) (cos p2) (cos dl)))))
    (cons (* ham-earth-radius-km c)
          (mod (+ 360.0 (radians-to-degrees (atan y x))) 360.0))))

(defun ham-grid-distance (grid1 grid2)
  "Return (DISTANCE-KM . BEARING-DEGREES) from GRID1 to GRID2.
Both are Maidenhead locators."
  (let ((a (ham-maidenhead-to-latlon grid1))
        (b (ham-maidenhead-to-latlon grid2)))
    (ham-great-circle (car a) (cdr a) (car b) (cdr b))))

(defun ham-km-to-miles (km)
  "Convert KM to statute miles."
  (* km 0.621371))


;;;; Band plan

(defconst ham-bands
  '(("2200m"    135700     137800)
    ("630m"     472000     479000)
    ("160m"    1800000    2000000)
    ("80m"     3500000    4000000)
    ("60m"     5330500    5406400)
    ("40m"     7000000    7300000)
    ("30m"    10100000   10150000)
    ("20m"    14000000   14350000)
    ("17m"    18068000   18168000)
    ("15m"    21000000   21450000)
    ("12m"    24890000   24990000)
    ("10m"    28000000   29700000)
    ("6m"     50000000   54000000)
    ("4m"     70000000   70500000)
    ("2m"    144000000  148000000)
    ("1.25m" 222000000  225000000)
    ("70cm"  420000000  450000000)
    ("33cm"  902000000  928000000)
    ("23cm" 1240000000 1300000000))
  "Amateur bands as (NAME LOW-HZ HIGH-HZ).
Ranges are generous supersets covering common regional allocations;
they identify a band, they do not authorise transmission on it.")

(defun ham-band-for-frequency (hz)
  "Return the band name containing HZ, or nil."
  (car (seq-find (lambda (b) (and (>= hz (nth 1 b)) (<= hz (nth 2 b))))
                 ham-bands)))

(defcustom ham-band-default-frequencies
  '(("160m"    1830000) ("80m"     3573000) ("60m"     5357000)
    ("40m"     7074000) ("30m"    10136000) ("20m"    14074000)
    ("17m"    18100000) ("15m"    21074000) ("12m"    24915000)
    ("10m"    28074000) ("6m"     50313000) ("2m"    144174000)
    ("70cm"  432100000))
  "Frequency to move to when switching to a band, as (NAME . HZ).
Defaults sit on or near common digital calling frequencies; adjust
to taste."
  :type '(alist :key-type string :value-type integer)
  :group 'ham)

(defun ham-band-default-frequency (band)
  "Return the default frequency in Hz for BAND, or nil."
  (cadr (assoc band ham-band-default-frequencies)))


;;;; Frequency formatting and parsing

(defcustom ham-frequency-format 'dotted
  "How to render frequencies.
`dotted' produces 14.074.000, `khz' produces 14074.000 kHz and
`mhz' produces 14.074000 MHz."
  :type '(choice (const dotted) (const khz) (const mhz))
  :group 'ham)

(defun ham-format-frequency (hz &optional style)
  "Format HZ as a string using STYLE or `ham-frequency-format'."
  (let ((hz (round hz)))
    (pcase (or style ham-frequency-format)
      ('khz (format "%.3f kHz" (/ hz 1000.0)))
      ('mhz (format "%.6f MHz" (/ hz 1000000.0)))
      (_ (let* ((mhz (/ hz 1000000))
                (rest (% hz 1000000)))
           (format "%d.%03d.%03d" mhz (/ rest 1000) (% rest 1000)))))))

(defun ham-parse-frequency (string)
  "Parse STRING into a frequency in Hz.

The rules, in order:
  two or more dots  -- grouped Hz, so 14.074.000 is 14074000 Hz
  one dot           -- MHz, so 14.074 is 14074000 Hz
  no dot, <= 6 digits -- kHz, so 14074 is 14074000 Hz
  no dot, > 6 digits  -- Hz

Signals an error if STRING is not a number."
  (let* ((s (replace-regexp-in-string "[ ,_]" "" (string-trim string)))
         (dots (cl-count ?. s)))
    (unless (string-match-p "\\`[0-9.]+\\'" s)
      (error "Not a frequency: %s" string))
    (cond
     ((>= dots 2) (string-to-number (replace-regexp-in-string "\\." "" s)))
     ((= dots 1) (round (* 1000000 (string-to-number s))))
     ((<= (length s) 6) (* 1000 (string-to-number s)))
     (t (string-to-number s)))))

(provide 'ham)
;;; ham.el ends here
