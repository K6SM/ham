;;; ham-sota.el --- Summits on the Air spots -*- lexical-binding: t; -*-

;; Copyright (C) 2026 K6SM

;; Author: K6SM
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (ham "0.6.0") (ham-spot "0.2.0"))
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

;; Summits on the Air: the same idea as POTA, up a hill, and usually
;; with less power and a worse antenna, which is why a summit spot is
;; worth acting on quickly.
;;
;;   https://api-db2.sota.org.uk/api/spots/120/all/all
;;
;; Two things differ from POTA and both are traps.
;;
;; FREQUENCY IS IN MEGAHERTZ.  POTA sends kilohertz.  Both send it as a
;; string and neither says which it is, so a parser written for one and
;; pointed at the other is wrong by a thousand and lands the radio in
;; another band entirely.
;;
;; THE OLD HOST STILL ANSWERS.  api2.sota.org.uk is retired, but it
;; does not say so in a way a program notices: it returns HTTP 200 and
;; a list of placeholder records with DEPRECATED where the callsign
;; should be.  A client pointed at it looks like it is working and
;; shows spots that are not real.  This reads api-db2.sota.org.uk, and
;; checks the answer for those placeholders so that a stale setting
;; produces a plain error rather than fiction.
;;
;; The spots endpoint takes a lookback window in minutes rather than a
;; count, which the old one took.  SOTA asks for no more than one
;; request a minute.

;;; Code:

(require 'ham)
(require 'ham-spot)
(require 'cl-lib)
(require 'subr-x)

(defgroup ham-sota nil
  "Summits on the Air spots."
  :group 'ham-spot
  :prefix "ham-sota-")

(defcustom ham-sota-host "https://api-db2.sota.org.uk"
  "The SOTA database API.

Not api2.sota.org.uk, which is retired and answers with placeholder
records rather than an error."
  :type 'string
  :group 'ham-sota)

(defcustom ham-sota-window 120
  "Minutes of spots to ask for.

The endpoint takes a lookback window rather than a count.  Asking for
much more than `ham-spot-max-age\=' only fetches spots the panel will
then drop."
  :type 'integer
  :group 'ham-sota)

(defcustom ham-sota-interval 120
  "Seconds between reads of the SOTA API."
  :type 'integer
  :group 'ham-sota)

(defcustom ham-sota-minimum-interval 60
  "Shortest gap between reads.

SOTA asks for no more than one request a minute.  This is their rule,
not a preference, so it is applied to a manual refresh too."
  :type 'integer
  :group 'ham-sota)

(defcustom ham-sota-associations nil
  "Associations to show, by code, or nil for all of them.

A SOTA reference is an association and a summit: `G/LD-007\=' is summit
LD-007 in the G association.  Setting this to \\='(\"W7W\" \"W7O\") shows
the Pacific Northwest only."
  :type '(choice (const :tag "Every association" nil) (repeat string))
  :group 'ham-sota)


;;;; Reading the answer

(defun ham-sota-url ()
  "Return the URL for the current settings.

`all/all\=' is the pair of filters the endpoint takes -- by callsign and
by association -- with both left open.  Filtering here instead keeps
one request serving every setting."
  (format "%s/api/spots/%d/all/all"
          (string-trim-right ham-sota-host "/")
          (max 1 ham-sota-window)))

(defun ham-sota--reference (record)
  "Return the summit reference RECORD names.

The current API returns `summitCode\=' already joined as ASSOCIATION and
SUMMIT, as in G/LD-007.  An older shape kept the two apart, and this
accepts that as well rather than producing LD-007 with the association
silently missing."
  (let ((summit (ham-json-string record 'summitCode))
        (association (ham-json-string record 'associationCode)))
    (cond
     ((null summit) nil)
     ((string-search "/" summit) (upcase summit))
     (association (upcase (concat association "/" summit)))
     (t (upcase summit)))))

(defun ham-sota--association (reference)
  "Return the association part of REFERENCE, or nil."
  (when (and reference (string-search "/" reference))
    (car (split-string reference "/"))))

(defun ham-sota--wanted-p (reference)
  "Return non-nil if REFERENCE is in an association being shown."
  (or (null ham-sota-associations)
      (member (ham-sota--association reference) ham-sota-associations)))

(defun ham-sota--time (text)
  "Return TEXT as an Emacs time.

SOTA writes its timestamps in UTC and does not always mark them as
such, so an unmarked one is read as UTC rather than as local."
  (when text
    (ignore-errors
      (date-to-time
       (if (or (string-suffix-p "Z" text)
               (string-match-p "[+-][0-9][0-9]:?[0-9][0-9]\\'" text))
           text
         (concat text "Z"))))))

(defconst ham-sota--deprecated-marker "DEPRECATED"
  "What the retired API puts where a callsign should be.")

(defun ham-sota--deprecated-p (data)
  "Return non-nil if DATA is the retired API's placeholder answer.

It answers HTTP 200 with a list of records saying DEPRECATED, which
every layer below this reads as a perfectly good list of spots."
  (and (listp data) data
       (seq-some (lambda (record)
                   (and (listp record)
                        (seq-some
                         (lambda (field)
                           (let ((value (ham-json-string record field)))
                             (and value
                                  (string-match-p ham-sota--deprecated-marker
                                                  (upcase value)))))
                         '(activatorCallsign callsign comments summitCode))))
                 (seq-take data 5))))

(defun ham-sota--spot (record)
  "Return the `ham-spot' RECORD describes, or nil."
  (let* ((activator (ham-json-string record 'activatorCallsign))
         (mhz (ham-json-string record 'frequency))
         ;; Megahertz, not kilohertz.  This is the line that matters.
         (hz (and mhz (round (* 1000000 (string-to-number mhz)))))
         (reference (ham-sota--reference record))
         (when-time (ham-sota--time (ham-json-string record 'timeStamp))))
    (when (and activator hz (> hz 0)
               (ham-band-for-frequency hz)
               (ham-sota--wanted-p reference))
      (ham-spot-fill-mode
       (ham-spot-create
        :call (upcase activator)
        :spotter (ham-json-string record 'callsign)
        :hz hz
        ;; SOTA writes its modes in lower case, and every other feed
        ;; here writes them in upper.
        :mode (let ((mode (ham-json-string record 'mode)))
                (and mode (upcase mode)))
        :when (or when-time (current-time))
        :source 'sota
        :reference reference
        :reference-name (or (ham-json-string record 'summitName)
                            (ham-json-string record 'summitDetails))
        :comment (ham-json-string record 'comments)
        :extra (list :program "SOTA"
                     :association (ham-sota--association reference)))))))

(defun ham-sota--parse (data)
  "Return the spots in DATA, the decoded SOTA answer."
  (unless (listp data)
    (error "Expected a list of spots"))
  (when (ham-sota--deprecated-p data)
    (error "This host is retired and is sending placeholder spots.  \
Set `ham-sota-host' to https://api-db2.sota.org.uk"))
  (delq nil (mapcar #'ham-sota--spot data)))


;;;; The feed

(defvar ham-sota--poller
  (ham-spot-poller-create
   :source 'sota
   :url #'ham-sota-url
   :parse #'ham-sota--parse
   :interval ham-sota-interval
   :minimum ham-sota-minimum-interval)
  "The polling state for SOTA.")

(defun ham-sota-start ()
  "Begin reading SOTA spots."
  (interactive)
  (setf (ham-spot-poller-interval ham-sota--poller) ham-sota-interval
        (ham-spot-poller-minimum ham-sota--poller) ham-sota-minimum-interval)
  (ham-spot-poller-start ham-sota--poller))

(defun ham-sota-stop ()
  "Stop reading SOTA spots."
  (interactive)
  (ham-spot-poller-stop ham-sota--poller))

(defun ham-sota-refresh ()
  "Read SOTA now, unless its minimum interval has not yet passed."
  (interactive)
  (ham-spot-poller-fetch ham-sota--poller t))

(defun ham-sota-status ()
  "Return a short description of the SOTA feed."
  (ham-spot-poller-status ham-sota--poller "SOTA"))

;;;###autoload
(defun ham-sota ()
  "Open a spot panel showing SOTA activations."
  (interactive)
  (ham-spots 'sota))

(ham-spot-register-feed
 (ham-spot-feed-create
  :name 'sota
  :title "SOTA"
  :start #'ham-sota-start
  :stop #'ham-sota-stop
  :live-p (lambda () (ham-spot-poller-running-p ham-sota--poller))
  :status #'ham-sota-status
  :refresh #'ham-sota-refresh))

(provide 'ham-sota)
;;; ham-sota.el ends here
