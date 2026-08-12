;;; ham.el --- Core library for amateur radio packages -*- lexical-binding: t; -*-

;; Copyright (C) 2026 K6SM

;; Author: K6SM
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: comm, hardware
;; URL: https://github.com/K6SM/ham.el

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


;;;; Logging and instrumentation

(defcustom ham-debug nil
  "When non-nil, record diagnostic messages in `ham-log-buffer-name'.
This is intended to stay off in normal use; the logging path is
cheap but not free, and it is on the hot path for rig polling."
  :type 'boolean
  :group 'ham)

(defcustom ham-log-buffer-name "*ham-log*"
  "Name of the buffer used for diagnostic logging."
  :type 'string
  :group 'ham)

(defcustom ham-log-max-lines 2000
  "Maximum number of lines retained in the log buffer."
  :type 'integer
  :group 'ham)

(defun ham-log (format-string &rest args)
  "Append a diagnostic line to the log buffer when `ham-debug' is non-nil.
FORMAT-STRING and ARGS are passed to `format'."
  (when ham-debug
    (let ((line (apply #'format format-string args))
          (stamp (format-time-string "%H:%M:%S.%3N")))
      (with-current-buffer (get-buffer-create ham-log-buffer-name)
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (point-max))
            (insert stamp " " line "\n")
            (when (> (line-number-at-pos (point-max)) ham-log-max-lines)
              (goto-char (point-min))
              (forward-line (- (line-number-at-pos (point-max))
                               ham-log-max-lines))
              (delete-region (point-min) (point)))))))))

;;;###autoload
(defun ham-show-log ()
  "Display the diagnostic log buffer."
  (interactive)
  (pop-to-buffer (get-buffer-create ham-log-buffer-name))
  (special-mode))


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
  (ham-log "publish %s %S" topic args)
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

(cl-defstruct (ham-connection (:constructor ham--connection-create)
                              (:copier nil))
  "A line-oriented asynchronous TCP connection."
  name host port process
  (pending "")
  on-line on-status
  (state 'disconnected)
  (auto-reconnect t)
  (backoff nil)
  (reconnect-timer nil)
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
    (ham-log "%s: state -> %s%s" (ham-connection-name conn) state
             (if detail (format " (%s)" detail) ""))
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
        (ham-log "%s < %s" (ham-connection-name conn) line)
        (when (ham-connection-on-line conn)
          (with-demoted-errors "ham-connection: line handler error: %S"
            (funcall (ham-connection-on-line conn) line))))
      (setq start (1+ idx)))
    (setf (ham-connection-pending conn) (substring text start))))

(defun ham--connection-schedule-reconnect (conn)
  "Arrange for CONN to be retried after its current backoff delay."
  (when (and (ham-connection-auto-reconnect conn)
             (not (ham-connection-reconnect-timer conn)))
    (let ((delay (or (ham-connection-backoff conn)
                     ham-reconnect-initial-delay)))
      (setf (ham-connection-backoff conn)
            (min ham-reconnect-max-delay (* 2 delay)))
      (ham--connection-set-state conn 'reconnecting (format "%.1fs" delay))
      (setf (ham-connection-reconnect-timer conn)
            (run-at-time delay nil
                         (lambda ()
                           (setf (ham-connection-reconnect-timer conn) nil)
                           (ham-connection-open conn)))))))

(defun ham--connection-sentinel (conn event)
  "Handle a process EVENT for CONN."
  (cond
   ((string-prefix-p "open" event)
    (setf (ham-connection-backoff conn) ham-reconnect-initial-delay)
    (ham--connection-set-state conn 'connected))
   ((string-match-p "\\`\\(failed\\|connection broken\\)" event)
    (ham--connection-set-state conn 'disconnected (string-trim event))
    (ham--connection-schedule-reconnect conn))
   ((string-match-p "\\`\\(deleted\\|finished\\|exited\\|killed\\)" event)
    (ham--connection-set-state conn 'disconnected (string-trim event))
    (ham--connection-schedule-reconnect conn))))

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

(defun ham-connection-open (conn)
  "Open CONN asynchronously.  Returns CONN."
  (when (ham-connection-process conn)
    (ignore-errors (delete-process (ham-connection-process conn))))
  (setf (ham-connection-pending conn) "")
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
             :filter (lambda (_proc chunk) (ham--connection-filter conn chunk))
             :sentinel (lambda (_proc event) (ham--connection-sentinel conn event))))
    (error
     (ham--connection-set-state conn 'disconnected (error-message-string err))
     (ham--connection-schedule-reconnect conn)))
  conn)

(defun ham-connection-close (conn)
  "Close CONN and cancel any pending reconnection."
  (setf (ham-connection-auto-reconnect conn) nil)
  (when (ham-connection-reconnect-timer conn)
    (cancel-timer (ham-connection-reconnect-timer conn))
    (setf (ham-connection-reconnect-timer conn) nil))
  (when (ham-connection-process conn)
    (ignore-errors (delete-process (ham-connection-process conn)))
    (setf (ham-connection-process conn) nil))
  (ham--connection-set-state conn 'disconnected "closed"))

(defun ham-connection-send (conn string)
  "Send STRING over CONN.  Returns non-nil on success.
A newline is appended if STRING does not already end with one."
  (when (ham-connection-live-p conn)
    (let ((payload (if (string-suffix-p "\n" string) string (concat string "\n"))))
      (ham-log "%s > %s" (ham-connection-name conn) (string-trim-right payload))
      (cl-incf (ham-connection-lines-out conn))
      (condition-case err
          (progn (process-send-string (ham-connection-process conn) payload) t)
        (error
         (ham-log "%s: send failed: %s" (ham-connection-name conn)
                  (error-message-string err))
         nil)))))


;;;; Geodesy

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
BEARING is the initial short path bearing, 0 to 360 degrees true."
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
  "Return (DISTANCE-KM . BEARING-DEGREES) between two Maidenhead locators."
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
