;;; ham-wwff.el --- World Wide Flora and Fauna spots -*- lexical-binding: t; -*-

;; Copyright (C) 2026 K6SM

;; Author: K6SM
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (ham "0.7.0") (ham-spot "0.3.0"))
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

;; World Wide Flora and Fauna: nature reserves rather than parks, and
;; the programme POTA was modelled on.  Plenty of references are both,
;; so the same operator turns up in both panels under two different
;; numbers.
;;
;;   https://spots.wwff.co/static/spots.json
;;
;; A third frequency convention, to go with the two already here.  POTA
;; sends kilohertz as a string, SOTA sends megahertz as a string, and
;; WWFF sends kilohertz as a number.  Nothing in any of the three says
;; which it is.
;;
;; And a second timestamp convention: `spot_time' is Unix epoch
;; seconds, where POTA and SOTA both send text.  Epoch seconds are at
;; least unambiguous, which is more than can be said for a bare
;; 2026-09-20T09:20:33 that turns out to be UTC.
;;
;; WWFF asks for no more than one request a minute.

;;; Code:

(require 'ham)
(require 'ham-spot)
(require 'cl-lib)
(require 'subr-x)

(defgroup ham-wwff nil
  "World Wide Flora and Fauna spots."
  :group 'ham-spot
  :prefix "ham-wwff-")

(defcustom ham-wwff-url "https://spots.wwff.co/static/spots.json"
  "Where to read current WWFF activations."
  :type 'string
  :group 'ham-wwff)

(defcustom ham-wwff-interval 120
  "Seconds between reads of the WWFF spot file."
  :type 'integer
  :group 'ham-wwff)

(defcustom ham-wwff-minimum-interval 60
  "Shortest gap between reads.

WWFF asks for no more than one request a minute, so this is applied to
a manual refresh as well."
  :type 'integer
  :group 'ham-wwff)

(defcustom ham-wwff-programs nil
  "National programmes to show, by reference prefix, or nil for all.

A WWFF reference is a national programme and a number: `KFF-0001\=' in
the United States, `GFF-0001\=' in the United Kingdom, `DLFF-0001\=' in
Germany.  Setting this to \\='(\"KFF\" \"VEFF\") shows North America."
  :type '(choice (const :tag "Every programme" nil) (repeat string))
  :group 'ham-wwff)


;;;; Reading the answer

(defun ham-wwff--reference-prefix (reference)
  "Return the national programme prefix of REFERENCE, or nil."
  (when (and reference (string-match "\\`\\([A-Z0-9]+\\)-" (upcase reference)))
    (match-string 1 (upcase reference))))

(defun ham-wwff--wanted-p (reference)
  "Return non-nil if REFERENCE belongs to a programme being shown."
  (or (null ham-wwff-programs)
      (member (ham-wwff--reference-prefix reference) ham-wwff-programs)))

(defun ham-wwff--time (record)
  "Return the moment RECORD was spotted.

`spot_time\=' is Unix epoch seconds.  A very small number there is not a
time at all -- 1970 is not when anybody was on the air -- so it falls
back to the formatted field, and then to now."
  (let ((epoch (ham-json-field record 'spot_time)))
    (cond
     ((and (numberp epoch) (> epoch 946684800))    ; after 2000
      (seconds-to-time epoch))
     ((and (stringp epoch) (> (string-to-number epoch) 946684800))
      (seconds-to-time (string-to-number epoch)))
     (t
      (let ((text (ham-json-string record 'spot_time_formatted)))
        (and text
             (ignore-errors
               (date-to-time
                (if (or (string-suffix-p "Z" text)
                        (string-match-p "[+-][0-9][0-9]:?[0-9][0-9]\\'" text))
                    text
                  (concat text "Z"))))))))))

(defun ham-wwff--spot (record)
  "Return the `ham-spot' RECORD describes, or nil."
  (let* ((activator (ham-json-string record 'activator))
         (reference (ham-json-string record 'reference))
         ;; Kilohertz, and a number rather than a string -- so read it
         ;; as a field and not as text, or a JSON integer arrives as
         ;; "14074" and a float as "14074.0" and only one of them
         ;; survives being rounded.
         (khz (let ((value (ham-json-field record 'frequency_khz)))
                (cond ((numberp value) value)
                      ((stringp value) (string-to-number value)))))
         (hz (and khz (round (* 1000 khz))))
         (when-time (ham-wwff--time record)))
    (when (and activator hz (> hz 0)
               (ham-band-for-frequency hz)
               (ham-wwff--wanted-p reference))
      (ham-spot-fill-mode
       (ham-spot-create
        :call (upcase activator)
        :spotter (ham-json-string record 'spotter)
        :hz hz
        :mode (let ((mode (ham-json-string record 'mode)))
                (and mode (upcase mode)))
        :when (or when-time (current-time))
        :source 'wwff
        :reference (and reference (upcase reference))
        :reference-name (ham-json-string record 'reference_name)
        ;; The comment is `remarks' here and `comments' everywhere else.
        :comment (or (ham-json-string record 'remarks)
                     (ham-json-string record 'comments))
        :extra (list :program "WWFF"))))))

(defun ham-wwff--parse (data)
  "Return the spots in DATA, the decoded WWFF answer."
  (unless (listp data)
    (error "Expected a list of spots"))
  (when (and data (not (listp (car data))))
    (error "Expected a list of spots, got %S" (type-of (car data))))
  (delq nil (mapcar #'ham-wwff--spot data)))


;;;; The feed

(defvar ham-wwff--poller
  (ham-spot-poller-create
   :source 'wwff
   :url (lambda () ham-wwff-url)
   :parse #'ham-wwff--parse
   :interval ham-wwff-interval
   :minimum ham-wwff-minimum-interval)
  "The polling state for WWFF.")

(defun ham-wwff-start ()
  "Begin reading WWFF spots."
  (interactive)
  (setf (ham-spot-poller-interval ham-wwff--poller) ham-wwff-interval
        (ham-spot-poller-minimum ham-wwff--poller) ham-wwff-minimum-interval)
  (ham-spot-poller-start ham-wwff--poller))

(defun ham-wwff-stop ()
  "Stop reading WWFF spots."
  (interactive)
  (ham-spot-poller-stop ham-wwff--poller))

(defun ham-wwff-refresh ()
  "Read WWFF now, unless its minimum interval has not yet passed."
  (interactive)
  (ham-spot-poller-fetch ham-wwff--poller t))

(defun ham-wwff-status ()
  "Return a short description of the WWFF feed."
  (ham-spot-poller-status ham-wwff--poller "WWFF"))

;;;###autoload
(defun ham-wwff ()
  "Open a spot panel showing WWFF activations."
  (interactive)
  (ham-spots 'wwff))

(ham-spot-register-feed
 (ham-spot-feed-create
  :name 'wwff
  :title "WWFF"
  :start #'ham-wwff-start
  :stop #'ham-wwff-stop
  :live-p (lambda () (ham-spot-poller-running-p ham-wwff--poller))
  :status #'ham-wwff-status
  :refresh #'ham-wwff-refresh))

(provide 'ham-wwff)
;;; ham-wwff.el ends here
