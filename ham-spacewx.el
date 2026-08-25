;;; ham-spacewx.el --- Space weather and propagation indices -*- lexical-binding: t; -*-

;; Copyright (C) 2026 K6SM

;; Author: K6SM
;; Version: 0.12.1
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

;; A space weather panel for HF operators, reading the public feeds
;; published by the NOAA Space Weather Prediction Center.
;;
;; `M-x ham-spacewx' opens the panel.  Everything renders as text, with
;; sparklines drawn from Unicode block characters, so the panel is
;; complete in a terminal frame.  A later revision adds images on top of
;; this layer for frames that can show them; nothing here depends on
;; that, and nothing here will be replaced by it.
;;
;; Fetching is asynchronous and rate limited.  Each source declares how
;; often it is worth re-reading, and `ham-spacewx-refresh' skips any
;; source whose data is still inside that window.  Sources fail
;; independently: a feed that times out shows as unavailable and leaves
;; the rest of the panel intact.
;;
;; Every endpoint is a `defcustom'.  NOAA reorganises its service tree
;; from time to time, and a moved feed should be a setting to correct
;; rather than a patch to apply.  Parsing looks columns up by their
;; header name rather than by position, so a feed that grows a column
;; does not break.
;;
;; Readings are published on the `ham-spacewx-updated' topic for any
;; other package that wants them.

;;; Code:

(require 'ham)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'url-queue)


;;;; Customization

(defgroup ham-spacewx nil
  "Space weather and propagation indices."
  :group 'ham
  :prefix "ham-spacewx-")

(defcustom ham-spacewx-buffer-name "*ham-spacewx*"
  "Name of the space weather panel buffer."
  :type 'string
  :group 'ham-spacewx)

(defcustom ham-spacewx-auto-refresh-interval 600
  "Seconds between automatic refreshes while the panel is displayed.
Set to nil to refresh only on demand.  This is the interval at which
`ham-spacewx-refresh' is called; each source still applies its own
minimum interval, so a short value here does not increase the load on
any single feed."
  :type '(choice (const :tag "Manual only" nil) integer)
  :group 'ham-spacewx)

(defcustom ham-spacewx-series-length 30
  "Number of samples to draw in a sparkline.
`ham-spacewx-metric-views' overrides this for individual metrics."
  :type 'integer
  :group 'ham-spacewx)

(defcustom ham-spacewx-metric-views
  '((speed    :samples 60 :units 30)
    (density  :samples 60 :units 30)
    (bt       :samples 60 :units 30)
    (bz       :samples 60 :units 30)
    (xray     :samples 60 :units 30)
    (kp       :days 5 :units 30)
    (a-index  :days 5 :units 30)
    (flux     :days 5 :units 30)
    (xray-max :days 5 :units 30 :aggregate max)
    (protons  :days 5 :units 30 :aggregate max)
    (sunspots :days 30 :units 30))
  "How much of each metric to draw, and how wide to draw it.

Each entry is (METRIC . PLIST) accepting:

  :samples N    draw the last N samples, one character each.
  :days N       draw the last N days, however many samples that is.
  :units N      redistribute the window into N characters, so rows
                covering the same period line up column for column
                whatever their native cadence.  A daily reading with
                five samples and a one minute reading with thousands
                both become N wide.
  :aggregate    how to combine samples sharing a bucket: `mean' by
                default, or `max' to keep peaks.  A peak is the point
                of a flare or proton trace, and averaging erases it."
  :type '(alist :key-type symbol :value-type plist)
  :group 'ham-spacewx)

(defcustom ham-spacewx-stale-after 3600
  "Seconds after which a reading is marked stale in the panel.
Space weather data that is hours old can be actively misleading, so the
panel says so rather than presenting it as current."
  :type 'integer
  :group 'ham-spacewx)

(defcustom ham-spacewx-fetch-backend 'auto
  "How feeds are fetched.

`url' uses Emacs's own `url.el'.  Its connection setup is not reliably
asynchronous — name resolution in particular can block — so a machine
whose network is down freezes Emacs for as long as the requests take to
give up.  That is what makes the panel feel unresponsive after a
resume.

`curl' runs the request as a subprocess.  `make-process' never blocks
the command loop, so Emacs stays responsive no matter how long the
network takes to answer or fail.  Windows has shipped curl since
Windows 10 1803, and it is standard on macOS and Linux.

`auto' uses curl when it can be found and falls back to `url.el'."
  :type '(choice (const :tag "curl if available, else url.el" auto)
                 (const :tag "curl subprocess" curl)
                 (const :tag "Emacs url.el" url))
  :group 'ham-spacewx)

(defcustom ham-spacewx-wake-delay 5
  "Seconds to wait after a suspended machine resumes before refreshing.
Every request issued before the network is back blocks until it times
out, which is what makes Emacs appear to freeze on wake."
  :type 'integer
  :group 'ham-spacewx)

(defcustom ham-spacewx-retry-delay 8
  "Seconds to wait before retrying a feed that failed.
One retry only, so a genuinely unreachable endpoint is reported rather
than hammered."
  :type 'integer
  :group 'ham-spacewx)

(defcustom ham-spacewx-request-timeout 15
  "Seconds to wait for a feed before giving up on it."
  :type 'integer
  :group 'ham-spacewx)

(defcustom ham-spacewx-wind-url
  "https://services.swpc.noaa.gov/json/rtsw/rtsw_wind_1m.json"
  "Feed for solar wind density, speed and temperature.
This is the real time solar wind product that replaced
`products/solar-wind/plasma-1-day.json' when SWPC retired that tree
around 30 April 2026.  Values are numeric rather than quoted strings,
and every record names the spacecraft it came from.  Real time solar
wind has come from DSCOVR since 2016, with ACE held as a backup."
  :type 'string
  :group 'ham-spacewx)

(defcustom ham-spacewx-wind-spacecraft 'active
  "Which spacecraft the solar wind readings come from.

The real time solar wind files carry every reporting spacecraft in one
document, so a spacecraft has to be chosen before anything is read.
`active' follows SWPC's own flag, which is what their plots do.  Naming
one pins the panel to it even when SWPC switches, which is the way to
compare like with like against a particular plot.

DSCOVR and ACE sit at different points near L1 and their instruments
are calibrated separately, so their speeds routinely differ by tens of
km/s.  Reading a mixture of the two is meaningless."
  :type '(choice (const :tag "Whichever SWPC marks active" active)
                 (const :tag "DSCOVR" "DSCOVR")
                 (const :tag "ACE" "ACE")
                 (string :tag "Named spacecraft"))
  :group 'ham-spacewx)

(defcustom ham-spacewx-wind-speed-field 'proton
  "Which speed the solar wind row reports.

The feed carries both a proton bulk speed and an alpha particle speed.
Proton speed is what NOAA plots as `solar wind speed' and what the
term ordinarily means."
  :type '(choice (const :tag "Proton bulk speed" proton)
                 (const :tag "Alpha particle speed" alpha)
                 (string :tag "Named field"))
  :group 'ham-spacewx)

(defcustom ham-spacewx-max-quality 0
  "Highest `overall_quality' value to accept from a solar wind sample.

The feed grades every sample and flags instrument problems.  Accepting
everything means a flagged reading can become the current value, which
is one way the panel can disagree with NOAA's plots for the same
spacecraft.  Zero accepts only samples graded best.  Set to nil to
accept every sample, including flagged ones."
  :type '(choice (const :tag "Accept every sample" nil)
                 (integer :tag "Highest quality value accepted"))
  :group 'ham-spacewx)

(defcustom ham-spacewx-mag-url
  "https://services.swpc.noaa.gov/json/rtsw/rtsw_mag_1m.json"
  "Feed for the interplanetary magnetic field, including Bz.
The replacement for the retired `products/solar-wind/mag-1-day.json'."
  :type 'string
  :group 'ham-spacewx)

(defcustom ham-spacewx-kindex-url
  "https://services.swpc.noaa.gov/products/noaa-planetary-k-index.json"
  "Feed for the planetary K index."
  :type 'string
  :group 'ham-spacewx)

(defcustom ham-spacewx-xray-url
  "https://services.swpc.noaa.gov/json/goes/primary/xrays-6-hour.json"
  "Feed for GOES soft X-ray flux."
  :type 'string
  :group 'ham-spacewx)

(defcustom ham-spacewx-xray-long-url
  "https://services.swpc.noaa.gov/json/goes/primary/xrays-7-day.json"
  "Feed for the multi-day GOES X-ray record.
Separate from the six hour feed because the panel shows both: the
recent trace at full resolution, and the peak flux per bucket over
several days, which is what says whether the sun has been flaring."
  :type 'string
  :group 'ham-spacewx)

(defcustom ham-spacewx-protons-url
  "https://services.swpc.noaa.gov/json/goes/primary/integral-protons-7-day.json"
  "Feed for GOES integral proton flux.
Carries several energy thresholds; the panel reads the 10 MeV channel,
the one the NOAA S scale and the 10 pfu event threshold are defined on.
Elevated protons cause polar cap absorption, which closes high latitude
paths outright."
  :type 'string
  :group 'ham-spacewx)

(defcustom ham-spacewx-sunspots-url
  "https://services.swpc.noaa.gov/text/daily-solar-indices.txt"
  "Feed for the daily sunspot number.

The Daily Solar Data report, in SWPC's fixed column text format.  Its
sunspot column is the number quoted everywhere else.

Not the JSON sunspot report, which lists active regions rather than a
daily total: deriving a Wolf number from it counts each region once per
observation and comes out several times too high."
  :type 'string
  :group 'ham-spacewx)

(defcustom ham-spacewx-flux-url
  "https://services.swpc.noaa.gov/products/10cm-flux-30-day.json"
  "Feed for the 10.7 cm solar radio flux.
The thirty day series, so the panel can draw a trend rather than a
single number."
  :type 'string
  :group 'ham-spacewx)


;;;; Faces

(defface ham-spacewx-heading
  '((t :inherit bold))
  "Face for section headings in the space weather panel."
  :group 'ham-spacewx)

(defface ham-spacewx-label
  '((t :inherit shadow))
  "Face for reading labels."
  :group 'ham-spacewx)

(defface ham-spacewx-value
  '((t :inherit default))
  "Face for reading values."
  :group 'ham-spacewx)

(defface ham-spacewx-stale
  '((t :inherit shadow :slant italic))
  "Face for readings old enough to be misleading."
  :group 'ham-spacewx)

(defface ham-spacewx-scale-0
  '((((background dark)) :foreground "#5FBF7F")
    (t :foreground "#1F7A3D"))
  "Face for a NOAA scale reading below the storm threshold."
  :group 'ham-spacewx)

(defface ham-spacewx-scale-1
  '((((background dark)) :foreground "#D8C24A")
    (t :foreground "#8A7400"))
  "Face for a NOAA scale level 1, minor."
  :group 'ham-spacewx)

(defface ham-spacewx-scale-2
  '((((background dark)) :foreground "#E39A3C")
    (t :foreground "#A85E00"))
  "Face for a NOAA scale level 2, moderate."
  :group 'ham-spacewx)

(defface ham-spacewx-scale-3
  '((((background dark)) :foreground "#E8603C")
    (t :foreground "#B33A10"))
  "Face for a NOAA scale level 3, strong."
  :group 'ham-spacewx)

(defface ham-spacewx-scale-4
  '((((background dark)) :foreground "#E24141" :weight bold)
    (t :foreground "#A81616" :weight bold))
  "Face for a NOAA scale level 4, severe."
  :group 'ham-spacewx)

(defface ham-spacewx-scale-5
  '((((background dark)) :foreground "#E36FD0" :weight bold)
    (t :foreground "#8E1478" :weight bold))
  "Face for a NOAA scale level 5, extreme."
  :group 'ham-spacewx)

(defface ham-spacewx-sparkline
  '((t :inherit shadow))
  "Face for sparklines."
  :group 'ham-spacewx)


;;;; Sources

(cl-defstruct (ham-spacewx-source (:constructor ham-spacewx-source-create)
                                (:copier nil))
  "A remote feed the panel reads.

KEY is the symbol the rest of the package refers to it by.  LABEL names
it for the user.  URL-VARIABLE is the symbol of the `defcustom' holding
its address, held indirectly so that customising the address takes
effect without re-registering the source.  SHAPE is how the payload is
laid out, one of `table', `records' or `summary'.  INTERVAL is the
smallest sensible gap between reads, in seconds.  TIMEOUT overrides
`ham-spacewx-request-timeout' for feeds large enough to need longer.
COLUMNS names the fields of a fixed column text report, in order."
  key label url-variable shape interval timeout columns)

(defvar ham-spacewx--sources
  (list
   (ham-spacewx-source-create
    :key 'wind :label "Solar wind plasma"
    :url-variable 'ham-spacewx-wind-url :shape 'records :interval 60)
   (ham-spacewx-source-create
    :key 'mag :label "Interplanetary magnetic field"
    :url-variable 'ham-spacewx-mag-url :shape 'records :interval 60)
   (ham-spacewx-source-create
    :key 'kindex :label "Planetary K index"
    :url-variable 'ham-spacewx-kindex-url :shape 'table :interval 900)
   (ham-spacewx-source-create
    :key 'xray :label "GOES X-ray flux"
    :url-variable 'ham-spacewx-xray-url :shape 'records :interval 300)
   (ham-spacewx-source-create
    :key 'xray-long :label "GOES X-ray, multi-day"
    :url-variable 'ham-spacewx-xray-long-url :shape 'records :interval 900
    :timeout 60)
   (ham-spacewx-source-create
    :key 'protons :label "GOES proton flux"
    :url-variable 'ham-spacewx-protons-url :shape 'records :interval 900
    :timeout 60)
   (ham-spacewx-source-create
    :key 'sunspots :label "Sunspot number"
    :url-variable 'ham-spacewx-sunspots-url :shape 'columns :interval 3600
    :columns '("year" "month" "day" "radio_flux" "ssn" "sunspot_area"
               "new_regions" "background_flux"))
   (ham-spacewx-source-create
    :key 'flux :label "10.7 cm flux"
    :url-variable 'ham-spacewx-flux-url :shape 'table :interval 3600))
  "The feeds the panel reads, in the order they are fetched.")

(defun ham-spacewx-source (key)
  "Return the source registered under KEY, or nil."
  (seq-find (lambda (source) (eq (ham-spacewx-source-key source) key))
            ham-spacewx--sources))

(defun ham-spacewx-source-seconds (source)
  "Return how long SOURCE may take before it is given up on.
A week of one minute samples is megabytes, and the default allowance
for a small feed is not enough to pull it over a slow link."
  (or (ham-spacewx-source-timeout source) ham-spacewx-request-timeout))

(defun ham-spacewx-source-url (source)
  "Return the current address of SOURCE."
  (symbol-value (ham-spacewx-source-url-variable source)))


;;;; Stored readings

(defvar ham-spacewx--data (make-hash-table :test #'eq)
  "Fetched payloads, keyed by source key.
Each value is a plist with `:payload', `:fetched' and `:error'.")

(defvar ham-spacewx--in-flight nil
  "Keys of sources with a request outstanding.")

(defvar ham-spacewx--generation 0
  "Bumped whenever stored data changes, to expire derived values.")

(defvar ham-spacewx--derived (make-hash-table :test #'equal)
  "Cache of values derived from payloads, keyed by request and generation.")

(defun ham-spacewx--generation-key ()
  "Return a token identifying the current state of stored data."
  ham-spacewx--generation)

(defun ham-spacewx--settings-fingerprint ()
  "Return the settings that change how a payload is interpreted.
Part of every cache key, so adjusting one of these takes effect at
once rather than at the next fetch."
  (list ham-spacewx-wind-spacecraft
        ham-spacewx-wind-speed-field
        ham-spacewx-max-quality))

(defun ham-spacewx--cached (key thunk)
  "Return the cached value for KEY, calling THUNK to compute it once.

Sorting and narrowing a feed of twenty thousand records is expensive,
and a single row asks for it four times over: for the value, the
series, the span and the scale.  Without this the panel spends seconds
of processor time on every redraw, which is indistinguishable from a
network stall to anyone watching."
  (let ((entry (gethash key ham-spacewx--derived)))
    (if (and entry (= (car entry) ham-spacewx--generation))
        (cdr entry)
      (let ((value (funcall thunk)))
        (puthash key (cons ham-spacewx--generation value)
                 ham-spacewx--derived)
        value))))

(defun ham-spacewx--entry (key)
  "Return the stored entry for KEY, or nil."
  (gethash key ham-spacewx--data))

(defun ham-spacewx--payload (key)
  "Return the parsed payload stored for KEY, or nil."
  (plist-get (ham-spacewx--entry key) :payload))

(defun ham-spacewx--fetched-at (key)
  "Return the time KEY was last fetched, or nil."
  (plist-get (ham-spacewx--entry key) :fetched))

(defun ham-spacewx--error (key)
  "Return the error string recorded for KEY, or nil."
  (plist-get (ham-spacewx--entry key) :error))

(defun ham-spacewx--age (key)
  "Return the age of KEY's data in seconds, or nil if never fetched."
  (let ((fetched (ham-spacewx--fetched-at key)))
    (and fetched (float-time (time-subtract (current-time) fetched)))))

(defun ham-spacewx--stale-p (key)
  "Return non-nil if KEY's data is older than `ham-spacewx-stale-after'."
  (let ((age (ham-spacewx--age key)))
    (and age (> age ham-spacewx-stale-after))))

(defun ham-spacewx-clear ()
  "Discard every stored reading.
Mainly useful when an endpoint has been corrected and the old failure
should not linger in the panel."
  (interactive)
  (clrhash ham-spacewx--data)
  (clrhash ham-spacewx--derived)
  (setq ham-spacewx--generation (1+ ham-spacewx--generation))
  (ham-spacewx--redisplay))


;;;; Parsing

;; NOAA publishes two layouts.  The "products" tree returns a table: a
;; header row of column names followed by rows of strings.  The "json"
;; tree returns records: a list of objects keyed by field name.  A few
;; summary endpoints return a single object.  All three arrive here as
;; Lisp and leave as something the accessors below can read by name.

(defun ham-spacewx--parse-columns (string columns)
  "Parse STRING, a fixed column text report, into records named by COLUMNS.

SWPC still publishes several products only as text.  Comment lines
begin with a hash or a colon; every other line is whitespace separated
values in a fixed order.  A `time_tag' is synthesised from the leading
year, month and day so the rest of the package can treat these records
like any other."
  (let (records)
    (dolist (line (split-string string "\n" t))
      (let ((trimmed (string-trim line)))
        (unless (or (string-empty-p trimmed)
                    (string-prefix-p "#" trimmed)
                    (string-prefix-p ":" trimmed))
          (let ((values (split-string trimmed nil t))
                (record nil))
            (when (>= (length values) 3)
              (let ((index 0))
                (dolist (name columns)
                  (when (< index (length values))
                    (push (cons (intern name) (nth index values)) record))
                  (setq index (1+ index))))
              (push (cons 'time_tag
                          (format "%s-%s-%s"
                                  (nth 0 values) (nth 1 values) (nth 2 values)))
                    record)
              (push (nreverse record) records))))))
    (nreverse records)))

(defun ham-spacewx--parse-json (string)
  "Parse STRING as JSON into alists and lists.
Signals an error if STRING is not valid JSON."
  (json-parse-string string
                     :object-type 'alist
                     :array-type 'list
                     :null-object nil
                     :false-object nil))

(defun ham-spacewx--table-rows (payload)
  "Return the data rows of a table PAYLOAD, excluding the header."
  (cdr payload))

(defun ham-spacewx--table-index (payload column)
  "Return the position of COLUMN in the header of table PAYLOAD.
COLUMN is matched case insensitively.  Returns nil if absent."
  (let ((header (car payload))
        (wanted (downcase column)))
    (seq-position header wanted
                  (lambda (a b) (and (stringp a) (string= (downcase a) b))))))

(defun ham-spacewx--table-column (payload column)
  "Return every value of COLUMN in table PAYLOAD, oldest first.
Returns nil if the column is absent."
  (let ((index (ham-spacewx--table-index payload column)))
    (when index
      (mapcar (lambda (row) (nth index row))
              (ham-spacewx--table-rows payload)))))

(defun ham-spacewx--key-name (key)
  "Return KEY as a string, whether it is a symbol or already a string."
  (if (symbolp key) (symbol-name key) (format "%s" key)))

(defun ham-spacewx--field (record field)
  "Return FIELD from RECORD, an alist parsed from a JSON object.
FIELD is matched case insensitively, because SWPC is not consistent
about it: the planetary K feed spells its field `Kp' while everything
else is lower case, and a case sensitive lookup silently returns nil
rather than failing loudly.

`json-parse-string' interns object keys as symbols when asked for
alists, so both key forms are accepted here: one is what the parser
produces, the other is what a hand-written fixture tends to contain."
  (let ((wanted (downcase field)))
    (cdr (seq-find (lambda (pair)
                     (and (consp pair)
                          (string= (downcase (ham-spacewx--key-name (car pair)))
                                   wanted)))
                   record))))

(defun ham-spacewx--record-field (records field)
  "Return every value of FIELD across RECORDS, oldest first."
  (mapcar (lambda (record) (ham-spacewx--field record field)) records))

(defun ham-spacewx--table-p (payload)
  "Return non-nil if PAYLOAD is a header row followed by data rows.
Declaring the layout per source turned out to be a liability: SWPC
publishes the same reading as a table in one tree and as records in
another, and moves feeds between them.  Detecting it costs one check
and cannot go stale."
  (and (consp payload)
       (proper-list-p (car payload))
       (seq-every-p #'stringp (car payload))))

(defun ham-spacewx--field-names (payload)
  "Return the column or field names present in PAYLOAD, as strings.
Used by `ham-spacewx-diagnose' so that a reading which comes back empty
can be traced to the name the feed actually uses."
  (cond
   ((null payload) nil)
   ((ham-spacewx--table-p payload) (car payload))
   ((consp (car payload))
    (mapcar (lambda (pair) (ham-spacewx--key-name (car pair))) (car payload)))))

(defun ham-spacewx--time-column (payload)
  "Return the time tag of every row or record in PAYLOAD, oldest first."
  (if (ham-spacewx--table-p payload)
      (ham-spacewx--table-column payload "time_tag")
    (ham-spacewx--record-field payload "time_tag")))

(defun ham-spacewx--samples (payload fields)
  "Return (VALUE . TIME) for the first of FIELDS that PAYLOAD carries.

Values and times are filtered together, so dropping a gap cannot slide
the two out of step.  Keeping them paired is what lets the panel say
how long a sparkline actually covers: the drawn window is the tail of
this list, and its span is the difference between the first and last
time in that tail, not in the whole feed."
  (let ((times (ham-spacewx--time-column payload))
        (table (ham-spacewx--table-p payload)))
    (seq-some
     (lambda (field)
       (let ((raw (if table
                      (ham-spacewx--table-column payload field)
                    (ham-spacewx--record-field payload field)))
             (clock times)
             (pairs nil))
         ;; Both lists are walked together.  Indexing into the times by
         ;; position would restart from the head for every sample, which
         ;; is quadratic and costs seconds on a week of one minute data.
         (while raw
           (let ((number (ham-spacewx--number (car raw))))
             (when number (push (cons number (car clock)) pairs)))
           (setq raw (cdr raw) clock (cdr clock)))
         (and pairs (nreverse pairs))))
     fields)))

(defun ham-spacewx--series (payload fields)
  "Return the first non-empty numeric series among FIELDS from PAYLOAD.
FIELDS is a list of candidate names, tried in order.  Works on either
layout, so a feed that moves between trees keeps reading."
  (let ((table (ham-spacewx--table-p payload)))
    (seq-some
     (lambda (field)
       (let ((values (ham-spacewx--numbers
                      (if table
                          (ham-spacewx--table-column payload field)
                        (ham-spacewx--record-field payload field)))))
         (and values values)))
     fields)))

(defun ham-spacewx--number (value)
  "Return VALUE as a number, or nil if it is not numeric.
Accepts a number, or a string holding one.  NOAA writes absent samples
as an empty string or as the JSON null, and both become nil here."
  (cond
   ((numberp value) value)
   ((and (stringp value) (string-match-p "\\`[ \t]*\\'" value)) nil)
   ((stringp value) (let ((n (string-to-number value)))
                      ;; `string-to-number' returns 0 for junk, so reject
                      ;; anything that does not look numeric first.
                      (and (string-match-p
                            "\\`[ \t]*[-+]?[0-9.]+\\([eE][-+]?[0-9]+\\)?[ \t]*\\'"
                            value)
                           n)))
   (t nil)))

(defun ham-spacewx--numbers (values)
  "Return the numeric members of VALUES, in order, dropping the rest."
  (delq nil (mapcar #'ham-spacewx--number values)))

(defun ham-spacewx--latest (values)
  "Return the last numeric member of VALUES, or nil."
  (car (last (ham-spacewx--numbers values))))

(defun ham-spacewx--tail (values n)
  "Return the last N members of VALUES."
  (let ((length (length values)))
    (if (<= length n) values (nthcdr (- length n) values))))


;;;; Reading accessors

(defun ham-spacewx--sorted-records (records)
  "Return RECORDS oldest first by time tag.

File order is not a promise.  These feeds carry several spacecraft in
one document, so the last record in the file is whichever spacecraft
was written last, not the newest sample.

Sorting compares the timestamps as text rather than parsing them.  Both
forms SWPC publishes are fixed width and most significant first, so
they order correctly as strings, and a feed mixes only one of them.
Parsing twenty thousand timestamps to sort them costs over a second of
processor time; comparing them as text costs nothing."
  (let ((keyed (mapcar (lambda (record)
                         (cons (or (ham-spacewx--field record "time_tag") "")
                               record))
                       records)))
    (mapcar #'cdr
            (sort keyed (lambda (a b) (string< (car a) (car b)))))))

(defun ham-spacewx--quality-ok-p (record)
  "Return non-nil if RECORD passes `ham-spacewx-max-quality'."
  (or (null ham-spacewx-max-quality)
      (let ((quality (ham-spacewx--field record "overall_quality")))
        (or (null quality)
            (<= (or (ham-spacewx--number quality) 0)
                ham-spacewx-max-quality)))))

(defun ham-spacewx-wind-spacecraft-in (records)
  "Return the spacecraft to read from RECORDS.
A configured name wins.  Otherwise the source of the newest record
SWPC has marked active."
  (if (stringp ham-spacewx-wind-spacecraft)
      ham-spacewx-wind-spacecraft
    (let ((active (seq-filter (lambda (record)
                                (ham-spacewx--field record "active"))
                              (ham-spacewx--sorted-records records))))
      (and active (ham-spacewx--field (car (last active)) "source")))))

(defun ham-spacewx--active-records (key)
  "Return the records stored under KEY for one spacecraft, oldest first.

Three things happen here, and leaving out any of them produces a series
that disagrees with NOAA: the records are sorted by time rather than
trusted in file order, narrowed to a single spacecraft rather than
mixed, and filtered on the feed's own quality grading."
  (ham-spacewx--cached
   (cons 'active (cons key (ham-spacewx--settings-fingerprint)))
   (lambda () (ham-spacewx--active-records-1 key))))

(defun ham-spacewx--active-records-1 (key)
  "Compute the narrowed records for KEY.  See `ham-spacewx--active-records'."
  (let ((payload (ham-spacewx--payload key)))
    (if (ham-spacewx--table-p payload)
        payload
      (let* ((sorted (ham-spacewx--sorted-records payload))
             (graded (seq-filter #'ham-spacewx--quality-ok-p sorted))
             (spacecraft (ham-spacewx-wind-spacecraft-in payload))
             (chosen (if spacecraft
                         (seq-filter
                          (lambda (record)
                            (equal (ham-spacewx--field record "source")
                                   spacecraft))
                          graded)
                       graded)))
        (or chosen graded sorted)))))

(defconst ham-spacewx--speed-fields
  '("proton_speed" "speed" "bulk_speed" "flow_speed")
  "Names the solar wind speed has been published under.")

(defconst ham-spacewx--density-fields
  '("proton_density" "density")
  "Names the solar wind proton density has been published under.")

(defconst ham-spacewx--bz-fields '("bz_gsm" "bz")
  "Names the north-south field component has been published under.")

(defconst ham-spacewx--bt-fields '("bt" "b_total" "bt_gsm")
  "Names the total field strength has been published under.")

(defconst ham-spacewx--kp-fields
  '("kp_index" "estimated_kp" "kp" "k_index" "kp_est" "kp_value")
  "Names the planetary K index has been published under.")

(defconst ham-spacewx--a-index-fields '("a_running" "a_index" "ap")
  "Names the running A index has been published under.")

(defconst ham-spacewx--sunspot-fields
  '("ssn" "sunspot_number" "sunspot_num" "observed_ssn" "R")
  "Names the daily sunspot number has been published under.")

(defconst ham-spacewx--flux-fields
  '("flux" "f10.7" "f10_7" "observed_flux" "radio_flux" "value" "ssn")
  "Names the 10.7 cm radio flux has been published under.")

(defconst ham-spacewx--metric-fields-static
  `((speed   . ,ham-spacewx--speed-fields)
    (density . ,ham-spacewx--density-fields)
    (bz      . ,ham-spacewx--bz-fields)
    (bt      . ,ham-spacewx--bt-fields)
    (kp      . ,ham-spacewx--kp-fields)
    (a-index . ,ham-spacewx--a-index-fields)
    (xray     . ("flux"))
    (xray-max . ("flux"))
    (protons  . ("flux"))
    (flux     . ,ham-spacewx--flux-fields)
    (sunspots . ,ham-spacewx--sunspot-fields))
  "Field names to try for each metric the panel draws.")

(defun ham-spacewx--metric-payload (metric)
  "Return the records or rows METRIC should be read from.
Two feeds need narrowing before anything is read: the solar wind pair
carry several spacecraft, and the GOES feed interleaves two energy
bands."
  (pcase metric
    ((or 'speed 'density) (ham-spacewx--active-records 'wind))
    ((or 'bz 'bt) (ham-spacewx--active-records 'mag))
    ('xray (ham-spacewx--xray-long-band))
    ('xray-max (ham-spacewx--xray-long-band-of 'xray-long))
    ('protons (ham-spacewx--proton-channel))
    ((or 'kp 'a-index) (ham-spacewx--payload 'kindex))
    ('flux (ham-spacewx--payload 'flux))
    ('sunspots (ham-spacewx--payload 'sunspots))))

(defun ham-spacewx-metric-fields (metric)
  "Return the field names to try for METRIC, newest preference first."
  (if (eq metric 'speed)
      (pcase ham-spacewx-wind-speed-field
        ('alpha '("alpha_speed"))
        ((and (pred stringp) field) (list field))
        (_ ham-spacewx--speed-fields))
    (alist-get metric ham-spacewx--metric-fields-static)))

(defun ham-spacewx-metric-samples (metric)
  "Return (VALUE . TIME) for METRIC, oldest first."
  (ham-spacewx--cached
     (cons 'samples (cons metric (ham-spacewx--settings-fingerprint)))
     (lambda ()
       (ham-spacewx--samples (ham-spacewx--metric-payload metric)
                             (ham-spacewx-metric-fields metric)))))

(defun ham-spacewx-metric-series (metric)
  "Return the values of METRIC, oldest first."
  (mapcar #'car (ham-spacewx-metric-samples metric)))

(defun ham-spacewx-metric-value (metric)
  "Return the current value of METRIC, or nil."
  (car (last (ham-spacewx-metric-series metric))))

(defun ham-spacewx-solar-wind-speed-series ()
  "Return the solar wind speed series in km/s, oldest first."
  (ham-spacewx-metric-series 'speed))

(defun ham-spacewx-solar-wind-density-series ()
  "Return the proton density series per cubic cm, oldest first."
  (ham-spacewx-metric-series 'density))

(defun ham-spacewx-bz-series ()
  "Return the Bz series in nT, oldest first."
  (ham-spacewx-metric-series 'bz))

(defun ham-spacewx-bt-series ()
  "Return the total field strength series in nT, oldest first."
  (ham-spacewx-metric-series 'bt))

(defun ham-spacewx-solar-wind-speed ()
  "Return the current solar wind speed in km/s, or nil."
  (ham-spacewx--latest (ham-spacewx-solar-wind-speed-series)))

(defun ham-spacewx-solar-wind-density ()
  "Return the current solar wind proton density per cubic cm, or nil."
  (ham-spacewx--latest (ham-spacewx-solar-wind-density-series)))

(defun ham-spacewx-bz ()
  "Return the current north-south field component Bz in nT, or nil.
A sustained negative value couples the solar wind to the magnetosphere
and precedes geomagnetic disturbance."
  (ham-spacewx--latest (ham-spacewx-bz-series)))

(defun ham-spacewx-bt ()
  "Return the current total field strength Bt in nT, or nil."
  (ham-spacewx--latest (ham-spacewx-bt-series)))

(defun ham-spacewx--describe-record (record)
  "Return RECORD as a short readable line of field and value pairs."
  (mapconcat (lambda (pair)
               (format "%s=%s" (ham-spacewx--key-name (car pair)) (cdr pair)))
             record " "))

(defun ham-spacewx-show-wind-sample ()
  "Show the exact record the solar wind readings are taken from.

Print it beside NOAA's own plot when the two disagree: it names the
spacecraft, the timestamp and the quality grade of the sample the panel
is actually using, which is what settles whether a difference is a
different spacecraft, a stale record or a genuinely different number."
  (interactive)
  (let ((buffer (get-buffer-create "*ham-spacewx-sample*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (insert "Solar wind sample in use\n\n")
        (insert (format "Spacecraft setting : %S\n" ham-spacewx-wind-spacecraft))
        (insert (format "Speed field        : %S\n"
                        ham-spacewx-wind-speed-field))
        (insert (format "Quality accepted   : %s\n"
                        (or ham-spacewx-max-quality "any")))
        (dolist (entry '((wind . "Plasma") (mag . "Magnetic field")))
          (let* ((key (car entry))
                 (all (ham-spacewx--payload key))
                 (chosen (ham-spacewx--active-records key))
                 (newest (car (last chosen))))
            (insert (format "\n%s\n" (cdr entry)))
            (insert (format "  records in feed     : %d\n" (length all)))
            (insert (format "  after filtering     : %d\n" (length chosen)))
            (insert (format "  spacecraft chosen   : %s\n"
                            (or (ham-spacewx-wind-spacecraft-in all) "none")))
            (insert (format "  spacecraft in feed  : %s\n"
                            (mapconcat #'identity
                                       (delete-dups
                                        (delq nil
                                              (mapcar
                                               (lambda (r)
                                                 (ham-spacewx--field r "source"))
                                               all)))
                                       ", ")))
            (if newest
                (insert (format "  newest sample       : %s\n"
                                (ham-spacewx--describe-record newest)))
              (insert "  newest sample       : none\n"))))))
    (pop-to-buffer buffer)))

(defun ham-spacewx-spacecraft ()
  "Return the name of the spacecraft the solar wind readings came from."
  (let ((records (ham-spacewx--active-records 'wind)))
    (and records (not (ham-spacewx--table-p records))
         (ham-spacewx--field (car (last records)) "source"))))

(defun ham-spacewx-kp-series ()
  "Return the planetary K index series, oldest first."
  (ham-spacewx-metric-series 'kp))

(defun ham-spacewx-kp ()
  "Return the current planetary K index, or nil."
  (ham-spacewx--latest (ham-spacewx-kp-series)))

(defun ham-spacewx-a-index-series ()
  "Return the running A index series, oldest first."
  (ham-spacewx-metric-series 'a-index))

(defun ham-spacewx-a-index ()
  "Return the A index for the last 24 hours, or nil.

A is a daily figure by definition, where Kp reports three hours, so the
number shown is the mean across the day rather than the most recent
three hourly sample.  A single sample carries the label `running' in
the feed but still describes one interval; averaging the day's samples
is what makes the reading mean what its name says."
  (let ((values (mapcar #'car
                        (ham-spacewx--within-days
                         (ham-spacewx-metric-samples 'a-index) 1))))
    (when values
      (/ (apply #'+ values) (float (length values))))))

(defun ham-spacewx--xray-long-band ()
  "Return the 0.1 to 0.8 nm band records only, dropping the short band.
The GOES feed interleaves two energy bands.  Drawing both produces a
sawtooth that looks like violent variability and is really just the two
bands alternating, so the band has to be selected before anything is
plotted, not only before the value is read."
  (seq-filter
   (lambda (record)
     (let ((energy (ham-spacewx--field record "energy")))
       (or (null energy) (string-match-p "0\\.1-0\\.8" energy))))
   (ham-spacewx--payload 'xray)))

(defun ham-spacewx--xray-long-band-of (key)
  "Return the 0.1 to 0.8 nm records of the feed stored under KEY."
  (seq-filter
   (lambda (record)
     (let ((energy (ham-spacewx--field record "energy")))
       (or (null energy) (string-match-p "0\\.1-0\\.8" energy))))
   (ham-spacewx--payload key)))

(defun ham-spacewx--proton-channel ()
  "Return the 10 MeV integral proton records only.

The feed interleaves thresholds from 1 to 500 MeV.  The match is
anchored so that `>=100 MeV' cannot satisfy a request for `>=10 MeV',
which a loose substring test would let through and quietly plot the
wrong channel."
  (seq-filter
   (lambda (record)
     (let ((energy (ham-spacewx--field record "energy")))
       (and energy (string-match-p "\\`>=? *10 *MeV\\'"
                                   (string-trim energy)))))
   (ham-spacewx--payload 'protons)))

(defun ham-spacewx-xray-series ()
  "Return the long-band X-ray flux series in W/m^2, oldest first."
  (ham-spacewx-metric-series 'xray))

(defun ham-spacewx-xray-flux ()
  "Return the current long-band solar X-ray flux in W/m^2, or nil.
Read from the GOES 0.1 to 0.8 nm band, which is the band the flare
classes are defined on."
  (ham-spacewx--latest (ham-spacewx-xray-series)))

(defun ham-spacewx-xray-max-series ()
  "Return the multi-day long-band X-ray series, oldest first."
  (ham-spacewx-metric-series 'xray-max))

(defun ham-spacewx-xray-max ()
  "Return the highest recent long-band X-ray flux in W/m^2, or nil."
  (let ((series (car (ham-spacewx-metric-drawn 'xray-max))))
    (and series (apply #'max series))))

(defun ham-spacewx-proton-series ()
  "Return the 10 MeV integral proton flux series in pfu, oldest first."
  (ham-spacewx-metric-series 'protons))

(defun ham-spacewx-proton-flux ()
  "Return the current 10 MeV integral proton flux in pfu, or nil.
Above 10 pfu is a NOAA S1 radiation storm, and polar paths close."
  (ham-spacewx--latest (ham-spacewx-proton-series)))

(defun ham-spacewx-sunspot-series ()
  "Return the daily sunspot number series, oldest first."
  (ham-spacewx-metric-series 'sunspots))

(defun ham-spacewx-sunspot-number ()
  "Return the latest daily sunspot number, or nil."
  (ham-spacewx--latest (ham-spacewx-sunspot-series)))

(defun ham-spacewx-flux-series ()
  "Return the 10.7 cm flux series, oldest first, or nil."
  (ham-spacewx-metric-series 'flux))

(defun ham-spacewx-solar-flux ()
  "Return the 10.7 cm solar radio flux in solar flux units, or nil."
  (ham-spacewx--latest (ham-spacewx-flux-series)))


;;;; Interpretation

(defun ham-spacewx-kp-description (kp)
  "Return a plain description of planetary K index KP.
The bands follow the NOAA G scale: below 4 is quiet to unsettled, 5 and
above is a geomagnetic storm."
  (cond
   ((null kp) "unknown")
   ((< kp 2) "quiet")
   ((< kp 4) "unsettled")
   ((< kp 5) "active")
   ((< kp 6) "minor storm G1")
   ((< kp 7) "moderate storm G2")
   ((< kp 8) "strong storm G3")
   ((< kp 9) "severe storm G4")
   (t "extreme storm G5")))

(defun ham-spacewx-xray-class (flux)
  "Return FLUX in W/m^2 as a flare class string such as \"B4.2\".
Returns nil if FLUX is nil."
  (when (and flux (> flux 0))
    (let* ((bands '((1.0e-4 . "X") (1.0e-5 . "M") (1.0e-6 . "C")
                    (1.0e-7 . "B") (1.0e-8 . "A")))
           (band (seq-find (lambda (b) (>= flux (car b))) bands)))
      (if band
          (format "%s%.1f" (cdr band) (/ flux (car band)))
        (format "A%.1f" (/ flux 1.0e-8))))))

(defun ham-spacewx-bz-description (bz)
  "Return a plain description of field component BZ.
Southward field is the condition that matters, so it is what gets
called out."
  (cond
   ((null bz) "")
   ((> bz 1.0) "northward")
   ((> bz -2.0) "neutral")
   ((> bz -8.0) "southward")
   (t "strongly southward")))


;;;; Severity

(defcustom ham-spacewx-noaa-scales
  '((R xray-max "Radio blackout"
       (1.0e-5 5.0e-5 1.0e-4 1.0e-3 2.0e-3))
    (S protons  "Radiation storm"
       (10 100 1000 10000 100000))
    (G kp       "Geomagnetic storm"
       (5 6 7 8 9)))
  "The NOAA space weather scales, and what each is measured on.

Each entry is (LETTER METRIC DESCRIPTION THRESHOLDS), where THRESHOLDS
are the values at which levels 1 to 5 begin.

The thresholds are NOAA's published ones.  R runs off GOES peak X-ray
flux, so R1 is an M1 flare and R3 an X1.  S runs off the 10 MeV
integral proton flux in pfu, S1 being the 10 pfu event threshold.  G
runs off Kp, G1 being Kp 5.

The colours are in `ham-spacewx-scale-0' through `ham-spacewx-scale-5'.
They follow the green, yellow, orange, red, dark red progression NOAA
displays, but the exact values are chosen here rather than taken from
a published palette: NOAA documents the scales and their thresholds,
not hex codes."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'ham-spacewx)

(defcustom ham-spacewx-severity-thresholds
  '((kp      above  4.0     5.0)
    (xray     above  1.0e-6  1.0e-5)
    (xray-max above  1.0e-6  1.0e-5)
    (protons  above  10      100)
    (speed   above  500     650)
    (density above  10      20)
    (bt      above  10      20)
    (a-index above  16      30)
    (bz      below -2.0    -8.0)
    (flux    below  90      70))
  "When a reading counts as degraded or as severe.

Each entry is (METRIC DIRECTION WARN SEVERE).  DIRECTION is `above'
when a larger value is worse, and `below' when a smaller one is: Bz
matters as it goes negative, and 10.7 cm flux matters as it falls,
since low flux is what closes the high bands.

The defaults follow published scales where one exists.  Kp 5 is the
NOAA G1 storm threshold.  X-ray 1e-5 is the M class boundary, where
shortwave fadeout starts on the sunlit side.  The solar wind and field
figures are working thresholds rather than standards, and are meant to
be adjusted."
  :type '(alist :key-type symbol
                :value-type (list (choice (const above) (const below))
                                  number number))
  :group 'ham-spacewx)

(defun ham-spacewx-severity (metric value)
  "Return how bad VALUE is for METRIC: `good', `warn', `severe' or nil.
Returns nil when VALUE is missing or METRIC has no configured scale, so
that an unscaled reading simply renders without colour."
  (let ((spec (alist-get metric ham-spacewx-severity-thresholds)))
    (when (and value spec)
      (pcase-let ((`(,direction ,warn ,severe) spec))
        (if (eq direction 'below)
            (cond ((<= value severe) 'severe)
                  ((<= value warn) 'warn)
                  (t 'good))
          (cond ((>= value severe) 'severe)
                ((>= value warn) 'warn)
                (t 'good)))))))

(defcustom ham-spacewx-signed-metrics '(bz)
  "Metrics whose sign carries the meaning, not just their magnitude.

A plain sparkline stretches the smallest sample to the bottom of the
ramp and the largest to the top, which hides where zero fell.  For Bz
that is the one thing worth seeing: a trace sitting entirely below the
midpoint spent the whole window southward.  Metrics listed here are
scaled symmetrically about zero instead, so the middle of the ramp is
always zero and a crossing is visible as a crossing."
  :type '(repeat symbol)
  :group 'ham-spacewx)

(defun ham-spacewx-metric-source (metric)
  "Return the source key METRIC is read from."
  (pcase metric
    ((or 'speed 'density) 'wind)
    ((or 'bz 'bt) 'mag)
    ((or 'kp 'a-index) 'kindex)
    ('xray 'xray)
    ('xray-max 'xray-long)
    ('protons 'protons)
    ('flux 'flux)
    ('sunspots 'sunspots)))

(defun ham-spacewx-metric-view (metric)
  "Return the drawing plan for METRIC as a plist."
  (or (alist-get metric ham-spacewx-metric-views)
      (list :samples ham-spacewx-series-length)))

(defun ham-spacewx--within-days (samples days)
  "Return the members of SAMPLES falling in the last DAYS.
Measured back from the newest readable timestamp rather than from now,
so a feed that has stopped updating still shows its final window
instead of emptying out."
  (let ((newest (seq-some (lambda (sample) (ham-spacewx--parse-time (cdr sample)))
                          (reverse samples))))
    (if (null newest)
        samples
      ;; Samples are already oldest first, so walking back from the end
      ;; parses only the window plus one rather than the whole feed.
      (let ((cutoff (time-subtract newest (days-to-time days)))
            (kept nil))
        (catch 'done
          (dolist (sample (reverse samples))
            (let ((moment (ham-spacewx--parse-time (cdr sample))))
              (when (and moment (time-less-p moment cutoff))
                (throw 'done nil))
              (push sample kept))))
        kept))))

(defun ham-spacewx--resample (values units aggregate)
  "Redistribute VALUES into UNITS buckets, combining with AGGREGATE.

Handles both directions.  Thousands of one minute samples collapse into
UNITS buckets; five daily samples spread across UNITS as a stair, each
empty bucket holding the last value seen rather than a gap.  AGGREGATE
is `max' to keep peaks, anything else averages."
  (if (or (null values) (null units) (< units 1) (= (length values) units))
      values
    (let ((buckets (make-vector units nil))
          (count (length values))
          (index 0)
          (carried nil)
          (out nil))
      (dolist (value values)
        (let ((bucket (min (1- units)
                           (floor (* units (/ (float index) count))))))
          (push value (aref buckets bucket)))
        (setq index (1+ index)))
      (dotimes (bucket units)
        (let ((members (aref buckets bucket)))
          (when members
            (setq carried
                  (cond
                   ((null (cdr members)) (car members))
                   ((eq aggregate 'max) (apply #'max members))
                   (t (/ (apply #'+ members) (float (length members)))))))
          (push carried out)))
      (delq nil (nreverse out)))))

(defun ham-spacewx-metric-window (metric)
  "Return how many characters wide METRIC is drawn."
  (let ((view (ham-spacewx-metric-view metric)))
    (or (plist-get view :units)
        (plist-get view :samples)
        ham-spacewx-series-length)))

(defun ham-spacewx-metric-drawn (metric)
  "Return (VALUES . TIMES) for METRIC, windowed and resampled for drawing."
  (ham-spacewx--cached
   (list 'drawn metric ham-spacewx-metric-views ham-spacewx-series-length
         (ham-spacewx--settings-fingerprint))
   (lambda () (ham-spacewx-metric-drawn-1 metric))))

(defun ham-spacewx-metric-drawn-1 (metric)
  "Compute the drawable series for METRIC."
  (let* ((view (ham-spacewx-metric-view metric))
         (samples (ham-spacewx-metric-samples metric))
         (days (plist-get view :days))
         (windowed (cond
                    (days (ham-spacewx--within-days samples days))
                    (t (ham-spacewx--tail
                        samples (or (plist-get view :samples)
                                    ham-spacewx-series-length)))))
         (units (plist-get view :units))
         (values (mapcar #'car windowed)))
    (cons (if units
              (ham-spacewx--resample values units
                                     (plist-get view :aggregate))
            values)
          (mapcar #'cdr windowed))))

(defun ham-spacewx-scale-thresholds (scale)
  "Return the level 1 to 5 thresholds for SCALE, or nil."
  (nth 2 (alist-get scale ham-spacewx-noaa-scales)))

(defun ham-spacewx-scale-metric (scale)
  "Return the metric SCALE is measured on."
  (car (alist-get scale ham-spacewx-noaa-scales)))

(defun ham-spacewx-scale-description (scale)
  "Return the plain name of SCALE."
  (nth 1 (alist-get scale ham-spacewx-noaa-scales)))

(defun ham-spacewx-metric-scale (metric)
  "Return the NOAA scale letter METRIC feeds, or nil.
The six hour X-ray reading shares the R scale with the multi-day peak:
both are the same measurement over a different window."
  (cond
   ((memq metric '(xray xray-max)) 'R)
   ((eq metric 'protons) 'S)
   ((eq metric 'kp) 'G)))

(defun ham-spacewx-scale-level (scale value)
  "Return the NOAA level 0 to 5 of VALUE on SCALE, or nil.
Level 0 means below the level 1 threshold, which is the ordinary
condition rather than a storm."
  (let ((thresholds (ham-spacewx-scale-thresholds scale)))
    (when (and value thresholds)
      (let ((level 0))
        (dolist (threshold thresholds)
          (when (>= value threshold) (setq level (1+ level))))
        level))))

(defun ham-spacewx-scale-face (level)
  "Return the face for NOAA scale LEVEL."
  (and level (intern (format "ham-spacewx-scale-%d" (min 5 (max 0 level))))))

(defun ham-spacewx--face-for (metric value)
  "Return the face VALUE should wear under METRIC.

A metric that feeds one of the NOAA scales is coloured on that scale,
so the panel and the published alert level agree.  Everything else
falls back to the three level severity, which is a working judgement
rather than a standard."
  (let ((scale (ham-spacewx-metric-scale metric)))
    (if scale
        (ham-spacewx-scale-face (ham-spacewx-scale-level scale value))
      (ham-spacewx-severity-face (ham-spacewx-severity metric value)))))

(defun ham-spacewx-severity-face (severity)
  "Return the face for SEVERITY, or nil for an unscaled reading.
Severity shares the NOAA scale palette rather than having colours of
its own, so one set of colours means the same thing everywhere in the
panel: quiet, degraded, serious."
  (pcase severity
    ('good 'ham-spacewx-scale-0)
    ('warn 'ham-spacewx-scale-2)
    ('severe 'ham-spacewx-scale-4)
    (_ nil)))


;;;; Propagation estimate

;; What follows is a model, not a measurement.  It predicts the state of
;; the ionosphere from solar and geomagnetic indices; an ionosonde
;; network measures it directly.  Where the two disagree the ionosonde
;; is right.  Every coefficient is a `defcustom' so the model can be
;; corrected against real soundings rather than argued about.
;;
;; The chain is the standard one.  Solar ultraviolet ionises the F2
;; layer, so the critical frequency foF2 follows the solar zenith angle
;; and the level of solar activity.  Multiplying foF2 by an obliquity
;; factor gives the maximum usable frequency over a 3000 km hop.  The D
;; layer, ionised by the same sunlight and by flare X-rays, absorbs
;; rather than refracts, and sets a lowest usable frequency.  A band is
;; open when it falls between the two.

(defcustom ham-spacewx-fof2-night 2.0
  "Night time F2 critical frequency at a 10.7 cm flux of zero, in MHz."
  :type 'number
  :group 'ham-spacewx)

(defcustom ham-spacewx-fof2-night-per-sfi 0.010
  "How much the night time critical frequency rises per solar flux unit."
  :type 'number
  :group 'ham-spacewx)

(defcustom ham-spacewx-fof2-noon 4.0
  "Daytime F2 critical frequency at a 10.7 cm flux of zero, in MHz."
  :type 'number
  :group 'ham-spacewx)

(defcustom ham-spacewx-fof2-noon-per-sfi 0.040
  "How much the daytime critical frequency rises per solar flux unit."
  :type 'number
  :group 'ham-spacewx)

(defcustom ham-spacewx-f2-peak-hour 14.0
  "Local hour at which the F2 layer is most ionised.

Not local noon.  The layer keeps building for a couple of hours after
the sun is highest, because recombination at F2 heights is slow, so
the daily maximum lags."
  :type 'number
  :group 'ham-spacewx)

(defcustom ham-spacewx-obliquity-factor 3.2
  "The M(3000)F2 factor turning a critical frequency into a MUF.
A signal striking the layer at a slant is returned at a higher
frequency than one sent straight up.  Around 3.2 for a 3000 km hop."
  :type 'number
  :group 'ham-spacewx)

(defcustom ham-spacewx-storm-depression 0.04
  "How much each Kp step above 4 depresses the critical frequency.
Scaled by geomagnetic latitude, since storms bite at high latitudes and
leave the equator largely alone."
  :type 'number
  :group 'ham-spacewx)

(defun ham-spacewx-latitude-factor (latitude)
  "Return the F2 ionisation factor at LATITUDE, in degrees.

Ionisation peaks either side of the magnetic equator and falls away
toward the poles.  The shape follows the estimate used by OpenHamClock
so that this panel and the figures published elsewhere agree; without
it, a mid latitude estimate runs several MHz high."
  (let ((deg (abs latitude)))
    (cond
     ((< deg 15) 1.15)
     ((< deg 45) (- 1.05 (/ (- deg 15) 120.0)))
     (t (max 0.45 (- 0.8 (/ (- deg 45) 250.0)))))))

(defcustom ham-spacewx-luf-night 2.0
  "Lowest usable frequency with the D layer unlit, in MHz."
  :type 'number
  :group 'ham-spacewx)

(defcustom ham-spacewx-luf-day 5.0
  "How much the sunlit D layer raises the lowest usable frequency, in MHz."
  :type 'number
  :group 'ham-spacewx)

(defcustom ham-spacewx-luf-per-r-level 3.0
  "How much each NOAA R level raises the lowest usable frequency, in MHz.
A flare floods the D layer and absorption climbs across the whole
shortwave range: this is the shortwave fadeout the R scale names."
  :type 'number
  :group 'ham-spacewx)

(defun ham-spacewx--solar-activity ()
  "Return the 10.7 cm solar flux to drive the model with, or nil.

Flux rather than sunspot count: it is measured daily by radio telescope
rather than counted by eye, and it is what propagation models are
conventionally parameterised on.  Falls back to converting a sunspot
number through the Covington relation when the flux is unavailable."
  (or (ham-spacewx-solar-flux)
      (let ((ssn (ham-spacewx-sunspot-number)))
        (and ssn (+ 63.7 (* 0.728 ssn))))))

(defun ham-spacewx--local-hour (lon &optional time)
  "Return the local solar hour at LON for TIME, 0 to 24."
  (let* ((utc (+ (string-to-number
                  (format-time-string "%H" (or time (current-time)) t))
                 (/ (string-to-number
                     (format-time-string "%M" (or time (current-time)) t))
                    60.0))))
    (mod (+ utc (/ lon 15.0) 24.0) 24.0)))

(defun ham-spacewx-fof2 (&optional time)
  "Return the estimated F2 critical frequency in MHz, or nil.

Rises with sunlight and with solar activity, peaks a couple of hours
after local noon, falls away from the magnetic equator, and is
depressed by a geomagnetic storm in proportion to how far from the
equator the station sits.  TIME defaults to now."
  (let ((here (ham-station-latlon))
        (sfi (ham-spacewx--solar-activity)))
    (when (and here sfi)
      (let* ((latitude (ham-spacewx-latitude-factor (car here)))
             (night (* (+ ham-spacewx-fof2-night
                          (* ham-spacewx-fof2-night-per-sfi sfi))
                       latitude))
             (noon (* (+ ham-spacewx-fof2-noon
                         (* ham-spacewx-fof2-noon-per-sfi sfi))
                      latitude))
             (hour (ham-spacewx--local-hour (cdr here) time))
             (blend (max 0.0
                         (min 1.0
                              (+ 0.5 (* 0.5 (cos (/ (* float-pi
                                                       (- hour
                                                          ham-spacewx-f2-peak-hour))
                                                    12.0)))))))
             (quiet (+ night (* (- noon night) blend)))
             (kp (or (ham-spacewx-kp) 0))
             (geomagnetic (abs (ham-geomagnetic-latitude (car here) (cdr here))))
             (storm (* ham-spacewx-storm-depression
                       (max 0 (- kp 4))
                       (min 1.0 (/ geomagnetic 60.0)))))
        (max 0.5 (* quiet (- 1.0 (min 0.6 storm))))))))

(defun ham-spacewx-muf (&optional time)
  "Return the estimated maximum usable frequency in MHz, or nil.
For a single 3000 km hop from the operator's location.  TIME defaults
to now."
  (let ((fof2 (ham-spacewx-fof2 time)))
    (and fof2 (* fof2 ham-spacewx-obliquity-factor))))

(defun ham-spacewx-luf (&optional time)
  "Return the estimated lowest usable frequency in MHz, or nil.

Set by D layer absorption, which follows sunlight closely and rises
sharply during a flare.  TIME defaults to now."
  (let ((here (ham-station-latlon)))
    (when here
      (let* ((sun (ham-solar-zenith-cosine (car here) (cdr here) time))
             (daylight (expt (max 0.0 sun) 0.75))
             (r-level (or (ham-spacewx-scale-level
                           'R (ham-spacewx-xray-flux))
                          0)))
        (+ ham-spacewx-luf-night
           (* ham-spacewx-luf-day daylight)
           (* ham-spacewx-luf-per-r-level r-level daylight))))))

(defcustom ham-spacewx-bands
  '("160m" "80m" "40m" "30m" "20m" "17m" "15m" "12m" "10m" "6m")
  "Bands the propagation estimate reports on, in order."
  :type '(repeat string)
  :group 'ham-spacewx)

(defcustom ham-spacewx-muf-margin 1.15
  "How far above the MUF a band can still carry something.

Above the maximum usable frequency the F2 layer stops returning
signals, but the transition is not a cliff: scatter and sporadic E keep
a band marginally alive for a little way past it.  Treating the MUF as
a hard edge marks bands shut that other estimates still call fair."
  :type 'number
  :group 'ham-spacewx)

(defcustom ham-spacewx-luf-margin 1.2
  "How far above the absorption floor a band is still attenuated."
  :type 'number
  :group 'ham-spacewx)

(defun ham-spacewx-band-condition (band &optional time)
  "Return the state of BAND at TIME: `closed', `poor', `fair' or `good'.

A band is good when it sits comfortably between the absorption floor
and the maximum usable frequency.  Close to either limit it is fair;
past the MUF it is poor rather than shut, since scatter and sporadic E
survive a little beyond; well past it, closed.  Returns nil when the
model has nothing to work from.  TIME defaults to now."
  (let ((muf (ham-spacewx-muf time))
        (luf (ham-spacewx-luf time))
        (entry (assoc band ham-bands)))
    (when (and muf luf entry)
      (let ((mhz (/ (+ (nth 1 entry) (nth 2 entry)) 2.0 1.0e6)))
        (cond
         ((> mhz (* ham-spacewx-muf-margin muf)) 'closed)
         ((> mhz muf) 'poor)
         ((< mhz luf) 'poor)
         ((< mhz (* ham-spacewx-luf-margin luf)) 'fair)
         ((> mhz (* 0.9 muf)) 'fair)
         (t 'good))))))

(defun ham-spacewx--time-at-local-hour (hour)
  "Return today's time at local solar HOUR for the operator's longitude."
  (let ((here (ham-station-latlon)))
    (when here
      (let* ((now (current-time))
             (utc-hour (mod (- hour (/ (cdr here) 15.0)) 24.0))
             (day (decode-time now t)))
        (encode-time 0
                     (round (* 60 (- utc-hour (floor utc-hour))))
                     (floor utc-hour)
                     (nth 3 day) (nth 4 day) (nth 5 day) t)))))

(defun ham-spacewx-band-conditions-at (hour)
  "Return an alist of band and condition at local solar HOUR."
  (let ((time (ham-spacewx--time-at-local-hour hour)))
    (mapcar (lambda (band)
              (cons band (ham-spacewx-band-condition band time)))
            ham-spacewx-bands)))

(defun ham-spacewx--condition-face (condition)
  "Return the face for a band CONDITION."
  (pcase condition
    ('good 'ham-spacewx-scale-0)
    ('fair 'ham-spacewx-scale-1)
    ('poor 'ham-spacewx-scale-2)
    ('closed 'ham-spacewx-scale-4)
    (_ 'ham-spacewx-label)))

;;;; Time spans

(defun ham-spacewx--parse-time (string)
  "Return STRING as an Emacs time value, or nil if it cannot be read.
SWPC writes time tags two ways, `2026-08-23 20:00:00.000' in the
products tree and `2026-08-23T20:00:00Z' in the JSON tree.  The
fractional seconds defeat `date-to-time', so they go first."
  (when (stringp string)
    (ignore-errors
      (date-to-time (replace-regexp-in-string "\\.[0-9]+" "" string)))))

(defun ham-spacewx--duration-label (seconds)
  "Return SECONDS as a short human duration."
  (let ((minutes (/ seconds 60.0)))
    (cond
     ((< minutes 1) "under a minute")
     ((< minutes 90) (format "%d min" (round minutes)))
     ((< minutes 2880) (format "%d h" (round (/ minutes 60))))
     (t (format "%d d" (round (/ minutes 1440)))))))

(defun ham-spacewx--span-label (times)
  "Return how long TIMES covers, as a short string, or nil.

The units are coarse on purpose.  A window that drifts between 23 and
24 hours as samples arrive should read `24 h' throughout rather than
flickering, because the figure is there to set the reader's
expectations, not to be measured against."
  (let ((parsed (delq nil (mapcar #'ham-spacewx--parse-time times))))
    (when (cdr parsed)
      (let* ((seconds (abs (float-time (time-subtract (car (last parsed))
                                                      (car parsed)))))
             (minutes (/ seconds 60.0)))
        (cond
         ((< minutes 1) nil)
         ((< minutes 90) (format "%d min" (round minutes)))
         ((< minutes 2880) (format "%d h" (round (/ minutes 60))))
         (t (format "%d d" (round (/ minutes 1440)))))))))

;;;; Sparklines

(defconst ham-spacewx--blocks ["▁" "▂" "▃" "▄" "▅" "▆" "▇" "█"]
  "Block characters used to draw a sparkline, shortest first.")

(defconst ham-spacewx--ascii ["_" "." "-" "~" "=" "+" "*" "#"]
  "Fallback ramp for frames that cannot show block characters.")

(defun ham-spacewx--ramp ()
  "Return the character ramp to draw sparklines with."
  (if (ham-unicode-blocks-p) ham-spacewx--blocks ham-spacewx--ascii))

(defun ham-spacewx--sparkline-bounds (series metric)
  "Return the (LOW . HIGH) the ramp should span for SERIES under METRIC.
A signed metric is scaled symmetrically about zero so the midpoint of
the ramp always means zero.  Everything else spans its own range, which
uses the full ramp for whatever variation is present."
  (if (memq metric ham-spacewx-signed-metrics)
      (let ((magnitude (apply #'max (mapcar #'abs series))))
        (if (zerop magnitude) (cons -1.0 1.0) (cons (- magnitude) magnitude)))
    (cons (apply #'min series) (apply #'max series))))

(defun ham-spacewx-sparkline (values &optional width metric)
  "Return VALUES drawn as a sparkline string of WIDTH characters.
WIDTH defaults to `ham-spacewx-series-length'.  Only the last WIDTH
values are drawn.  When METRIC is given, each sample is coloured by its
own severity, so the moment a storm developed is visible in the trace
rather than only in the current value, and a metric listed in
`ham-spacewx-signed-metrics' is scaled about zero.  Returns an empty
string for an empty series, and a flat line when every value is the
same, rather than dividing by zero."
  (let* ((numbers (ham-spacewx--numbers values))
         (width (or width ham-spacewx-series-length))
         (series (ham-spacewx--tail numbers width))
         (ramp (ham-spacewx--ramp))
         (steps (1- (length ramp))))
    (if (null series)
        ""
      (let* ((bounds (ham-spacewx--sparkline-bounds series metric))
             (low (car bounds))
             (span (- (cdr bounds) low)))
        (mapconcat
         (lambda (value)
           (let ((glyph (aref ramp (if (zerop span)
                                       (/ steps 2)
                                     (min steps
                                          (max 0 (round (* steps (/ (- value low)
                                                                    (float span)))))))))
                 (face (and metric (ham-spacewx--face-for metric value))))
             (if face (propertize glyph 'face face) glyph)))
         series "")))))

(defun ham-spacewx--scale-note (series metric)
  "Return a note describing the vertical scale of SERIES, or nil.

A signed METRIC reports the half height, since its midpoint is zero and
what matters is how far either way the trace reaches.  Everything else
reports the range the ramp spans, which is what says whether a dramatic
looking trace is a real excursion or a flat reading magnified.

SERIES must already be trimmed to the window being drawn, or the note
describes a range that is not on screen."
  (let ((numbers (ham-spacewx--numbers series)))
    (when (cdr numbers)
      (let ((low (apply #'min numbers))
            (high (apply #'max numbers)))
        (cond
         ((memq metric ham-spacewx-signed-metrics)
          (let ((magnitude (max (abs low) (abs high))))
            (and (> magnitude 0)
                 (format "±%s" (ham-spacewx--format-number magnitude)))))
         ((= low high) nil)
         (t (ham-spacewx--format-range low high metric)))))))

(defun ham-spacewx--format-number (value)
  "Return VALUE with one decimal, dropping a trailing zero."
  (let ((text (format "%.1f" value)))
    (if (string-suffix-p ".0" text) (substring text 0 -2) text)))

(defun ham-spacewx--format-range (low high metric)
  "Return the range LOW to HIGH of METRIC as a short string.

X-ray flux is written as flare classes, because at one decimal its
range reads as zero to zero: the whole scale lives below 0.001.
Otherwise the precision follows the magnitude, and both ends are given
the same precision so the pair reads as a range rather than as two
unrelated numbers."
  (if (eq (ham-spacewx-metric-scale metric) 'R)
      (format "%s–%s" (or (ham-spacewx-xray-class low) "?")
              (or (ham-spacewx-xray-class high) "?"))
    (let* ((magnitude (max (abs low) (abs high)))
           (decimals (cond
                      ((and (= low (truncate low)) (= high (truncate high))) 0)
                      ((>= magnitude 100) 0)
                      ((>= magnitude 1) 1)
                      (t 2)))
           (fmt (format "%%.%df" decimals)))
      (format "%s–%s" (format fmt low) (format fmt high)))))


;;;; Fetching

(defun ham-spacewx--due-p (source &optional force)
  "Return non-nil if SOURCE should be fetched now.
With FORCE, only an outstanding request holds it back."
  (let* ((key (ham-spacewx-source-key source))
         (age (ham-spacewx--age key)))
    (and (not (memq key ham-spacewx--in-flight))
         (or force (null age) (> age (ham-spacewx-source-interval source))))))

(defun ham-spacewx--store (key payload error)
  "Record PAYLOAD or ERROR against KEY and refresh the panel.

A failed fetch keeps whatever was read last.  Overwriting good data
with nil is why the panel came up empty after the machine woke from
sleep: every feed timed out at once, and readings that were merely a
few hours old were discarded rather than shown as old.  Stale space
weather is worth seeing as long as the panel says how old it is; an
empty panel tells the operator nothing at all."
  (setq ham-spacewx--in-flight (delq key ham-spacewx--in-flight))
  (setq ham-spacewx--generation (1+ ham-spacewx--generation))
  (let* ((previous (ham-spacewx--entry key))
         (kept (if error (plist-get previous :payload) payload))
         (fetched (if error (plist-get previous :fetched) (current-time))))
    (puthash key (list :payload kept
                       :fetched fetched
                       :error error
                       :failed (and error (current-time)))
             ham-spacewx--data))
  (if error
      (ham-log "ham-spacewx: %s failed: %s%s" key error
               (if (ham-spacewx--payload key) " (keeping last reading)" ""))
    (ham-log "ham-spacewx: %s updated" key))
  (when error (ham-spacewx--schedule-retry key))
  ;; Redraw once the whole refresh has landed rather than after each
  ;; feed.  Redrawing per source rebuilds the panel five times, and the
  ;; intermediate states show readings that are about to change.
  (unless ham-spacewx--in-flight
    (ham-spacewx--redisplay))
  (unless error
    (ham-publish 'ham-spacewx-updated key payload)))

(defvar ham-spacewx--retried nil
  "Keys retried since the last successful read, so retries do not loop.")

(defun ham-spacewx--schedule-retry (key)
  "Try KEY once more after a short delay.

A machine that has just woken finds its network not yet up, and every
feed fails at once.  One retry a few seconds later almost always
succeeds, and turns a panel full of errors into an ordinary refresh."
  (unless (memq key ham-spacewx--retried)
    (push key ham-spacewx--retried)
    (ham-spacewx--remember-timer
     (run-at-time
      ham-spacewx-retry-delay nil
      (lambda ()
       (let ((source (ham-spacewx-source key)))
          (when (and source (not (memq key ham-spacewx--in-flight)))
            (ham-log "ham-spacewx: retrying %s" key)
            (ham-spacewx--fetch source))))))))

(defun ham-spacewx--body ()
  "Return the response body in the current retrieval buffer.
Returns nil if the headers cannot be found."
  (goto-char (point-min))
  (when (re-search-forward "\r?\n\r?\n" nil t)
    (buffer-substring-no-properties (point) (point-max))))

(defun ham-spacewx--describe-error (spec)
  "Return a readable description of SPEC, the `:error' from a retrieval.
`url-retrieve' reports an HTTP failure as (error http CODE), which says
nothing useful when printed raw.  Anything else is passed through."
  (pcase spec
    (`(error http ,code) (format "HTTP %s" code))
    (_ (error-message-string spec))))

(defun ham-spacewx--describe-body (body)
  "Return the leading text of BODY, for reporting a parse failure.
A feed that has moved often answers with an HTML error page, and seeing
the first line of it identifies that immediately."
  (let ((head (string-trim (substring body 0 (min 120 (length body))))))
    (replace-regexp-in-string "[ \t\n\r]+" " " head)))

(defun ham-spacewx--handle (status key shape)
  "Handle a completed retrieval for KEY with payload layout SHAPE.
STATUS is the plist `url-queue-retrieve' passes to its callback."
  (let ((buffer (current-buffer))
        payload error)
    (unwind-protect
        (cond
         ((plist-get status :error)
          (setq error (ham-spacewx--describe-error (plist-get status :error))))
         (t
          (let ((body (ham-spacewx--body)))
            (cond
             ((null body) (setq error "no response body"))
             ((string-empty-p (string-trim body))
              (setq error "empty response body"))
             (t
              (condition-case err
                  (setq payload (ham-spacewx--parse-body body shape))
                (error
                 (setq error (format "%s — got: %s"
                                     (error-message-string err)
                                     (ham-spacewx--describe-body body))))))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))
    (ham-spacewx--store key payload error)))

(defun ham-spacewx--curl ()
  "Return the curl program to use, or nil if it should not be used."
  (pcase ham-spacewx-fetch-backend
    ('url nil)
    ('curl (or (executable-find "curl") "curl"))
    (_ (executable-find "curl"))))

(defun ham-spacewx--parse-body (body shape)
  "Parse BODY according to SHAPE."
  (if (consp shape)
      (ham-spacewx--parse-columns body shape)
    (ham-spacewx--parse-json body)))

(defun ham-spacewx--fetch-with-curl (curl key url shape &optional seconds)
  "Read URL for KEY through CURL as a subprocess, parsing it as SHAPE.
SECONDS overrides the default timeout.  `make-process' hands the work
to the operating system and returns immediately, so a network that
never answers costs nothing but a wait for a callback that arrives
later."
  (let ((buffer (generate-new-buffer (format " *ham-spacewx-%s*" key))))
    (make-process
     :name (format "ham-spacewx-%s" key)
     :buffer buffer
     :noquery t
     :connection-type 'pipe
     :command (list curl "--silent" "--show-error" "--location"
                    "--compressed"
                    "--max-time" (number-to-string
                                  (or seconds ham-spacewx-request-timeout))
                    "--write-out" "\nham-spacewx-status:%{http_code}"
                    url)
     :sentinel
     (lambda (process _event)
       (unless (process-live-p process)
         (let ((body nil) (status nil) (failure nil))
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (goto-char (point-max))
               (if (re-search-backward "^ham-spacewx-status:\\([0-9]+\\)$"
                                       nil t)
                   (setq status (string-to-number (match-string 1))
                         body (buffer-substring-no-properties
                               (point-min) (match-beginning 0)))
                 (setq body (buffer-string))))
             (kill-buffer buffer))
           (cond
            ((and status (>= status 400))
             (setq failure (format "HTTP %d" status)))
            ((= (process-exit-status process) 28)
             (setq failure (format "timed out after %ss"
                                   (or seconds ham-spacewx-request-timeout))))
            ((/= (process-exit-status process) 0)
             (setq failure (format "curl exit %d: %s"
                                   (process-exit-status process)
                                   (string-trim
                                    (substring (or body "")
                                               0 (min 100 (length
                                                           (or body ""))))))))
            ((or (null body) (string-empty-p (string-trim body)))
             (setq failure "empty response body")))
           (if failure
               (ham-spacewx--store key nil failure)
             (condition-case err
                 (ham-spacewx--store
                  key (ham-spacewx--parse-body body shape) nil)
               (error
                (ham-spacewx--store
                 key nil (format "%s — got: %s"
                                 (error-message-string err)
                                 (ham-spacewx--describe-body body))))))))))))

(defun ham-spacewx--fetch-with-url (key url shape &optional seconds)
  "Read URL for KEY through `url.el'.
Kept as a fallback for machines with no curl.  Its connection setup can
block, which is why it is not the first choice."
  (let ((url-queue-timeout (or seconds ham-spacewx-request-timeout)))
    (url-queue-retrieve
     url
     (lambda (status) (ham-spacewx--handle status key shape))
     nil t t)))

(defun ham-spacewx--fetch (source)
  "Start an asynchronous read of SOURCE."
  (let ((key (ham-spacewx-source-key source))
        (url (ham-spacewx-source-url source))
        (shape (if (eq (ham-spacewx-source-shape source) 'columns)
                   (ham-spacewx-source-columns source)
                 (ham-spacewx-source-shape source)))
        (seconds (ham-spacewx-source-seconds source))
        (curl (ham-spacewx--curl)))
    (push key ham-spacewx--in-flight)
    (setq ham-spacewx--retried (delq key ham-spacewx--retried))
    (ham-log "ham-spacewx: fetching %s from %s via %s"
             key url (if curl "curl" "url.el"))
    (condition-case err
        (if curl
            (ham-spacewx--fetch-with-curl curl key url shape seconds)
          (ham-spacewx--fetch-with-url key url shape seconds))
      (error (ham-spacewx--store key nil (error-message-string err))))))

;;;###autoload
(defun ham-spacewx-refresh (&optional force)
  "Read every source whose data has aged past its own interval.
With a prefix argument, or non-nil FORCE, read every source regardless."
  (interactive "P")
  (dolist (source ham-spacewx--sources)
    (when (ham-spacewx--due-p source force)
      (ham-spacewx--fetch source)))
  ;; Nothing was due, so nothing will call back: draw now.
  (unless ham-spacewx--in-flight
    (ham-spacewx--redisplay)))

;;;###autoload
(defun ham-spacewx-diagnose ()
  "Re-read every feed and report exactly what each one answered.
Writes the address, the outcome and, where a feed parsed, the shape of
what came back.  This is the first thing to run when the panel shows no
readings: it distinguishes a moved endpoint from a network problem from
a payload this package does not understand."
  (interactive)
  (let ((buffer (get-buffer-create "*ham-spacewx-diagnose*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (insert "ham-spacewx diagnostics\n")
        (insert (format "Emacs %s, system-type %s\n" emacs-version system-type))
        (insert (format "Fetching via %s\n"
                        (if (ham-spacewx--curl) "curl" "url.el")))
        (insert "(windows-nt is Emacs's name for every modern Windows,\n")
        (insert " not a version number)\n\n")
        (insert "Refreshing every feed.  Run this again in a few seconds\n")
        (insert "if any source still reads \"fetching\".\n\n")))
    (ham-spacewx-refresh t)
    (run-at-time
     2 nil
     (lambda ()
       (with-current-buffer buffer
         (let ((inhibit-read-only t))
           (goto-char (point-max))
           (dolist (source ham-spacewx--sources)
             (let* ((key (ham-spacewx-source-key source))
                    (payload (ham-spacewx--payload key))
                    (err (ham-spacewx--error key)))
               (insert (format "%s\n  %s\n"
                               (ham-spacewx-source-label source)
                               (ham-spacewx-source-url source)))
               (insert
                (cond
                 ((memq key ham-spacewx--in-flight) "  still fetching\n")
                 (err (format "  FAILED: %s\n" err))
                 ((null payload) "  parsed, but empty\n")
                 (t (format "  ok, %d %s\n  %s: %s\n  reading: %s\n"
                            (length payload)
                            (if (ham-spacewx--table-p payload)
                                "rows including the header"
                              "records")
                            (if (ham-spacewx--table-p payload)
                                "columns" "fields")
                            (mapconcat #'identity
                                       (ham-spacewx--field-names payload) ", ")
                            (or (ham-spacewx--number-string
                                 (pcase key
                                   ('wind (ham-spacewx-solar-wind-speed))
                                   ('mag (ham-spacewx-bz))
                                   ('kindex (ham-spacewx-kp))
                                   ('xray (ham-spacewx-xray-flux))
                                   ('flux (ham-spacewx-solar-flux)))
                                 "%s")
                                "NONE — no candidate field matched")))))
               (insert "\n")))))))
    (pop-to-buffer buffer)))


;;;; Rendering

(defconst ham-spacewx--label-width 32
  "Column width for reading labels.")

(defconst ham-spacewx--value-width 14
  "Column width for reading values.")

(defconst ham-spacewx--sparkline-indent 4
  "Indent of the sparkline line beneath its reading.")

(defun ham-spacewx--heading (text)
  "Insert TEXT as a section heading."
  (insert "\n" (propertize text 'face 'ham-spacewx-heading) "\n"))

(defun ham-spacewx--row (label value &optional note metric reading)
  "Insert one reading, and its trend beneath it.

LABEL names the reading and VALUE is its formatted value.  NOTE is an
optional plain description shown after it.

METRIC supplies the series, the window and the colours.  READING is the
number behind VALUE; the colour comes from it rather than from the
sparkline, because the sparkline may be resampled and the last bucket's
average is not the current reading.  When READING is omitted the last
drawn sample stands in.

One colour covers the value, the note and every sample of the trace, so
a reading and the words describing it never disagree."
  (let* ((drawn (and metric (ham-spacewx-metric-drawn metric)))
         (series (car drawn))
         (span (ham-spacewx--span-label (cdr drawn)))
         (scale (ham-spacewx--scale-note series metric))
         (annotation (string-join (delq nil (list span scale)) ", "))
         (shown (if (and metric (null reading))
                    (ham-spacewx--latest series)
                  reading))
         (face (or (and metric (ham-spacewx--face-for metric shown))
                   'ham-spacewx-value))
         (name (if (string-empty-p annotation)
                   label
                 (format "%s (%s)" label annotation))))
    (insert "  "
            (propertize (string-pad name ham-spacewx--label-width)
                        'face 'ham-spacewx-label)
            (propertize (or value "—") 'face face))
    (when (and note (not (string-empty-p note)))
      (insert "  " (propertize note 'face face)))
    ;; Every reading reports its own age, rather than only the ones
    ;; whose feed happened to fail.  A number the operator cannot date
    ;; is worse than no number.
    (let ((age (and metric (ham-spacewx--metric-age metric))))
      (when age
        (insert (propertize (format "  (%s old)"
                                    (ham-spacewx--duration-label age))
                            'face 'ham-spacewx-stale))))
    (insert "\n")
    (when series
      (let ((line (ham-spacewx-sparkline series
                                         (ham-spacewx-metric-window metric)
                                         metric)))
        (unless (string-empty-p line)
          (insert (make-string ham-spacewx--sparkline-indent ?\s))
          (insert (if (get-text-property 0 'face line)
                      line
                    (propertize line 'face 'ham-spacewx-sparkline)))
          (insert "\n"))))))

(defun ham-spacewx--number-string (value format-string)
  "Return VALUE rendered with FORMAT-STRING, or nil if VALUE is nil."
  (and value (format format-string value)))


(defun ham-spacewx--metric-age (metric)
  "Return how old METRIC's data is, in seconds, if it is worth saying.
Returns nil while the reading is current, so an ordinary panel is not
cluttered with ages that all say the same thing."
  (let* ((key (ham-spacewx-metric-source metric))
         (age (and key (ham-spacewx--age key))))
    (and age (> age ham-spacewx-stale-after) age)))

(defun ham-spacewx--source-note (key)
  "Return a short status string for KEY, or nil if it is current."
  (cond
   ((memq key ham-spacewx--in-flight) "fetching…")
   ((ham-spacewx--error key)
    (let ((age (ham-spacewx--age key)))
      (if age
          (format "%s — showing the reading from %s ago"
                  (ham-spacewx--error key)
                  (ham-spacewx--duration-label age))
        (format "unavailable: %s" (ham-spacewx--error key)))))
   ((null (ham-spacewx--fetched-at key)) "not fetched")
   ((ham-spacewx--stale-p key)
    (format "stale, %s old" (ham-spacewx--duration-label
                             (ham-spacewx--age key))))))

(defun ham-spacewx--render-propagation ()
  "Insert the propagation estimate, or say why there is none."
  (ham-spacewx--heading "Propagation (estimated)")
  (cond
   ((null (ham-station-latlon))
    (insert (propertize
             "  Set `ham-station-grid' to your locator for a local estimate.\n"
             'face 'ham-spacewx-label)))
   ((null (ham-spacewx-muf))
    (insert (propertize "  Waiting for solar data.\n" 'face 'ham-spacewx-label)))
   (t
    (let* ((muf (ham-spacewx-muf))
           (luf (ham-spacewx-luf))
           (night (time-add (current-time) (seconds-to-time (* 12 3600))))
           (muf-night (ham-spacewx-muf night)))
      (ham-spacewx--row
       "MUF, 3000 km hop"
       (format "%.1f MHz" muf)
       (format "now; %.1f MHz in 12 h" muf-night))
      (ham-spacewx--row "Absorption floor" (format "%.1f MHz" luf))
      ;; Day and night separately.  A single row for "now" hides the
      ;; thing an operator actually plans around: which bands will be
      ;; there this evening, and which will not.
      (dolist (period (list (cons "Bands by day" ham-spacewx-f2-peak-hour)
                            (cons "Bands at night" 2.0)))
        (insert "  " (propertize (string-pad (car period)
                                             ham-spacewx--label-width)
                                 'face 'ham-spacewx-label))
        (dolist (entry (ham-spacewx-band-conditions-at (cdr period)))
          (insert (propertize (car entry) 'face
                              (ham-spacewx--condition-face (cdr entry)))
                  " "))
        (insert "\n"))
      (insert "  " (string-pad "" ham-spacewx--label-width))
      (dolist (state '((good . "good") (fair . "fair")
                       (poor . "marginal") (closed . "closed")))
        (insert (propertize (cdr state) 'face
                            (ham-spacewx--condition-face (car state)))
                " "))
      (insert "\n")))))

(defun ham-spacewx--render-status ()
  "Insert a line per source that is not currently healthy."
  (let ((notes (delq nil
                     (mapcar (lambda (source)
                               (let* ((key (ham-spacewx-source-key source))
                                      (note (ham-spacewx--source-note key)))
                                 (and note (cons source note))))
                             ham-spacewx--sources))))
    (when notes
      (ham-spacewx--heading "Sources")
      (dolist (entry notes)
        (ham-spacewx--row (ham-spacewx-source-label (car entry))
                          nil (cdr entry))
        ;; A failure is only actionable if it says which address failed.
        (when (ham-spacewx--error (ham-spacewx-source-key (car entry)))
          (insert (propertize
                   (format "  %s%s\n"
                           (make-string ham-spacewx--label-width ?\s)
                           (ham-spacewx-source-url (car entry)))
                   'face 'ham-spacewx-stale))))
      (insert (propertize "\n  M-x ham-spacewx-diagnose for detail\n"
                          'face 'ham-spacewx-label)))))

(defun ham-spacewx-scale-now (scale)
  "Return the current level of SCALE, or nil."
  (let ((metric (ham-spacewx-scale-metric scale)))
    (ham-spacewx-scale-level scale (ham-spacewx-metric-value metric))))

(defun ham-spacewx-scale-peak (scale hours)
  "Return the highest level SCALE reached in the last HOURS, or nil."
  (let* ((metric (ham-spacewx-scale-metric scale))
         (samples (ham-spacewx--within-days
                   (ham-spacewx-metric-samples metric) (/ hours 24.0)))
         (values (mapcar #'car samples)))
    (and values (ham-spacewx-scale-level scale (apply #'max values)))))

(defun ham-spacewx--scale-badge (scale level)
  "Return SCALE and LEVEL rendered as a coloured badge such as G2."
  (propertize (format "%s%s" scale (or level "?"))
              'face (or (ham-spacewx-scale-face level) 'ham-spacewx-label)
              'help-echo (format "%s: %s"
                                 (ham-spacewx-scale-description scale)
                                 (pcase level
                                   (0 "none")
                                   (1 "minor") (2 "moderate") (3 "strong")
                                   (4 "severe") (5 "extreme")
                                   (_ "no data")))))

(defun ham-spacewx--render-scales ()
  "Insert the NOAA scale line: current levels, then the last day's peak."
  (insert "  " (propertize "now" 'face 'ham-spacewx-label) "  ")
  (dolist (scale '(R S G))
    (insert (ham-spacewx--scale-badge scale (ham-spacewx-scale-now scale)) " "))
  (insert "   " (propertize "24 h peak" 'face 'ham-spacewx-label) "  ")
  (dolist (scale '(R S G))
    (insert (ham-spacewx--scale-badge scale (ham-spacewx-scale-peak scale 24))
            " "))
  (insert "\n"))

(defun ham-spacewx--render-solar ()
  "Insert the solar section."
  (ham-spacewx--heading "Solar")
  (let ((now (ham-spacewx-xray-flux))
        (peak (ham-spacewx-xray-max))
        (flux (ham-spacewx-solar-flux))
        (protons (ham-spacewx-proton-flux)))
    (ham-spacewx--row "X-ray" (or (ham-spacewx-xray-class now) "—")
                      nil 'xray now)
    (ham-spacewx--row "X-ray peak" (or (ham-spacewx-xray-class peak) "—")
                      nil 'xray-max peak)
    (ham-spacewx--row "10.7 cm flux"
                      (ham-spacewx--number-string flux "%.0f sfu")
                      nil 'flux flux)
    (let ((ssn (ham-spacewx-sunspot-number)))
      (ham-spacewx--row "Sunspot number"
                        (ham-spacewx--number-string ssn "%.0f")
                        nil 'sunspots ssn))
    (ham-spacewx--row "Proton >=10 MeV"
                      (ham-spacewx--number-string protons "%.2f pfu")
                      nil 'protons protons)))

(defun ham-spacewx--render-geomagnetic ()
  "Insert the geomagnetic section."
  (ham-spacewx--heading "Geomagnetic")
  (let ((kp (ham-spacewx-kp))
        (a (ham-spacewx-a-index)))
    (ham-spacewx--row "Planetary K"
                      (ham-spacewx--number-string kp "%.0f")
                      (ham-spacewx-kp-description kp) 'kp kp)
    (ham-spacewx--row "A index"
                      (ham-spacewx--number-string a "%.0f")
                      nil 'a-index a)))

(defun ham-spacewx--render-solar-wind ()
  "Insert the solar wind section.

Every value is the latest sample, never the last bucket of a resampled
trace: the number answers what the wind is doing now, and the trace
beside it answers what it has been doing."
  (let ((spacecraft (ham-spacewx-spacecraft)))
    (ham-spacewx--heading (if spacecraft
                              (format "Solar wind (%s)" spacecraft)
                            "Solar wind")))
  (let ((speed (ham-spacewx-solar-wind-speed))
        (density (ham-spacewx-solar-wind-density))
        (bt (ham-spacewx-bt))
        (bz (ham-spacewx-bz)))
    (ham-spacewx--row "Speed"
                      (ham-spacewx--number-string speed "%.0f km/s")
                      nil 'speed speed)
    (ham-spacewx--row "Density"
                      (ham-spacewx--number-string density "%.1f p/cm³")
                      nil 'density density)
    (ham-spacewx--row "Bt"
                      (ham-spacewx--number-string bt "%.1f nT")
                      nil 'bt bt)
    (ham-spacewx--row "Bz"
                      (ham-spacewx--number-string bz "%.1f nT")
                      (ham-spacewx-bz-description bz) 'bz bz)))

(defun ham-spacewx--render ()
  "Redraw the panel into the current buffer."
  (let ((inhibit-read-only t)
        (point (point)))
    (erase-buffer)
    (insert (propertize "Space Weather" 'face 'ham-spacewx-heading))
    (let* ((ages (delq nil (mapcar (lambda (source)
                                     (ham-spacewx--age
                                      (ham-spacewx-source-key source)))
                                   ham-spacewx--sources)))
           (oldest (and ages (seq-max ages)))
           (minutes (and oldest (floor (/ oldest 60)))))
      (insert (propertize
               (format "   NOAA SWPC%s\n"
                       (if (and minutes (> minutes 0))
                           (format ", oldest reading %d min" minutes)
                         ""))
               'face 'ham-spacewx-label)))
    (ham-spacewx--render-scales)
    (ham-spacewx--render-solar)
    (ham-spacewx--render-geomagnetic)
    (ham-spacewx--render-solar-wind)
    (ham-spacewx--render-propagation)
    (ham-spacewx--render-status)
    ;; Column padding leaves trailing spaces on rows that carry neither a
    ;; description nor a sparkline.  They are invisible until someone
    ;; selects a region or diffs a capture of the buffer.
    (delete-trailing-whitespace)
    (goto-char (min point (point-max)))))

(defun ham-spacewx--redisplay ()
  "Redraw the panel if it exists."
  (let ((buffer (get-buffer ham-spacewx-buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ham-spacewx--render)))))


;;;; Automatic refresh

(defvar ham-spacewx--timer nil
  "Timer driving automatic refresh, or nil.")

(defvar ham-spacewx--pending-timers nil
  "One-shot timers this package has scheduled and may still cancel.")

(defun ham-spacewx--remember-timer (timer)
  "Track TIMER so it can be cancelled once the panel is gone.
An abandoned one-shot timer fires into a dead buffer, and on resume
several can come due at once."
  (setq ham-spacewx--pending-timers
        (cons timer (seq-filter #'timerp ham-spacewx--pending-timers)))
  timer)

(defun ham-spacewx--cancel-pending ()
  "Cancel every one-shot timer this package is holding."
  (dolist (timer ham-spacewx--pending-timers)
    (when (timerp timer) (cancel-timer timer)))
  (setq ham-spacewx--pending-timers nil))

(defun ham-spacewx--start-timer ()
  "Start the automatic refresh timer if it is wanted and not running."
  (when (and ham-spacewx-auto-refresh-interval (null ham-spacewx--timer))
    (setq ham-spacewx--timer
          (run-at-time ham-spacewx-auto-refresh-interval
                       ham-spacewx-auto-refresh-interval
                       #'ham-spacewx--tick))))

(defun ham-spacewx--stop-timer ()
  "Stop the automatic refresh timer."
  (when ham-spacewx--timer
    (cancel-timer ham-spacewx--timer)
    (setq ham-spacewx--timer nil))
  (ham-spacewx--cancel-pending))

(defvar ham-spacewx--last-tick nil
  "When the refresh timer last ran, used to notice a suspended machine.")

(defun ham-spacewx--slept-p (gap)
  "Return non-nil if GAP seconds is too long for a normal tick.
A repeating timer fires once on resume however long the machine was
away, so a gap far past the interval means it was suspended rather
than merely busy."
  (and gap ham-spacewx-auto-refresh-interval
       (> gap (* 3 ham-spacewx-auto-refresh-interval))))

(defun ham-spacewx--tick ()
  "Refresh while the panel is live, and stop the timer once it is gone.

Three things are deliberately not done here.  A tick never starts a
refresh while one is still outstanding, because stacking requests on a
network that is not answering is how a slow refresh becomes a frozen
Emacs.  A tick that lands right after the machine woke defers instead
of firing, because at that moment the network usually is not up and
every request will block until it times out.  And a panel that has
been killed stops the timer rather than leaving it running."
  (let* ((now (current-time))
         (gap (and ham-spacewx--last-tick
                   (float-time (time-subtract now ham-spacewx--last-tick)))))
    (setq ham-spacewx--last-tick now)
    (cond
     ((not (buffer-live-p (get-buffer ham-spacewx-buffer-name)))
      (ham-spacewx--stop-timer))
     (ham-spacewx--in-flight
      (ham-log "ham-spacewx: refresh still running, skipping this tick"))
     ((ham-spacewx--slept-p gap)
      (ham-log "ham-spacewx: %.0fs gap suggests resume, waiting %ss"
               gap ham-spacewx-wake-delay)
      (ham-spacewx--redisplay)
      (ham-spacewx--remember-timer
       (run-at-time ham-spacewx-wake-delay nil #'ham-spacewx--wake)))
     (t (ham-spacewx-refresh)))))

(defun ham-spacewx--wake ()
  "Refresh after a resume, once the network has had time to come back."
  (when (buffer-live-p (get-buffer ham-spacewx-buffer-name))
    (setq ham-spacewx--retried nil)
    (ham-spacewx-refresh t)))


;;;; Mode

(defun ham-spacewx-refresh-all ()
  "Read every feed now, regardless of how recently it was read."
  (interactive)
  (ham-spacewx-refresh t))

(defvar-keymap ham-spacewx-mode-map
  :doc "Keymap for `ham-spacewx-mode'."
  "g" #'ham-spacewx-refresh
  "G" #'ham-spacewx-refresh-all
  "c" #'ham-spacewx-clear
  "w" #'ham-spacewx-show-wind-sample
  "?" #'ham-spacewx-help)

(easy-menu-define ham-spacewx-mode-menu ham-spacewx-mode-map
  "Menu for `ham-spacewx-mode'."
  '("Space Wx"
    ["Refresh aged sources" ham-spacewx-refresh :keys "g"
     :help "Read any feed whose data has passed its own interval"]
    ["Refresh everything now" ham-spacewx-refresh-all :keys "G"
     :help "Read every feed regardless of how recently it was read"]
    "---"
    ["Show solar wind sample" ham-spacewx-show-wind-sample :keys "w"
     :help "The exact record the wind readings come from"]
    ["Diagnose feeds" ham-spacewx-diagnose
     :help "Report each feed's address, outcome and field names"]
    ["Discard stored readings" ham-spacewx-clear :keys "c"
     :help "Forget every reading, so the next refresh starts clean"]
    "---"
    ["Explain this panel" ham-spacewx-help :keys "?"
     :help "What each reading means and how to read the trends"]
    ["Customize" (lambda () (interactive) (customize-group 'ham-spacewx))
     :help "Endpoints, windows, thresholds and colours"]
    "---"
    ["Bury panel" quit-window]))

(define-derived-mode ham-spacewx-mode special-mode "Space Wx"
  "Major mode for the space weather panel.

\\{ham-spacewx-mode-map}"
  (buffer-disable-undo)
  (setq-local truncate-lines t)
  (add-hook 'kill-buffer-hook #'ham-spacewx--stop-timer nil t))

(defun ham-spacewx-help ()
  "Describe the space weather panel keys and readings."
  (interactive)
  (with-help-window "*ham-spacewx-help*"
    (princ "Space weather panel\n\n")
    (princ "Keys\n")
    (princ "  g    refresh sources whose data has aged out\n")
    (princ "  G    refresh every source now\n")
    (princ "  c    discard stored readings\n")
    (princ "  w    show the exact solar wind record in use\n")
    (princ "  q    bury the panel\n\n")
    (princ "Reading the panel\n")
    (princ "  The bracketed span after each name is how much time the\n")
    (princ "  sparkline beneath it covers.\n")
    (princ "  Values and sparkline samples are coloured by severity, so\n")
    (princ "  when a disturbance began is visible in the trace.\n")
    (princ "  Bz is drawn about zero: the middle of the ramp is zero, so\n")
    (princ "  a trace sitting low spent that window southward.  The plus\n")
    (princ "  or minus figure after it is the full height of the trace.\n\n")
    (princ "Readings\n")
    (princ "  10.7 cm flux   Solar radio flux in solar flux units.  Higher\n")
    (princ "                 values raise the maximum usable frequency.\n")
    (princ "  X-ray          GOES 0.1-0.8 nm band as a flare class.  M and X\n")
    (princ "                 flares cause shortwave fadeout on the sunlit side.\n")
    (princ "  Planetary K    Geomagnetic disturbance, 0 to 9.  5 and above is\n")
    (princ "                 a storm and degrades polar and high latitude paths.\n")
    (princ "  Speed          Solar wind speed.  Sustained high speed streams\n")
    (princ "                 drive recurring disturbance.\n")
    (princ "  Bz             North-south interplanetary field.  Sustained\n")
    (princ "                 southward field couples energy in and precedes\n")
    (princ "                 geomagnetic activity.\n\n")
    (princ "Data from the NOAA Space Weather Prediction Center.\n")
    (princ "Real time solar wind comes from DSCOVR; ACE is the backup.\n")))

;;;###autoload
(defun ham-spacewx ()
  "Open the space weather panel."
  (interactive)
  (let ((buffer (get-buffer-create ham-spacewx-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ham-spacewx-mode)
        (ham-spacewx-mode))
      (ham-spacewx--render))
    (pop-to-buffer buffer)
    (ham-spacewx-refresh)
    (ham-spacewx--start-timer)
    buffer))

(provide 'ham-spacewx)

;;; ham-spacewx.el ends here
