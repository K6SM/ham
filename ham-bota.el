;;; ham-bota.el --- Bunkers on the Air spots -*- lexical-binding: t; -*-

;; Copyright (C) 2026 K6SM

;; Author: K6SM
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (ham "0.7.0") (ham-spot "0.4.0"))
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

;; Worldwide Bunkers on the Air: wartime defences, mostly European and
;; mostly small, activated the way a park or a summit is.
;;
;;   https://api.wwbota.org/spots/?age=1
;;
;; WWBOTA does not answer with a list.  It holds the connection open
;; and pushes each spot as it happens, as Server-Sent Events -- a
;; stream of `data:' lines over one long-lived HTTPS request.  The
;; `age' parameter says how many hours of backlog to send first, so one
;; connection gives both the recent past and everything that follows.
;;
;; That makes this the only feed here that is neither a poll nor a
;; telnet session, and the reason `ham-connection' grew TLS: the same
;; line-oriented transport the cluster uses, wrapped in TLS, reading an
;; event stream instead of a chat room.
;;
;; A spot carries a `type'.  `Live' is somebody on the air; `QRT' is
;; somebody who has stopped, and it removes them from the panel rather
;; than adding anything -- which is better than waiting an hour for
;; their last spot to age out.  `Test' is somebody checking their
;; equipment.
;;
;; One activation can count for several bunkers at once, so the
;; references arrive as a list.
;;
;; The endpoint and the shape of a spot were taken from openhamclock's
;; useWWBOTASpots hook, which connects to this stream and works.

;;; Code:

(require 'ham)
(require 'ham-spot)
(require 'cl-lib)
(require 'subr-x)

(defgroup ham-bota nil
  "Bunkers on the Air spots."
  :group 'ham-spot
  :prefix "ham-bota-")

(defcustom ham-bota-host "api.wwbota.org"
  "Host serving the WWBOTA spot stream."
  :type 'string
  :group 'ham-bota)

(defcustom ham-bota-port 443
  "Port the WWBOTA API listens on."
  :type 'integer
  :group 'ham-bota)

(defcustom ham-bota-tls t
  "Whether to reach the WWBOTA API over TLS.
Only worth turning off to point this at a local server while testing."
  :type 'boolean
  :group 'ham-bota)

(defcustom ham-bota-path "/spots/"
  "Path of the spot stream on the WWBOTA API."
  :type 'string
  :group 'ham-bota)

(defcustom ham-bota-backlog-hours 1
  "Hours of past spots to ask for when the stream opens.

The stream sends this much history before it starts pushing, so the
panel has something in it immediately rather than waiting for whoever
is next on the air."
  :type 'integer
  :group 'ham-bota)

(defcustom ham-bota-include-tests nil
  "Whether to show spots marked as a test.

Somebody checking their equipment works rather than calling CQ.  Real
enough, but not somebody waiting to be worked."
  :type 'boolean
  :group 'ham-bota)

(defcustom ham-bota-programs nil
  "National programmes to show, by reference prefix, or nil for all.

A WWBOTA reference is `B/\=' then a national prefix and a number, as in
`B/G-0123\=' in the United Kingdom or `B/DL-0044\=' in Germany.  Setting
this to \\='(\"G\" \"GM\") shows Britain."
  :type '(choice (const :tag "Every programme" nil) (repeat string))
  :group 'ham-bota)


;;;; State

(defvar ham-bota--connection nil
  "The `ham-connection' carrying the event stream, or nil.")

(defvar ham-bota--reading nil
  "Where in the response the reader is: `headers', `body' or nil.")

(defvar ham-bota--http-status nil
  "The HTTP status line the server answered with.")

(defvar ham-bota--chunked nil
  "Non-nil if the response body is in HTTP chunks.")

(defvar ham-bota--raw ""
  "Response text received and not yet framed.")

(defvar ham-bota--event nil
  "The `data' lines of the event being read, newest first.")

(defvar ham-bota--status nil
  "A short string describing the state of the stream.")

(defvar ham-bota--spots 0
  "How many spots this connection has produced.")

(defvar ham-bota--last-event nil
  "When the stream last delivered anything.")


;;;; The event stream

(defun ham-bota-url ()
  "Return the URL of the spot stream, for display."
  (format "%s://%s%s%s?age=%d"
          (if ham-bota-tls "https" "http")
          ham-bota-host
          ;; The port only when it is not the one the scheme implies,
          ;; so the ordinary case reads as the address somebody would
          ;; type rather than as configuration.
          (if (equal ham-bota-port (if ham-bota-tls 443 80))
              ""
            (format ":%d" ham-bota-port))
          ham-bota-path
          (max 1 ham-bota-backlog-hours)))

(defun ham-bota--request ()
  "Return the HTTP request that opens the stream.

`Accept: text/event-stream\=' is what asks for the stream rather than a
document, and is the whole difference between this and an ordinary
GET."
  (concat
   (format "GET %s?age=%d HTTP/1.1\r\n" ham-bota-path
           (max 1 ham-bota-backlog-hours))
   (format "Host: %s\r\n" ham-bota-host)
   "Accept: text/event-stream\r\n"
   "Cache-Control: no-cache\r\n"
   (format "User-Agent: %s\r\n" ham-fetch-user-agent)
   ;; Asking for no compression: a gzipped event stream would arrive as
   ;; bytes this reader cannot make lines out of, and the saving on a
   ;; few spots an hour is nothing.
   "Accept-Encoding: identity\r\n"
   "Connection: keep-alive\r\n"
   "\r\n"))

;; The response is framed rather than read as lines.  An HTTP body is
;; usually sent in chunks, each introduced by its length on a line of
;; its own and followed by a blank one, and those lengths travel in the
;; same stream as the content.  A reader splitting the lot on newlines
;; hands them to the caller as though they were part of an event, and
;; worse, a chunk that ends mid-line splits that line in two -- so an
;; event large enough to be broken across chunks silently disappears.
;; Undoing the chunking before looking for lines is the only way round
;; that, and it has to happen on the raw text.

(defun ham-bota--on-chunk (text)
  "Take TEXT, the next of the response, and frame what it completes."
  (setq ham-bota--last-event (float-time))
  (setq ham-bota--raw (concat ham-bota--raw text))
  (when (eq ham-bota--reading 'headers)
    (ham-bota--read-headers))
  (when (eq ham-bota--reading 'body)
    (ham-bota--read-body)))

(defun ham-bota--read-headers ()
  "Read the status line and headers once all of them have arrived."
  (let ((end (string-search "\r\n\r\n" ham-bota--raw)))
    (when end
      (let* ((head (substring ham-bota--raw 0 end))
             (lines (split-string head "\r\n" t))
             (status (car lines)))
        (setq ham-bota--raw (substring ham-bota--raw (+ end 4)))
        (setq ham-bota--http-status (string-trim (or status "")))
        (setq ham-bota--chunked
              (and (seq-some (lambda (line)
                               (string-match-p
                                "\\`transfer-encoding:.*chunked" (downcase line)))
                             lines)
                   t))
        (if (string-match-p "\\` *HTTP/[0-9.]+ 2[0-9][0-9]" ham-bota--http-status)
            (progn
              (setq ham-bota--reading 'body)
              (setq ham-bota--status (format "%s, streaming" ham-bota-host)))
          ;; Anything else is a refusal, and it has a blank line after
          ;; its headers exactly as a good response does.  Reading on
          ;; would declare the stream open over the top of the error.
          (setq ham-bota--reading 'refused)
          (setq ham-bota--status
                (format "%s: %s" ham-bota-host ham-bota--http-status)))
        (ham-spot--schedule-redisplay)))))

(defun ham-bota--read-body ()
  "Take what can be read from the body and run it through the stream."
  (let ((body (if ham-bota--chunked
                  (ham-bota--dechunk)
                (prog1 ham-bota--raw (setq ham-bota--raw "")))))
    (when (and body (not (string-empty-p body)))
      (dolist (line (split-string body "\n"))
        (ham-bota--on-stream-line line)))))

(defun ham-bota--dechunk ()
  "Return whatever complete chunks are in the raw text, removing them.

A chunk is its length in hexadecimal, a newline, that many bytes, and
a newline.  A length with no body behind it yet, or a body that has not
all arrived, stays where it is until the rest turns up."
  (let ((out "")
        (done nil))
    (while (not done)
      (let ((eol (string-search "\r\n" ham-bota--raw)))
        (if (null eol)
            (setq done t)
          (let* ((header (substring ham-bota--raw 0 eol))
                 ;; A chunk length may carry extensions after a
                 ;; semicolon, which nothing here needs.
                 (size-text (car (split-string header ";")))
                 (size (and (string-match-p "\\`[0-9a-fA-F]+\\'"
                                            (string-trim size-text))
                            (string-to-number (string-trim size-text) 16))))
            (cond
             ;; Not a length at all.  The response is not chunked after
             ;; all, or something has gone wrong with the framing;
             ;; either way the rest is better read as content than
             ;; thrown away.
             ((null size)
              (setq ham-bota--chunked nil)
              (setq out (concat out ham-bota--raw))
              (setq ham-bota--raw "")
              (setq done t))
             ((zerop size)
              ;; The end of the body.  Nothing more will come.
              (setq ham-bota--raw "")
              (setq done t))
             ;; The whole chunk plus the newline that closes it.
             ((>= (length ham-bota--raw) (+ eol 2 size 2))
              (setq out (concat out (substring ham-bota--raw (+ eol 2)
                                               (+ eol 2 size))))
              (setq ham-bota--raw (substring ham-bota--raw (+ eol 2 size 2))))
             (t (setq done t)))))))
    out))

(defun ham-bota--on-stream-line (line)
  "Handle one LINE of the event stream itself."
  (let ((text (string-trim-right line "\r")))
    (cond
     ;; A blank line ends an event.  An event with nothing in it is
     ;; simply dropped: a stream that has been quiet for a while is
     ;; mostly blank lines and keepalives.
     ((string-empty-p text)
      (when ham-bota--event
        (let ((data (string-join (nreverse ham-bota--event) "\n")))
          (setq ham-bota--event nil)
          (ham-bota--on-event data))))
     ;; A line starting with a colon is a comment, and is how a server
     ;; keeps the connection from being dropped by something in the
     ;; middle while nobody is on the air.
     ((string-prefix-p ":" text) nil)
     ((string-prefix-p "data:" text)
      (push (string-trim (substring text 5)) ham-bota--event))
     ;; event:, id:, retry: and anything else this does not act on.
     (t nil))))

(defun ham-bota--on-event (data)
  "Handle one event's DATA, which should be a spot as JSON."
  (condition-case err
      (let ((record (ham-parse-json data)))
        (ham-bota--handle-record record))
    (error
     (setq ham-bota--status
           (format "%s: could not read a spot: %s"
                   ham-bota-host (error-message-string err))))))


;;;; Reading a spot

(defun ham-bota--references (record)
  "Return RECORD's bunker references, as a list of strings."
  (delq nil (mapcar (lambda (reference)
                      (let ((text (ham-json-string reference 'reference)))
                        (and text (upcase text))))
                    (ham-json-field record 'references))))

(defun ham-bota--reference-prefix (reference)
  "Return the national programme prefix of REFERENCE, or nil.

A reference is `B/\=' then the programme and a number, so B/G-0123 is
the G programme.  The `B/\=' is the same on every one of them and says
nothing."
  (when (and reference
             (string-match "\\`B/\\([A-Z0-9]+\\)-" (upcase reference)))
    (match-string 1 (upcase reference))))

(defun ham-bota--wanted-p (references)
  "Return non-nil if any of REFERENCES is in a programme being shown."
  (or (null ham-bota-programs)
      (seq-some (lambda (reference)
                  (member (ham-bota--reference-prefix reference)
                          ham-bota-programs))
                references)))

(defun ham-bota--name (record references)
  "Return the name to show for RECORD, which names REFERENCES.

One activation can count for several bunkers at once.  The first one is
named and the rest are counted, because the name of the second bunker
does not help anybody decide whether to call."
  (let* ((first (car (ham-json-field record 'references)))
         (name (and first (ham-json-string first 'name)))
         (extra (1- (length references))))
    (cond
     ((and name (> extra 0)) (format "%s (+%d)" name extra))
     (name name)
     ((> extra 0) (format "+%d more" extra)))))

(defun ham-bota--time (text)
  "Return TEXT, an ISO timestamp, as an Emacs time."
  (when text
    (ignore-errors
      (date-to-time
       (if (or (string-suffix-p "Z" text)
               (string-match-p "[+-][0-9][0-9]:?[0-9][0-9]\\'" text))
           text
         (concat text "Z"))))))

(defun ham-bota--frequency (record)
  "Return RECORD's frequency in hertz, or nil.

WWBOTA sends a number, and which unit it means is not stated anywhere.
Rather than assume, the magnitude decides: nothing in the amateur bands
is ambiguous between kilohertz and megahertz once the number is in
front of you.  14.062 can only be megahertz and 14062 can only be
kilohertz, because 14 kHz and 14 MHz are not both places a bunker is
being activated from."
  (let* ((value (ham-json-field record 'freq))
         (number (cond ((numberp value) (float value))
                       ((stringp value) (string-to-number value)))))
    (when (and number (> number 0))
      (let ((hz (cond
                 ;; Megahertz: 0.136 through 1300.
                 ((< number 2000) (round (* 1000000 number)))
                 ;; Kilohertz: 136 through 1,300,000.
                 ((< number 2000000) (round (* 1000 number)))
                 (t (round number)))))
        (and (ham-band-for-frequency hz) hz)))))

(defun ham-bota--handle-record (record)
  "Add, update or remove the spot RECORD describes."
  (let* ((call (ham-json-string record 'call))
         (type (or (ham-json-string record 'type) "Live"))
         (references (ham-bota--references record)))
    (when (and call (ham-bota--wanted-p references))
      (cond
       ;; Not a spot at all: an activator saying they have finished.
       ((string-equal-ignore-case type "QRT")
        (ham-spot-forget 'bota call))
       ((and (string-equal-ignore-case type "Test")
             (not ham-bota-include-tests))
        nil)
       (t
        (let ((hz (ham-bota--frequency record))
              (when-time (ham-bota--time (ham-json-string record 'time))))
          (when hz
            ;; One spot per activator: a bunker activation is a person,
            ;; and a later spot is them moving rather than a second
            ;; station.  Theirs goes before the new one is recorded, so
            ;; a move to another band replaces rather than doubles.
            (ham-spot-forget 'bota call)
            (cl-incf ham-bota--spots)
            (ham-spot-record
             (ham-spot-fill-mode
              (ham-spot-create
               :call (upcase call)
               :spotter (ham-json-string record 'spotter)
               :hz hz
               :mode (let ((mode (ham-json-string record 'mode)))
                       (and mode (upcase mode)))
               :when (or when-time (current-time))
               :source 'bota
               :reference (car references)
               :reference-name (ham-bota--name record references)
               :comment (ham-json-string record 'comment)
               :extra (list :program "WWBOTA"
                            :references references
                            :type type)))))))))))


;;;; Connecting

(defun ham-bota--on-status (state detail)
  "Note the stream moving to STATE, with DETAIL."
  (setq ham-bota--status
        (pcase state
          ('connected (format "%s, connected" ham-bota-host))
          ('connecting (format "%s, connecting" ham-bota-host))
          ('reconnecting (format "%s, reconnecting%s" ham-bota-host
                                 (if detail (format " (%s)" detail) "")))
          (_ (format "%s, %s" ham-bota-host (or detail state)))))
  (when (eq state 'connected)
    ;; Every connection is a fresh response: headers again, and no
    ;; half-read event or half-read chunk carried over from the one
    ;; that dropped.
    (setq ham-bota--reading 'headers
          ham-bota--http-status nil
          ham-bota--chunked nil
          ham-bota--raw ""
          ham-bota--event nil)
    (ham-connection-send ham-bota--connection (ham-bota--request)))
  (ham-spot--schedule-redisplay))

;;;###autoload
(defun ham-bota-connect ()
  "Open the WWBOTA spot stream."
  (interactive)
  (ham-bota-disconnect)
  (setq ham-bota--spots 0
        ham-bota--status (format "%s, connecting" ham-bota-host))
  (setq ham-bota--connection
        (ham-connection-make :name "ham-bota"
                             :host ham-bota-host
                             :port ham-bota-port
                             :tls ham-bota-tls
                             :on-chunk #'ham-bota--on-chunk
                             :on-status #'ham-bota--on-status))
  (ham-connection-open ham-bota--connection)
  (message "ham-bota: opening %s" (ham-bota-url)))

(defun ham-bota-disconnect ()
  "Close the WWBOTA spot stream."
  (interactive)
  (when ham-bota--connection
    (ham-connection-close ham-bota--connection))
  (setq ham-bota--connection nil
        ham-bota--reading nil
        ham-bota--http-status nil
        ham-bota--chunked nil
        ham-bota--raw ""
        ham-bota--event nil
        ham-bota--status nil))

(defun ham-bota-connected-p ()
  "Return non-nil if the stream is open."
  (ham-connection-live-p ham-bota--connection))

(defun ham-bota-status ()
  "Return a short description of the WWBOTA feed."
  (cond
   ((null ham-bota--connection) nil)
   ((ham-bota-connected-p)
    (format "WWBOTA: %s  %d spots" (or ham-bota--status "up") ham-bota--spots))
   (t (format "WWBOTA: %s" (or ham-bota--status "down")))))

;;;###autoload
(defun ham-bota ()
  "Open a spot panel showing WWBOTA activations."
  (interactive)
  (ham-spots 'bota))

(ham-spot-register-feed
 (ham-spot-feed-create
  :name 'bota
  :title "WWBOTA"
  :start (lambda () (unless (ham-bota-connected-p) (ham-bota-connect)))
  :stop #'ham-bota-disconnect
  :live-p #'ham-bota-connected-p
  :status #'ham-bota-status
  ;; Nothing to refresh: the stream pushes.  Reconnecting is the only
  ;; way to ask again, and it re-sends the backlog.
  :refresh (lambda () (unless (ham-bota-connected-p) (ham-bota-connect)))))

(provide 'ham-bota)
;;; ham-bota.el ends here
