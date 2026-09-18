;;; ham-dxcluster.el --- DX cluster spots -*- lexical-binding: t; -*-

;; Copyright (C) 2026 K6SM

;; Author: K6SM
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (ham "0.5.0") (ham-spot "0.1.0"))
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

;; A DX cluster is a chat room for machines.  Connect, say who you are,
;; and it tells you every station anyone on the network has heard:
;;
;;   DX de KD0AA:     18100.0  JR1FYS       FT8 LOUD in FL!      2156Z
;;
;; That line is the whole protocol as far as this file is concerned.
;; Everything else -- the banner, the prompts, the talk between
;; operators -- is noise to be stepped over.
;;
;; Three families of cluster software answer on port 7300 or 8000 and
;; they differ in what they will accept as commands, so the banner is
;; read to find out which one this is.  A Spider wants `set/qra', an
;; AR-Cluster wants `set station grid', a CC cluster wants neither, and
;; some hosts are firehoses that take no commands at all.  Guessing
;; wrong is not harmless: a cluster sent something it does not
;; understand may reply with a page of help text, and one of them will
;; disconnect.
;;
;; ON WINDOWS.  Clusters are usually described as telnet hosts, and
;; Windows has not shipped a telnet client enabled by default since XP.
;; None is needed.  Telnet to a cluster is a bare TCP socket carrying
;; lines of text with no telnet option negotiation in practice, and
;; `make-network-process' opens one on every platform Emacs runs on.
;; Nothing here shells out to anything.
;;
;; The protocol details -- how to tell the cluster types apart, what to
;; ask each for a backlog, that the login prompt arrives with no
;; newline after it -- were confirmed against HamClock's dxcluster.cpp,
;; which has had a great many more hours on real clusters than this
;; has.

;;; Code:

(require 'ham)
(require 'ham-spot)
(require 'cl-lib)
(require 'subr-x)

(defgroup ham-dxcluster nil
  "DX cluster spots."
  :group 'ham-spot
  :prefix "ham-dxcluster-")

(defcustom ham-dxcluster-host "dxc.nc7j.com"
  "Host name of the DX cluster to connect to."
  :type 'string
  :group 'ham-dxcluster)

(defcustom ham-dxcluster-port 7373
  "Port the cluster listens on.
7300 and 8000 are the other common ones."
  :type 'integer
  :group 'ham-dxcluster)

(defcustom ham-dxcluster-call nil
  "Callsign to log in with, or nil to refuse to connect.

A cluster is a shared resource that logs who is on it, and connecting
to one without saying who you are is not done.  There is deliberately
no default."
  :type '(choice (const :tag "Not set" nil) string)
  :group 'ham-dxcluster)

(defcustom ham-dxcluster-commands nil
  "Commands to send once logged in, as a list of strings.

Filters go here.  A cluster with no filter sends every spot on every
band from everywhere, which on a busy evening is more than anyone can
read.  What the commands look like depends on the cluster:

  Spider     set/filter dxcc/reject k         not the United States
             set/filter band/pass 20,40       only 20 and 40 metres
  AR         set dx filter not skimmer        people, not machines
  CC         set/nobeacon

Sent in order, a second apart, after the grid is set."
  :type '(repeat string)
  :group 'ham-dxcluster)

(defcustom ham-dxcluster-send-grid t
  "Whether to tell the cluster your locator on connecting.

A Spider asks for it if it does not have one, and some clusters use it
to work out which spots are near you.  Taken from `ham-station-grid'."
  :type 'boolean
  :group 'ham-dxcluster)

(defcustom ham-dxcluster-request-backlog t
  "Whether to ask for recent spots on connecting.

Without this the panel is empty until somebody spots something, which
on a quiet band can be a long wait with nothing to say whether the
connection is working."
  :type 'boolean
  :group 'ham-dxcluster)

(defcustom ham-dxcluster-backlog-count 30
  "How many recent spots to ask for."
  :type 'integer
  :group 'ham-dxcluster)

(defcustom ham-dxcluster-heartbeat 60
  "Seconds of quiet before sending a blank line to the cluster.

Nothing needs it at the protocol level.  It is there because a link
that carries no traffic for several minutes is a link some router in
the middle will quietly drop, and the first anyone knows of it is spots
that stopped arriving."
  :type 'integer
  :group 'ham-dxcluster)

(defcustom ham-dxcluster-command-delay 1.0
  "Seconds between commands sent to the cluster.

Sending a burst of commands at a cluster the moment it finishes its
banner is a good way to have some of them swallowed, and looks enough
like an attack that a few hosts will drop the connection."
  :type 'number
  :group 'ham-dxcluster)

(defcustom ham-dxcluster-clock-tolerance 600
  "Seconds a spot may be ahead of this machine before it is yesterday's.

A cluster spot carries a time but no date, so one timed after now is
either from just before midnight UTC or from a node whose clock
disagrees with ours.  Anything further ahead than this is read as
yesterday's; anything nearer is read as now."
  :type 'integer
  :group 'ham-dxcluster)

(defcustom ham-dxcluster-log-lines 200
  "Lines of cluster conversation to keep for `ham-dxcluster-show-log'."
  :type 'integer
  :group 'ham-dxcluster)


;;;; State

(defvar ham-dxcluster--connection nil
  "The `ham-connection' to the cluster, or nil.")

(defvar ham-dxcluster--type nil
  "Which cluster software answered: `spider', `ar', `cc', `read-only' or nil.")

(defvar ham-dxcluster--logged-in nil
  "Non-nil once the callsign has been sent.")

(defvar ham-dxcluster--ready nil
  "Non-nil once the banner is done and commands may be sent.")

(defvar ham-dxcluster--queue nil
  "Commands still to send, oldest first.")

(defvar ham-dxcluster--queue-timer nil)

(defvar ham-dxcluster--heartbeat-timer nil)

(defvar ham-dxcluster--last-activity nil
  "`float-time' when the cluster last said anything.")

(defvar ham-dxcluster--log nil
  "Recent lines to and from the cluster, newest first.")

(defvar ham-dxcluster--status nil
  "A short string describing the state of the connection.")

(defvar ham-dxcluster--spots 0
  "How many spots this connection has produced.")

(defun ham-dxcluster--note (direction text)
  "Record TEXT in the log, marked with DIRECTION."
  (push (format "%s %s" direction text) ham-dxcluster--log)
  (when (> (length ham-dxcluster--log) ham-dxcluster-log-lines)
    (setq ham-dxcluster--log (seq-take ham-dxcluster--log
                                       ham-dxcluster-log-lines))))


;;;; Parsing

(defconst ham-dxcluster--spot-regexp
  (concat "^DX de +\\([A-Z0-9/#-]+\\):? +"       ; who heard it
          "\\([0-9]+\\.?[0-9]*\\) +"             ; kHz
          "\\([A-Z0-9/]+\\)"                     ; who was heard
          "\\(.*\\)$")                           ; comment and time
  "What a cluster spot looks like.

Case is folded when this is used: a few clusters send `DX De'.  The
spotter may carry a `-#' suffix, which is how a skimmer signs itself,
and both calls may carry a portable prefix or suffix with a slash.")

(defconst ham-dxcluster--time-regexp
  "\\([0-2][0-9]\\)\\([0-5][0-9]\\)Z"
  "The time a spot was made, at the end of the line.

Read by matching rather than by column.  Fixed columns are what the
format nominally guarantees and what a spot with a long comment or an
unusually long callsign quietly breaks.")

(defun ham-dxcluster--parse-time (text)
  "Return the Emacs time TEXT ends with, or nil.

The cluster sends an hour and a minute in UTC and no date, so the date
is this one -- except just after midnight UTC, when a spot made a
minute ago carries yesterday's hour and would otherwise look like one
made almost a whole day in the future.

A spot that is only slightly ahead is a difference of opinion about
what time it is, not a spot from yesterday.  Cluster nodes are not all
synchronised, spots pass through more than one of them, and the minute
is truncated rather than rounded, so a fresh spot can easily carry a
time a little after ours.  Backdating those by a day would age them out
of the panel instantly -- the newest spots being the ones to vanish."
  (when (string-match ham-dxcluster--time-regexp text)
    (let* ((hour (string-to-number (match-string 1 text)))
           (minute (string-to-number (match-string 2 text)))
           (now (current-time))
           (today (decode-time now t))
           (guess (encode-time 0 minute hour
                               (decoded-time-day today)
                               (decoded-time-month today)
                               (decoded-time-year today)
                               t)))
      (when (and (<= hour 23) (<= minute 59))
        (let ((ahead (float-time (time-subtract guess now))))
          (cond
           ((> ahead ham-dxcluster-clock-tolerance)
            (time-subtract guess (days-to-time 1)))
           ((> ahead 0) now)
           (t guess)))))))

(defun ham-dxcluster--parse-comment (text)
  "Return the comment part of TEXT, without the trailing time or grid."
  (string-trim
   (replace-regexp-in-string
    "[ \t]*[0-9]\\{4\\}Z\\([ \t]+[A-R][A-R][0-9][0-9]\\)?[ \t]*$" "" text)))

(defun ham-dxcluster--parse-grid (text)
  "Return the spotter's grid from TEXT, or nil.
Some clusters append it after the time and some do not."
  (when (string-match "[0-9]\\{4\\}Z[ \t]+\\([A-R][A-R][0-9][0-9]\\)[ \t]*$" text)
    (match-string 1 text)))

(defun ham-dxcluster-parse-spot (line)
  "Return the `ham-spot' LINE reports, or nil if it is not a spot.

Most of what a cluster sends is not a spot: a banner, a prompt, a
message between two operators, an announcement that somebody has gone
to bed.  Anything that does not parse is simply not a spot, and saying
so is the whole of the error handling."
  (let ((case-fold-search t))
    (when (string-match ham-dxcluster--spot-regexp line)
      (let* ((spotter (upcase (match-string 1 line)))
             (khz (string-to-number (match-string 2 line)))
             (call (upcase (match-string 3 line)))
             (rest (match-string 4 line))
             (hz (round (* khz 1000)))
             (when-time (ham-dxcluster--parse-time rest)))
        (when (and (> khz 0) (ham-band-for-frequency hz))
          (ham-spot-fill-mode
           (ham-spot-create
            :call call
            :spotter spotter
            :hz hz
            ;; A comment naming a mode is worth more than the band plan
            ;; guessing one, since this is a person saying what they
            ;; actually heard.
            :mode (ham-dxcluster--mode-in-comment rest)
            :when (or when-time (current-time))
            :source 'dxcluster
            :spotter-grid (ham-dxcluster--parse-grid rest)
            :comment (ham-dxcluster--parse-comment rest))))))))

(defconst ham-dxcluster--comment-modes
  '("FT8" "FT4" "JS8" "JT65" "JT9" "CW" "SSB" "USB" "LSB" "RTTY" "PSK31"
    "PSK" "AM" "FM" "SSTV" "MFSK" "OLIVIA" "CONTESTIA" "Q65" "WSPR")
  "Modes a spotter might name in a comment, longest-matching first.")

(defun ham-dxcluster--mode-in-comment (comment)
  "Return the mode named in COMMENT, or nil.

Matched on word boundaries so that a comment reading \"CQ NA\" does not
become AM, and \"FT8\" in \"FT8 -12 dB\" does."
  (let ((case-fold-search t))
    (seq-find (lambda (mode)
                (string-match-p (concat "\\_<" (regexp-quote mode) "\\_>")
                                comment))
              ham-dxcluster--comment-modes)))


;;;; Talking to the cluster

(defun ham-dxcluster--send (text)
  "Send TEXT to the cluster now."
  (when (ham-connection-live-p ham-dxcluster--connection)
    (ham-dxcluster--note ">" text)
    (setq ham-dxcluster--last-activity (float-time))
    (ham-connection-send ham-dxcluster--connection text)))

(defun ham-dxcluster--enqueue (&rest commands)
  "Queue COMMANDS to be sent one at a time."
  (setq ham-dxcluster--queue (append ham-dxcluster--queue
                                     (delq nil commands)))
  (ham-dxcluster--drain))

(defun ham-dxcluster--drain ()
  "Send the next queued command, then arm a timer for the one after it."
  (when ham-dxcluster--queue-timer
    (cancel-timer ham-dxcluster--queue-timer)
    (setq ham-dxcluster--queue-timer nil))
  (when (and ham-dxcluster--queue
             (ham-connection-live-p ham-dxcluster--connection))
    (ham-dxcluster--send (pop ham-dxcluster--queue))
    (when ham-dxcluster--queue
      (setq ham-dxcluster--queue-timer
            (run-at-time ham-dxcluster-command-delay nil
                         #'ham-dxcluster--drain)))))

(defun ham-dxcluster--grid-command ()
  "Return the command telling this cluster our locator, or nil."
  (when (and ham-dxcluster-send-grid ham-station-grid)
    (pcase ham-dxcluster--type
      ((or 'spider 'cc) (format "set/qra %s" ham-station-grid))
      ('ar (format "set station grid %s" ham-station-grid))
      (_ nil))))

(defun ham-dxcluster--backlog-command ()
  "Return the command asking this cluster for recent spots, or nil."
  (when ham-dxcluster-request-backlog
    (pcase ham-dxcluster--type
      ('spider (format "sh/dx real %d" ham-dxcluster-backlog-count))
      ('ar (format "show/dx/%d" ham-dxcluster-backlog-count))
      ;; A CC cluster's show/fdx takes no count: it sends what it sends.
      ('cc "show/fdx")
      (_ nil))))

(defun ham-dxcluster--on-ready ()
  "Send everything that waits for the banner to finish."
  (unless ham-dxcluster--ready
    (setq ham-dxcluster--ready t)
    (setq ham-dxcluster--status
          (format "%s, %s" ham-dxcluster-host
                  (ham-dxcluster--type-name)))
    (unless (eq ham-dxcluster--type 'read-only)
      (apply #'ham-dxcluster--enqueue
             (append (list (ham-dxcluster--grid-command))
                     ham-dxcluster-commands
                     (list (ham-dxcluster--backlog-command)))))))

(defun ham-dxcluster--type-name ()
  "Return what to call the cluster software that answered."
  (pcase ham-dxcluster--type
    ('spider "DXSpider")
    ('ar "AR-Cluster")
    ('cc "CC Cluster")
    ('read-only "read-only")
    (_ "unknown")))

(defun ham-dxcluster--detect-type (line)
  "Note which cluster software LINE suggests is answering.

The banner names it, in among a good deal else.  Nothing depends on
getting this right except which commands are worth sending, so an
unrecognised cluster is treated as one that takes no commands rather
than as a failure."
  (let ((text (downcase line)))
    (cond
     (ham-dxcluster--type nil)
     ((string-match-p "please enter your location" text)
      (setq ham-dxcluster--type 'spider))
     ((and (string-match-p "dx" text) (string-match-p "spider" text))
      (setq ham-dxcluster--type 'spider))
     ((string-match-p "ar-cluster" text)
      (setq ham-dxcluster--type 'ar))
     ((string-match-p "\\bcc\\b" text)
      (setq ham-dxcluster--type 'cc)))))

(defun ham-dxcluster--login-prompt-p (text)
  "Return non-nil if TEXT is a cluster asking who we are."
  (let ((case-fold-search t))
    (string-match-p "\\(login\\|call\\(sign\\)?\\|your call\\)[ \t]*:?[ \t]*\\'"
                    (string-trim-right text))))

(defun ham-dxcluster--prompt-p (text)
  "Return non-nil if TEXT is the cluster waiting for input."
  (string-match-p "[>$#][ \t]*\\'" (string-trim-right text)))


;;;; Reading

(defun ham-dxcluster--on-line (line)
  "Handle one complete LINE from the cluster."
  (setq ham-dxcluster--last-activity (float-time))
  (ham-dxcluster--note "<" line)
  (ham-dxcluster--detect-type line)
  (let ((spot (ham-dxcluster-parse-spot line)))
    (cond
     (spot
      (cl-incf ham-dxcluster--spots)
      ;; A spot means the banner is long over, whatever the banner
      ;; looked like: a cluster sending data is a cluster that is up.
      (ham-dxcluster--on-ready)
      (ham-spot-record spot))
     ;; A Spider that has no locator for us asks for one in the middle
     ;; of the session, not only at login.
     ((string-match-p "please enter your location" (downcase line))
      (when-let ((command (ham-dxcluster--grid-command)))
        (ham-dxcluster--enqueue command)))
     ((ham-dxcluster--login-prompt-p line)
      (ham-dxcluster--send-login))
     ((ham-dxcluster--prompt-p line)
      (ham-dxcluster--on-ready)))))

(defun ham-dxcluster--on-partial (text)
  "Handle TEXT the cluster has sent without a newline after it.

This is the login prompt.  A cluster asks for a callsign and then waits
for one, with the question still sitting unterminated in the buffer, so
a reader that only ever sees whole lines waits for a newline that the
cluster is waiting for us to cause."
  (when (and (not ham-dxcluster--logged-in)
             (ham-dxcluster--login-prompt-p text))
    (ham-connection-consume-partial ham-dxcluster--connection)
    (ham-dxcluster--note "<" (string-trim text))
    (ham-dxcluster--send-login)))

(defun ham-dxcluster--send-login ()
  "Send the callsign, once."
  (unless ham-dxcluster--logged-in
    (setq ham-dxcluster--logged-in t)
    (setq ham-dxcluster--status (format "%s, logging in" ham-dxcluster-host))
    (ham-dxcluster--send ham-dxcluster-call)))

(defun ham-dxcluster--on-status (state detail)
  "Note the connection moving to STATE, with DETAIL."
  (setq ham-dxcluster--status
        (pcase state
          ('connected (format "%s, connected" ham-dxcluster-host))
          ('connecting (format "%s, connecting" ham-dxcluster-host))
          ('reconnecting (format "%s, reconnecting%s" ham-dxcluster-host
                                 (if detail (format " (%s)" detail) "")))
          (_ (format "%s, %s" ham-dxcluster-host (or detail state)))))
  (pcase state
    ('connected
     ;; Each connection is a fresh conversation: a cluster that dropped
     ;; us has forgotten we logged in, and so must we, or the prompt it
     ;; sends next time goes unanswered.
     (setq ham-dxcluster--logged-in nil
           ham-dxcluster--ready nil
           ham-dxcluster--type nil
           ham-dxcluster--queue nil)
     (ham-dxcluster--start-heartbeat))
    ((or 'disconnected 'reconnecting)
     (setq ham-dxcluster--ready nil)))
  (ham-spot--schedule-redisplay))

(defun ham-dxcluster--start-heartbeat ()
  "Arrange to keep the link warm while it is quiet."
  (ham-dxcluster--stop-heartbeat)
  (when (> ham-dxcluster-heartbeat 0)
    (setq ham-dxcluster--heartbeat-timer
          (run-at-time ham-dxcluster-heartbeat ham-dxcluster-heartbeat
                       #'ham-dxcluster--heartbeat))))

(defun ham-dxcluster--stop-heartbeat ()
  "Stop the keepalive timer."
  (when ham-dxcluster--heartbeat-timer
    (cancel-timer ham-dxcluster--heartbeat-timer)
    (setq ham-dxcluster--heartbeat-timer nil)))

(defun ham-dxcluster--heartbeat ()
  "Send a blank line if the cluster has been quiet."
  (when (and (ham-connection-live-p ham-dxcluster--connection)
             (or (null ham-dxcluster--last-activity)
                 (> (- (float-time) ham-dxcluster--last-activity)
                    ham-dxcluster-heartbeat)))
    (ham-dxcluster--send "")))


;;;; Connecting

;;;###autoload
(defun ham-dxcluster-connect ()
  "Connect to the DX cluster."
  (interactive)
  (unless (and ham-dxcluster-call (not (string-empty-p ham-dxcluster-call)))
    (user-error "Set `ham-dxcluster-call' to your callsign first"))
  (ham-dxcluster-disconnect)
  (setq ham-dxcluster--spots 0
        ham-dxcluster--log nil
        ham-dxcluster--status (format "%s, connecting" ham-dxcluster-host))
  (setq ham-dxcluster--connection
        (ham-connection-make :name "ham-dxcluster"
                             :host ham-dxcluster-host
                             :port ham-dxcluster-port
                             :on-line #'ham-dxcluster--on-line
                             :on-partial #'ham-dxcluster--on-partial
                             :on-status #'ham-dxcluster--on-status))
  (ham-connection-open ham-dxcluster--connection)
  (message "ham-dxcluster: connecting to %s:%d as %s"
           ham-dxcluster-host ham-dxcluster-port ham-dxcluster-call))

(defun ham-dxcluster-disconnect ()
  "Disconnect from the DX cluster."
  (interactive)
  (ham-dxcluster--stop-heartbeat)
  (when ham-dxcluster--queue-timer
    (cancel-timer ham-dxcluster--queue-timer)
    (setq ham-dxcluster--queue-timer nil))
  (when ham-dxcluster--connection
    (ham-connection-close ham-dxcluster--connection))
  (setq ham-dxcluster--connection nil
        ham-dxcluster--queue nil
        ham-dxcluster--logged-in nil
        ham-dxcluster--ready nil
        ham-dxcluster--type nil
        ham-dxcluster--status nil))

(defun ham-dxcluster-connected-p ()
  "Return non-nil if the cluster link is up."
  (ham-connection-live-p ham-dxcluster--connection))

(defun ham-dxcluster-send-command (command)
  "Send COMMAND to the cluster.

For the things a cluster can do that this package does not: announcing
yourself, spotting somebody, asking after a callsign.  The reply
appears in `ham-dxcluster-show-log'."
  (interactive (list (read-string "Cluster command: ")))
  (unless (ham-dxcluster-connected-p)
    (user-error "Not connected to a cluster"))
  (ham-dxcluster--send command))

(defun ham-dxcluster-spot (call khz comment)
  "Tell the cluster that CALL is on KHZ, with COMMENT.

The one thing here that transmits, in the sense that everyone on the
network sees it.  It is not undoable and it is not anonymous, so it
asks first."
  (interactive
   (let* ((spot (and (derived-mode-p 'ham-spots-mode) (ham-spot-at-point)))
          (call (read-string "Spot callsign: " (and spot (ham-spot-call spot))))
          (khz (read-string "Frequency in kHz: "
                            (if spot (format "%.1f" (ham-spot-khz spot))
                              (and (ham-rig-frequency)
                                   (format "%.1f" (/ (ham-rig-frequency) 1000.0)))))))
     (list call (string-to-number khz) (read-string "Comment: "))))
  (unless (ham-dxcluster-connected-p)
    (user-error "Not connected to a cluster"))
  (when (yes-or-no-p (format "Spot %s on %.1f kHz to the whole network? "
                             (upcase call) khz))
    (ham-dxcluster--send (format "dx %.1f %s %s" khz (upcase call) comment))))

(defun ham-dxcluster-status ()
  "Return a short description of the cluster connection."
  (cond
   ((null ham-dxcluster--connection) nil)
   ((ham-dxcluster-connected-p)
    (format "cluster: %s  %d spots" (or ham-dxcluster--status "up")
            ham-dxcluster--spots))
   (t (format "cluster: %s" (or ham-dxcluster--status "down")))))

(defun ham-dxcluster-show-log ()
  "Show the recent conversation with the cluster.

Everything sent and received, newest first.  This is where to look when
the panel is empty: a cluster that is refusing a login, or objecting to
a filter command, says so in plain English and then carries on as if
nothing happened."
  (interactive)
  (ham-with-help-buffer "*ham-dxcluster-log*"
      (format "DX cluster %s:%d" ham-dxcluster-host ham-dxcluster-port)
    (insert ham-panel-indent
            (propertize (format "%-12s" "State") 'face 'ham-face-label)
            (or ham-dxcluster--status "not connected") "\n")
    (insert ham-panel-indent
            (propertize (format "%-12s" "Software") 'face 'ham-face-label)
            (ham-dxcluster--type-name) "\n")
    (insert ham-panel-indent
            (propertize (format "%-12s" "Spots") 'face 'ham-face-label)
            (number-to-string ham-dxcluster--spots) "\n\n")
    (insert (propertize "Conversation, newest first\n" 'face 'ham-face-heading))
    (if (null ham-dxcluster--log)
        (insert ham-panel-indent (ham-note-line "Nothing yet.") "\n")
      (dolist (line ham-dxcluster--log)
        (insert ham-panel-indent
                (if (string-prefix-p ">" line)
                    (propertize line 'face 'ham-face-label)
                  (ham-note-line line))
                "\n")))))

;;;###autoload
(defun ham-dxcluster ()
  "Open the spot panel showing DX cluster spots."
  (interactive)
  (ham-spots 'dxcluster))

(ham-spot-register-feed
 (ham-spot-feed-create
  :name 'dxcluster
  :title "DX cluster"
  :start (lambda ()
           (when (and ham-dxcluster-call
                      (not (ham-dxcluster-connected-p)))
             (ham-dxcluster-connect)))
  :stop #'ham-dxcluster-disconnect
  :live-p #'ham-dxcluster-connected-p
  :status #'ham-dxcluster-status
  ;; Nothing to poll: a cluster pushes.  Refreshing asks for the
  ;; backlog again, which is the nearest thing to "say that again".
  :refresh (lambda ()
             (when (and (ham-dxcluster-connected-p)
                        (not (eq ham-dxcluster--type 'read-only)))
               (when-let ((command (ham-dxcluster--backlog-command)))
                 (ham-dxcluster--enqueue command))))))

(provide 'ham-dxcluster)
;;; ham-dxcluster.el ends here
