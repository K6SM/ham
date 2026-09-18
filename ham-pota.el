;;; ham-pota.el --- Parks on the Air spots -*- lexical-binding: t; -*-

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

;; Parks on the Air: somebody sitting in a park with a wire in a tree,
;; and a queue of people trying to work them.  POTA publishes who is
;; currently on the air as JSON, and this turns that into spots.
;;
;;   https://api.pota.app/spot/activator
;;
;; Frequency arrives in kilohertz, as a string.  SOTA's arrives in
;; megahertz, also as a string.  Neither says which it is.
;;
;; The answer is the whole current list every time, so it replaces what
;; this feed had rather than merging: an activator who has packed up is
;; simply absent from the next answer, and a merge would leave them on
;; the panel for an hour looking exactly like somebody still calling CQ.
;;
;; No account or key is needed.  The endpoint is public and read-only.

;;; Code:

(require 'ham)
(require 'ham-spot)
(require 'cl-lib)
(require 'subr-x)

(defgroup ham-pota nil
  "Parks on the Air spots."
  :group 'ham-spot
  :prefix "ham-pota-")

(defcustom ham-pota-url "https://api.pota.app/spot/activator"
  "Where to read current POTA activations.

The `spot/activator\=' endpoint rather than plain `spot\=': it carries the
park name, the grid and the coordinates, which is what lets the panel
say how far away a park is."
  :type 'string
  :group 'ham-pota)

(defcustom ham-pota-interval 120
  "Seconds between reads of the POTA API.

POTA publishes no rate limit, which is a reason to be careful rather
than a licence: this is one radio's panel, not a service, and a park
that has been spotted is not going anywhere in the next two minutes."
  :type 'integer
  :group 'ham-pota)

(defcustom ham-pota-minimum-interval 60
  "Shortest gap between reads, however often a refresh is asked for."
  :type 'integer
  :group 'ham-pota)

(defcustom ham-pota-include-rbn t
  "Whether to include spots the Reverse Beacon Network produced.

POTA relays RBN decodes as spots, marked with a source of `RBN\='.  They
are how a CW activator gets spotted without stopping to do it
themselves, so they are usually wanted -- but they are a machine
hearing a callsign, not a person listening, and there are a great many
of them."
  :type 'boolean
  :group 'ham-pota)

(defcustom ham-pota-programs nil
  "Park programs to show, by reference prefix, or nil for all of them.

A POTA reference begins with the country's prefix -- `K\=' for the United
States, `VE\=' for Canada, `G\=' for the United Kingdom.  Setting this to
\\='(\"K\" \"VE\") shows North American parks only.

This is one of the things the separate panels are for: the reference
prefix says which program a park belongs to, and Canadian Parks on the
Air is POTA's `VE\=' references rather than a separate feed."
  :type '(choice (const :tag "Every program" nil) (repeat string))
  :group 'ham-pota)


;;;; Reading the answer

(defun ham-pota--reference-prefix (reference)
  "Return the program prefix of REFERENCE, or nil.
A POTA reference is a prefix, a hyphen and a number: K-1234, VE-0001."
  (when (and reference (string-match "\\`\\([A-Z0-9]+\\)-" (upcase reference)))
    (match-string 1 (upcase reference))))

(defun ham-pota--wanted-p (reference)
  "Return non-nil if REFERENCE belongs to a program being shown."
  (or (null ham-pota-programs)
      (member (ham-pota--reference-prefix reference) ham-pota-programs)))

(defun ham-pota--time (text)
  "Return TEXT as an Emacs time.

POTA writes `2026-09-18T09:20:33\=' with no zone marker at all, and it is
UTC.  Read as local time it is wrong by the offset -- which in the
Americas makes every spot several hours old on arrival, so the panel
shows nothing and nothing says why."
  (when text
    (ignore-errors
      (date-to-time (if (or (string-suffix-p "Z" text)
                            (string-match-p "[+-][0-9][0-9]:?[0-9][0-9]\\'" text))
                        text
                      (concat text "Z"))))))

(defun ham-pota--spot (record)
  "Return the `ham-spot' RECORD describes, or nil.

A record is skipped when POTA has flagged it invalid, when its program
is not being shown, when its frequency is not in a band, or when the
RBN produced it and those are not wanted."
  (let* ((activator (ham-json-string record 'activator))
         (reference (ham-json-string record 'reference))
         (khz (ham-json-string record 'frequency))
         (hz (and khz (round (* 1000 (string-to-number khz)))))
         (source (ham-json-string record 'source))
         (invalid (ham-json-string record 'invalid))
         (when-time (ham-pota--time (ham-json-string record 'spotTime))))
    (when (and activator hz (> hz 0)
               (null invalid)
               (ham-band-for-frequency hz)
               (ham-pota--wanted-p reference)
               (or ham-pota-include-rbn
                   (not (equal (and source (upcase source)) "RBN"))))
      (ham-spot-fill-mode
       (ham-spot-create
        :call (upcase activator)
        :spotter (ham-json-string record 'spotter)
        :hz hz
        :mode (ham-json-string record 'mode)
        :when (or when-time (current-time))
        :source 'pota
        :grid (or (ham-json-string record 'grid6)
                  (ham-json-string record 'grid4))
        :reference (and reference (upcase reference))
        ;; The park's name is `name' on this endpoint and `parkName' on
        ;; the other one, and either may be absent.
        :reference-name (or (ham-json-string record 'name)
                            (ham-json-string record 'parkName)
                            (ham-json-string record 'locationDesc))
        :comment (ham-json-string record 'comments)
        :extra (list :program "POTA" :spot-source source))))))

(defun ham-pota--parse (data)
  "Return the spots in DATA, the decoded POTA answer.

The answer is a JSON array.  Anything else -- an object carrying an
error, a login page from a captive portal -- is not one, and saying so
is better than returning nothing and letting the panel look merely
quiet."
  (unless (listp data)
    (error "Expected a list of spots"))
  (when (and data (not (listp (car data))))
    (error "Expected a list of spots, got %S" (type-of (car data))))
  (delq nil (mapcar #'ham-pota--spot data)))


;;;; The feed

(defvar ham-pota--poller
  (ham-spot-poller-create
   :source 'pota
   :url (lambda () ham-pota-url)
   :parse #'ham-pota--parse
   :interval ham-pota-interval
   :minimum ham-pota-minimum-interval)
  "The polling state for POTA.")

(defun ham-pota-start ()
  "Begin reading POTA spots."
  (interactive)
  (setf (ham-spot-poller-interval ham-pota--poller) ham-pota-interval
        (ham-spot-poller-minimum ham-pota--poller) ham-pota-minimum-interval)
  (ham-spot-poller-start ham-pota--poller))

(defun ham-pota-stop ()
  "Stop reading POTA spots."
  (interactive)
  (ham-spot-poller-stop ham-pota--poller))

(defun ham-pota-refresh ()
  "Read POTA now, unless its minimum interval has not yet passed."
  (interactive)
  (ham-spot-poller-fetch ham-pota--poller t))

(defun ham-pota-status ()
  "Return a short description of the POTA feed."
  (ham-spot-poller-status ham-pota--poller "POTA"))

;;;###autoload
(defun ham-pota ()
  "Open a spot panel showing POTA activations."
  (interactive)
  (ham-spots 'pota))

(ham-spot-register-feed
 (ham-spot-feed-create
  :name 'pota
  :title "POTA"
  :start #'ham-pota-start
  :stop #'ham-pota-stop
  :live-p (lambda () (ham-spot-poller-running-p ham-pota--poller))
  :status #'ham-pota-status
  :refresh #'ham-pota-refresh))

(provide 'ham-pota)
;;; ham-pota.el ends here
