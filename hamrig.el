;;; ham-rig.el --- Transceiver control via rigctld -*- lexical-binding: t; -*-

;; Copyright (C) 2026 K6SM

;; Author: K6SM
;; Version: 0.1.0
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
(defvar ham-rig--tx-timer nil)
(defvar ham-rig--tx-started-at nil)
(defvar ham-rig--unkey-on-reconnect nil)
(defvar ham-rig--stats (list :requests 0 :timeouts 0 :errors 0
                             :latency-sum 0.0 :latency-max 0.0))

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
  "Abandon the in-flight request if it has gone unanswered."
  (when (and ham-rig--inflight
             (> (- (float-time) (ham-rig--request-sent-at ham-rig--inflight))
                ham-rig-request-timeout))
    (ham-log "ham-rig: timeout on %s" (ham-rig--request-command ham-rig--inflight))
    (cl-incf (plist-get ham-rig--stats :timeouts))
    (setq ham-rig--inflight nil
          ham-rig--resp-lines nil)
    (ham-rig--pump)))

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
the commands rigctld answers without one."
  (cond
   ((string-match "\\`RPRT \\(-?[0-9]+\\)" line)
    (ham-rig--complete (string-to-number (match-string 1 line))))
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
           (ham-rig-ptt-p)
           (ham-has-subscribers-p ham-rig-topic-frequency)
           (ham-has-subscribers-p ham-rig-topic-ptt))))

(defun ham-rig--poll-fast ()
  "Poll frequency, PTT and signal strength."
  (ham-rig--check-timeout)
  (when (ham-rig--should-poll-p)
    (ham-rig--enqueue
     "f" (lambda (r) (when-let ((hz (ham-rig--num r "Frequency")))
                       (ham-rig--set 'frequency (round hz))))
     'poll)
    (ham-rig--enqueue
     "t" (lambda (r) (let ((v (ham-rig--val r "PTT")))
                       (ham-rig--set 'ptt (and v (not (equal v "0"))))))
     'poll)
    (unless (ham-rig-ptt-p)
      (ham-rig--enqueue
       "l STRENGTH"
       (lambda (r) (ham-rig--set 'strength (ham-rig--num r "Strength")))
       'poll))))

(defun ham-rig--poll-slow ()
  "Poll mode, VFO, split and, while transmitting, SWR and ALC."
  (when (ham-rig--should-poll-p)
    (ham-rig--enqueue
     "m" (lambda (r)
           (ham-rig--set 'passband (ham-rig--num r "Passband"))
           (ham-rig--set 'mode (ham-rig--val r "Mode")))
     'poll)
    (ham-rig--enqueue
     "v" (lambda (r) (ham-rig--set 'vfo (ham-rig--val r "VFO")))
     'poll)
    (ham-rig--enqueue
     "s" (lambda (r)
           (ham-rig--set 'split-vfo (ham-rig--val r "TX VFO"))
           (let ((v (ham-rig--val r "Split")))
             (ham-rig--set 'split (and v (not (equal v "0"))))))
     'poll)
    (when (ham-rig-ptt-p)
      (ham-rig--enqueue
       "l SWR" (lambda (r) (ham-rig--set 'swr (ham-rig--num r "SWR")))
       'poll)
      (ham-rig--enqueue
       "l ALC" (lambda (r) (ham-rig--set 'alc (ham-rig--num r "ALC")))
       'poll))))

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
        (ham-connection-send ham-rig--connection "+T 0")
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
     (setq ham-rig--inflight nil ham-rig--queue nil ham-rig--resp-lines nil)
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
     (setq ham-rig--dirty t)
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
  (setq ham-rig--connection nil ham-rig--queue nil ham-rig--inflight nil)
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
    (ham-rig--enqueue "v" (lambda (r) (ham-rig--set 'vfo (ham-rig--val r "VFO"))))))

(defun ham-rig-toggle-split ()
  "Toggle split operation."
  (interactive)
  (let ((on (if (ham-rig-get 'split) 0 1)))
    (ham-rig--enqueue (format "S %d VFOB" on))))

(defun ham-rig-toggle-ptt ()
  "Key or unkey the transmitter."
  (interactive)
  (if (ham-rig-ptt-p)
      (progn (ham-rig--enqueue "T 0") (ham-rig--set 'ptt nil))
    (unless (ham-rig-connected-p)
      (user-error "Not connected to rigctld"))
    (ham-rig--enqueue "T 1")
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
    (message "ham-rig: %d requests, %d timeouts, %d errors, mean %.1f ms, max %.1f ms, queue %d"
             n
             (plist-get ham-rig--stats :timeouts)
             (plist-get ham-rig--stats :errors)
             (if (zerop n) 0.0 (* 1000 (/ (plist-get ham-rig--stats :latency-sum) n)))
             (* 1000 (plist-get ham-rig--stats :latency-max))
             (length ham-rig--queue))))


;;;; Rendering

(defconst ham-rig--partial-blocks ["" "▏" "▎" "▍" "▌" "▋" "▊" "▉"]
  "Eighth-cell block characters for smooth meters in a terminal.")

(defun ham-rig--bar (fraction width)
  "Return a bar of WIDTH characters filled to FRACTION, 0.0 to 1.0."
  (let* ((fraction (max 0.0 (min 1.0 (or fraction 0.0))))
         (unicode (ham-unicode-blocks-p))
         (exact (* fraction width))
         (full (floor exact))
         (part (floor (* 8 (- exact full))))
         (filled (concat (make-string full (if unicode ?█ ?#))
                         (if (and unicode (> part 0))
                             (aref ham-rig--partial-blocks part)
                           "")))
         (used (+ full (if (and unicode (> part 0)) 1 0))))
    (concat (propertize filled 'face 'ham-rig-meter)
            (propertize (make-string (max 0 (- width used)) (if unicode ?░ ?.))
                        'face 'ham-rig-label))))

(defun ham-rig--s-label (db)
  "Return an S-meter label for DB relative to S9."
  (cond
   ((null db) "--")
   ((< db 3) (format "S%d" (max 0 (+ 9 (floor db 6)))))
   (t (format "S9+%d" (* 10 (round db 10))))))

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
     (propertize (format "%s:%d" ham-rig-host ham-rig-port) 'face 'ham-rig-label)
     "   "
     (propertize (symbol-name state)
                 'face (if (eq state 'connected) 'ham-rig-rx 'ham-rig-label))
     (if model (concat "   " (propertize model 'face 'ham-rig-label)) "")
     "\n\n  "
     (propertize (if freq (ham-format-frequency freq) "---.---.---")
                 'face 'ham-rig-frequency)
     "   " (propertize (or band "") 'face 'ham-rig-label)
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
                 "  "
                 (ham-rig--bar (/ (or (ham-rig-get 'alc) 0) 100.0)
                               ham-rig-smeter-width)
                 (propertize "  ALC " 'face 'ham-rig-label)
                 (format "%-5s" (or (ham-rig-get 'alc) "--"))
                 (propertize " SWR " 'face 'ham-rig-label)
                 (format "%s" (if-let ((s (ham-rig-get 'swr)))
                                  (format "%.1f" s) "--"))
                 (if ham-rig--tx-started-at
                     (propertize (format "   %ds"
                                         (round (- (float-time)
                                                   ham-rig--tx-started-at)))
                                 'face 'ham-rig-tx)
                   ""))
       (concat (propertize "RX" 'face 'ham-rig-rx)
               "  "
               (ham-rig--bar (and db (/ (+ db 54.0) 114.0)) ham-rig-smeter-width)
               "  "
               (format "%-6s" (ham-rig--s-label db))))
     "\n\n  "
     (propertize "f freq  m mode  b band  v vfo  s split  t ptt  T unkey  g refresh  ? caps"
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


;;;; Major mode

(defvar-keymap ham-rig-mode-map
  :doc "Keymap for `ham-rig-mode'."
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
  "?" #'ham-rig-show-capabilities
  "S" #'ham-rig-show-stats
  "L" #'ham-show-log)

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
