;;; ham-remote.el --- Audio transport for remote operation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 K6SM

;; Author: K6SM
;; Version: 0.1.1
;; Package-Requires: ((emacs "29.1") (ham "0.1.0") (ham-rig "0.1.3"))
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

;; Operate a station over a network: `ham-rig' already reaches a
;; `rigctld' on any host, and this carries the audio alongside it.
;;
;; No audio passes through Emacs.  A pause for garbage collection is
;; nothing to a frequency readout and ruinous to a transmit buffer, so
;; the audio runs in external programs and this package starts them,
;; watches them, sequences them against PTT, and reports what they are
;; doing.
;;
;; Two streams run at once, in opposite directions:
;;
;;   receive    radio end -> operator, so you hear the band
;;   transmit   operator -> radio end, so the radio hears you
;;
;; Which program carries them is a back end, chosen by name.  `trx'
;; sends Opus and is the default; `zita-njbridge' sends uncompressed
;; samples.  That distinction is not cosmetic: a digital voice mode
;; puts a modulated waveform on the link rather than speech, and a
;; codec that models the human voice will destroy it.  A back end
;; declares whether it is lossless, and `ham-remote-require-lossless'
;; refuses to start a lossy one when the waveform needs to survive.
;;
;; The radio end runs its own half under systemd, started at boot and
;; independent of whether Emacs is running.  `ham-remote-show-radio-end'
;; prints what to put there for the current configuration.
;;
;; What this does not yet do: watch the link from the radio's side.  If
;; the network fails mid-transmission, nothing at the operator's end can
;; unkey the transmitter -- the same gap CAT has, made likelier by a
;; longer link.  Until a radio-end watchdog exists, remote operation
;; rests on the transceiver's own transmit timeout.  Enable it.

;;; Code:

(require 'ham)
(require 'ham-rig)
(require 'cl-lib)
(require 'subr-x)

(defgroup ham-remote nil
  "Audio transport for operating a station remotely."
  :group 'ham
  :prefix "ham-remote-")


;;;; Options

(defcustom ham-remote-host "radio.local"
  "Host at the radio end, carrying the audio and `rigctld'."
  :type 'string
  :group 'ham-remote)

(defcustom ham-remote-receive-port 5010
  "UDP port carrying audio from the radio to the operator."
  :type 'integer
  :group 'ham-remote)

(defcustom ham-remote-transmit-port 5011
  "UDP port carrying audio from the operator to the radio."
  :type 'integer
  :group 'ham-remote)

(defcustom ham-remote-playback-device "default"
  "ALSA device the operator listens on."
  :type 'string
  :group 'ham-remote)

(defcustom ham-remote-capture-device "default"
  "ALSA device the operator speaks into."
  :type 'string
  :group 'ham-remote)

(defcustom ham-remote-radio-playback-device "default"
  "ALSA device at the radio end feeding the transmitter.
For a transceiver with a USB audio interface this is that interface."
  :type 'string
  :group 'ham-remote)

(defcustom ham-remote-radio-capture-device "default"
  "ALSA device at the radio end taking receiver audio."
  :type 'string
  :group 'ham-remote)

(defcustom ham-remote-sample-rate 48000
  "Sample rate in Hz, which must match at both ends."
  :type 'integer
  :group 'ham-remote)

(defcustom ham-remote-channels 1
  "Channel count.  One is right for a single receiver."
  :type 'integer
  :group 'ham-remote)

(defcustom ham-remote-transport "trx"
  "Name of the audio transport back end.
See `ham-remote-transport-names' for what is registered."
  :type 'string
  :group 'ham-remote)

(defcustom ham-remote-require-lossless nil
  "When non-nil, refuse to start a back end that compresses the audio.

Set this for a digital voice mode.  What travels then is a modulated
waveform rather than speech, and a codec built to model the human voice
will wreck it."
  :type 'boolean
  :group 'ham-remote)

(defcustom ham-remote-settle-delay 0.2
  "Seconds between keying the transmitter and its audio being worth sending.

A transceiver takes time to switch from receive to transmit, and
anything sent during that time is lost.  It matters for audio a program
generates -- a voice keyer, a digital mode -- rather than for speech,
where the operator naturally pauses."
  :type 'number
  :group 'ham-remote)

(defcustom ham-remote-restart-delay 2.0
  "Seconds before restarting an audio stream that stopped unexpectedly."
  :type 'number
  :group 'ham-remote)

(defcustom ham-remote-restart-max-delay 30.0
  "Longest delay between restart attempts, in seconds."
  :type 'number
  :group 'ham-remote)

(defcustom ham-remote-buffer-name "*ham-remote*"
  "Name of the buffer showing the state of the audio link."
  :type 'string
  :group 'ham-remote)


;;;; Transport back ends

;; A back end is a description of how to run two programs, one per
;; direction, at either end of the link.  Commands are lists of strings
;; carrying placeholders, so a back end whose options differ from the
;; version packaged here can be corrected without touching any code:
;;
;;   %h  host          %p  port           %d  audio device
;;   %r  sample rate   %c  channel count
;;
;; A literal percent sign is %%.

(cl-defstruct (ham-remote-transport (:constructor ham-remote-transport-create)
                                    (:copier nil))
  "One way of carrying audio between the two ends of a link."
  name lossless receive transmit radio-receive radio-transmit summary)

(defvar ham-remote--transports (make-hash-table :test #'equal)
  "Registered transports, keyed by name.")

(defun ham-remote-register-transport (transport)
  "Register TRANSPORT, replacing any of the same name."
  (puthash (ham-remote-transport-name transport) transport
           ham-remote--transports)
  (ham-remote-transport-name transport))

(defun ham-remote-transport-named (name)
  "Return the transport called NAME, or nil."
  (gethash name ham-remote--transports))

(defun ham-remote-transport-names ()
  "Return the names of every registered transport."
  (sort (hash-table-keys ham-remote--transports) #'string-lessp))

(defun ham-remote--expand (command &rest properties)
  "Return COMMAND with its placeholders replaced from PROPERTIES.
PROPERTIES is a plist of :host, :port, :device, :rate and :channels."
  (mapcar
   (lambda (argument)
     (replace-regexp-in-string
      "%[hpdrc%]"
      (lambda (token)
        (pcase token
          ("%h" (format "%s" (plist-get properties :host)))
          ("%p" (format "%s" (plist-get properties :port)))
          ("%d" (format "%s" (plist-get properties :device)))
          ("%r" (format "%s" (plist-get properties :rate)))
          ("%c" (format "%s" (plist-get properties :channels)))
          ("%%" "%")
          (_ token)))
      argument t t))
   command))


;;;; The transports shipped here

(defcustom ham-remote-trx-receive-command
  '("rx" "-h" "0.0.0.0" "-p" "%p" "-d" "%d" "-r" "%r" "-c" "%c" "-j" "20")
  "Command receiving audio, for the `trx' back end.
The `-h' of `rx' is the address to listen on, not the far end.  `-j' is
the jitter buffer in milliseconds: raise it if the audio breaks up, at
the cost of delay."
  :type '(repeat string)
  :group 'ham-remote)

(defcustom ham-remote-trx-transmit-command
  '("tx" "-h" "%h" "-p" "%p" "-d" "%d" "-r" "%r" "-c" "%c" "-f" "480" "-b" "32")
  "Command sending audio, for the `trx' back end.
`-f' is the Opus frame size in samples, and the main latency control:
at 48000 Hz the codec permits 120, 240, 480 or 960, being 2.5, 5, 10 or
20 milliseconds.  `-b' is the bitrate in kbit/s, of which 32 is ample
for one voice channel."
  :type '(repeat string)
  :group 'ham-remote)

(defcustom ham-remote-zita-receive-command
  '("zita-n2j" "--jname" "ham-remote-rx" "--chan" "%c" "0.0.0.0" "%p")
  "Command receiving audio, for the `zita-njbridge' back end.

Unverified: these options are written from the documentation rather
than from a running copy, and zita-njbridge needs JACK at both ends.
Correct them here if they do not match your build."
  :type '(repeat string)
  :group 'ham-remote)

(defcustom ham-remote-zita-transmit-command
  '("zita-j2n" "--jname" "ham-remote-tx" "--chan" "%c" "%h" "%p")
  "Command sending audio, for the `zita-njbridge' back end.
Unverified; see `ham-remote-zita-receive-command'."
  :type '(repeat string)
  :group 'ham-remote)

(defun ham-remote--register-builtin-transports ()
  "Register the transports that ship with this package."
  (ham-remote-register-transport
   (ham-remote-transport-create
    :name "trx"
    :lossless nil
    :summary "Opus over RTP; low bandwidth, not fit for digital voice"
    :receive (lambda () ham-remote-trx-receive-command)
    :transmit (lambda () ham-remote-trx-transmit-command)
    :radio-receive (lambda () ham-remote-trx-receive-command)
    :radio-transmit (lambda () ham-remote-trx-transmit-command)))
  (ham-remote-register-transport
   (ham-remote-transport-create
    :name "zita-njbridge"
    :lossless t
    :summary "Uncompressed over UDP; needs JACK, carries any waveform"
    :receive (lambda () ham-remote-zita-receive-command)
    :transmit (lambda () ham-remote-zita-transmit-command)
    :radio-receive (lambda () ham-remote-zita-receive-command)
    :radio-transmit (lambda () ham-remote-zita-transmit-command))))

(ham-remote--register-builtin-transports)


;;;; Streams

(cl-defstruct (ham-remote--stream (:constructor ham-remote--stream-create)
                                  (:copier nil))
  "One direction of audio, and the process carrying it."
  direction process started-at restarts restart-timer backoff)

(defvar ham-remote--streams nil
  "Alist of direction symbol to `ham-remote--stream'.")

(defvar ham-remote--running nil
  "Non-nil once the operator asked for the link to be up.")

(defun ham-remote--stream (direction)
  "Return the stream for DIRECTION, creating it if need be."
  (or (alist-get direction ham-remote--streams)
      (let ((stream (ham-remote--stream-create :direction direction
                                               :restarts 0)))
        (setf (alist-get direction ham-remote--streams) stream)
        stream)))

(defun ham-remote--current-transport ()
  "Return the configured transport, or signal if it is unknown."
  (or (ham-remote-transport-named ham-remote-transport)
      (user-error "No such audio transport: %s.  Known: %s"
                  ham-remote-transport
                  (string-join (ham-remote-transport-names) ", "))))

(defun ham-remote--check-lossless (transport)
  "Signal if TRANSPORT compresses audio where that is not allowed."
  (when (and ham-remote-require-lossless
             (not (ham-remote-transport-lossless transport)))
    (user-error
     "%s compresses the audio, and `ham-remote-require-lossless' is set.\
  A modulated waveform will not survive it; choose %s"
     (ham-remote-transport-name transport)
     (or (string-join
          (cl-remove-if-not
           (lambda (name)
             (ham-remote-transport-lossless (ham-remote-transport-named name)))
           (ham-remote-transport-names))
          ", ")
         "a lossless transport"))))

(defun ham-remote--command (direction)
  "Return the operator-end command for DIRECTION."
  (let* ((transport (ham-remote--current-transport))
         (template (funcall (if (eq direction 'receive)
                                (ham-remote-transport-receive transport)
                              (ham-remote-transport-transmit transport)))))
    (ham-remote--expand
     template
     :host ham-remote-host
     :port (if (eq direction 'receive)
               ham-remote-receive-port
             ham-remote-transmit-port)
     :device (if (eq direction 'receive)
                 ham-remote-playback-device
               ham-remote-capture-device)
     :rate ham-remote-sample-rate
     :channels ham-remote-channels)))

(defun ham-remote--stream-live-p (stream)
  "Return non-nil if STREAM has a running process."
  (and stream
       (ham-remote--stream-process stream)
       (process-live-p (ham-remote--stream-process stream))))

(defun ham-remote--start-stream (direction)
  "Start the audio process for DIRECTION."
  (let ((stream (ham-remote--stream direction)))
    (unless (ham-remote--stream-live-p stream)
      (let* ((command (ham-remote--command direction))
             (program (car command)))
        (unless (executable-find program)
          (user-error "Cannot find %s.  Install the transport, or correct its command"
                      program))
        (setf (ham-remote--stream-process stream)
              (make-process
               :name (format "ham-remote-%s" direction)
               :command command
               :noquery t
               :connection-type 'pipe
               ;; No buffer: the process talks to the sound card, and
               ;; what it prints is chatter that would otherwise
               ;; accumulate in a buffer for the length of the session.
               :filter #'ignore
               :sentinel (lambda (process event)
                           (ham-remote--stream-sentinel direction process event))))
        (setf (ham-remote--stream-started-at stream) (float-time))
        (ham-remote--schedule-redisplay)))
    stream))

(defun ham-remote--stream-sentinel (direction process _event)
  "Handle a state change of PROCESS carrying DIRECTION."
  (let ((stream (ham-remote--stream direction)))
    (when (and (eq process (ham-remote--stream-process stream))
               (not (process-live-p process)))
      (setf (ham-remote--stream-process stream) nil)
      (ham-remote--schedule-redisplay)
      ;; Only restart what the operator still wants running.
      (when ham-remote--running
        (ham-remote--schedule-restart direction)))))

(defun ham-remote--schedule-restart (direction)
  "Arrange to restart DIRECTION after a growing delay."
  (let* ((stream (ham-remote--stream direction))
         (delay (or (ham-remote--stream-backoff stream)
                    ham-remote-restart-delay)))
    (unless (ham-remote--stream-restart-timer stream)
      (setf (ham-remote--stream-backoff stream)
            (min ham-remote-restart-max-delay (* 2 delay)))
      (setf (ham-remote--stream-restart-timer stream)
            (run-at-time
             delay nil
             (lambda ()
               (setf (ham-remote--stream-restart-timer stream) nil)
               (when (and ham-remote--running
                          (not (ham-remote--stream-live-p stream)))
                 (cl-incf (ham-remote--stream-restarts stream))
                 (with-demoted-errors "ham-remote: restart failed: %S"
                   (ham-remote--start-stream direction)))))))))

(defun ham-remote--stop-stream (direction)
  "Stop the audio process for DIRECTION."
  (let ((stream (ham-remote--stream direction)))
    (when (ham-remote--stream-restart-timer stream)
      (cancel-timer (ham-remote--stream-restart-timer stream))
      (setf (ham-remote--stream-restart-timer stream) nil))
    (let ((process (ham-remote--stream-process stream)))
      (setf (ham-remote--stream-process stream) nil)
      (when (process-live-p process)
        (ignore-errors (delete-process process))))
    (setf (ham-remote--stream-started-at stream) nil
          (ham-remote--stream-backoff stream) nil)))


;;;; Starting and stopping

;;;###autoload
(defun ham-remote-start ()
  "Start carrying audio to and from the radio."
  (interactive)
  (let ((transport (ham-remote--current-transport)))
    (ham-remote--check-lossless transport)
    (setq ham-remote--running t)
    (ham-remote--start-stream 'receive)
    (ham-remote--start-stream 'transmit)
    (message "ham-remote: %s to %s" (ham-remote-transport-name transport)
             ham-remote-host)))

;;;###autoload
(defun ham-remote-stop ()
  "Stop carrying audio."
  (interactive)
  (setq ham-remote--running nil)
  (ham-remote--stop-stream 'receive)
  (ham-remote--stop-stream 'transmit)
  (ham-remote--schedule-redisplay)
  (message "ham-remote: stopped"))

(defun ham-remote-restart ()
  "Stop and start the audio streams."
  (interactive)
  (ham-remote-stop)
  (ham-remote-start))

(defun ham-remote-running-p ()
  "Return non-nil if both directions are carrying audio."
  (and ham-remote--running
       (ham-remote--stream-live-p (ham-remote--stream 'receive))
       (ham-remote--stream-live-p (ham-remote--stream 'transmit))))


;;;; Sequencing against the transmitter

(defun ham-remote-transmit-after-settle (function)
  "Key the transmitter, wait for it to switch, then call FUNCTION.

A transceiver needs time to change over, and audio sent during it is
lost.  Anything generating audio to be transmitted -- a voice keyer, a
digital mode -- should start through here rather than immediately after
keying."
  (ham-rig-toggle-ptt)
  (run-at-time ham-remote-settle-delay nil
               (lambda ()
                 (with-demoted-errors "ham-remote: transmit failed: %S"
                   (funcall function)))))

(defun ham-remote--on-ptt (_keyed)
  "React to the transmitter being keyed or not."
  (ham-remote--schedule-redisplay))

(defun ham-remote--subscribe ()
  "Follow the transmitter so the panel can show what it is doing."
  (ham-subscribe ham-rig-topic-ptt 'ham-remote #'ham-remote--on-ptt))

(ham-remote--subscribe)


;;;; The radio end

(defun ham-remote--radio-end-commands ()
  "Return the two commands to run at the radio end, as strings."
  (let ((transport (ham-remote--current-transport)))
    (list
     ;; The radio end sends what it hears to the operator.
     (string-join
      (ham-remote--expand
       (funcall (ham-remote-transport-radio-transmit transport))
       :host "OPERATOR-HOST"
       :port ham-remote-receive-port
       :device ham-remote-radio-capture-device
       :rate ham-remote-sample-rate
       :channels ham-remote-channels)
      " ")
     ;; And plays what the operator sends into the transmitter.
     (string-join
      (ham-remote--expand
       (funcall (ham-remote-transport-radio-receive transport))
       :host "0.0.0.0"
       :port ham-remote-transmit-port
       :device ham-remote-radio-playback-device
       :rate ham-remote-sample-rate
       :channels ham-remote-channels)
      " "))))

;;;###autoload
(defun ham-remote-show-radio-end ()
  "Show what to run at the radio end for the current configuration.

The radio end runs its half under systemd so that it starts at boot and
does not depend on Emacs being alive, which is the whole point of
putting the radio somewhere else."
  (interactive)
  (let ((commands (ham-remote--radio-end-commands)))
    (with-current-buffer (get-buffer-create "*ham-remote-radio-end*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Radio end setup\n\n" 'face 'bold))
        (insert "Replace OPERATOR-HOST with the address this machine has\n"
                "on the tunnel, then run both under systemd.\n\n")
        (insert (propertize "Audio to the operator\n" 'face 'bold))
        (insert "  " (nth 0 commands) "\n\n")
        (insert (propertize "Audio to the transmitter\n" 'face 'bold))
        (insert "  " (nth 1 commands) "\n\n")
        (insert (propertize "Rig control\n" 'face 'bold))
        (insert (format "  rigctld -m MODEL -r /dev/ttyUSB0 -s 38400 -T 0.0.0.0 -t %d\n\n"
                        ham-rig-port))
        (insert (propertize "Also needed\n" 'face 'bold))
        (insert "  A tunnel carrying both, since rigctld has no\n"
                "  authentication or encryption of its own. WireGuard suits\n"
                "  this better than SSH, whose forwarding is built for TCP\n"
                "  while the audio is UDP.\n\n")
        (insert "  The transceiver's own transmit timeout, enabled. Nothing\n"
                "  at this end can unkey the radio once the network is gone.\n")
        (goto-char (point-min)))
      (special-mode)
      (pop-to-buffer (current-buffer)))))


;;;; Panel

(defvar ham-remote--redisplay-timer nil)

(defun ham-remote--panel-visible-p ()
  "Return non-nil if the panel is on screen."
  (let ((buffer (get-buffer ham-remote-buffer-name)))
    (and buffer (get-buffer-window buffer t) t)))

(defun ham-remote--describe-stream (direction label)
  "Return a line describing DIRECTION under LABEL."
  (let* ((stream (ham-remote--stream direction))
         (live (ham-remote--stream-live-p stream))
         (started (ham-remote--stream-started-at stream)))
    (concat "  "
            (propertize (format "%-10s" label) 'face 'ham-rig-label)
            (propertize (if live "running" "stopped")
                        'face (if live 'ham-rig-rx 'ham-rig-label))
            (if (and live started)
                (format "   %ds" (round (- (float-time) started)))
              "")
            (let ((restarts (ham-remote--stream-restarts stream)))
              (if (> restarts 0)
                  (propertize (format "   %d restart%s" restarts
                                      (if (= restarts 1) "" "s"))
                              'face 'ham-rig-tx)
                ""))
            "\n")))

(defun ham-remote--render ()
  "Return the panel contents."
  (let ((transport (ham-remote-transport-named ham-remote-transport)))
    (concat
     "\n  "
     (propertize (or ham-remote-transport "no transport") 'face 'ham-rig-label)
     "   "
     (propertize ham-remote-host 'face 'ham-rig-label)
     (if (and transport (ham-remote-transport-lossless transport))
         (propertize "   lossless" 'face 'ham-rig-rx)
       (propertize "   compressed" 'face 'ham-rig-label))
     "\n\n"
     (ham-remote--describe-stream 'receive "RX audio")
     (ham-remote--describe-stream 'transmit "TX audio")
     "\n  "
     (propertize "PTT " 'face 'ham-rig-label)
     (if (ham-rig-ptt-p)
         (propertize "transmitting" 'face 'ham-rig-tx)
       (propertize "receiving" 'face 'ham-rig-rx))
     "\n\n  "
     (propertize "s start  S stop  r restart  R radio end  g refresh  q quit"
                 'face 'ham-rig-label)
     "\n")))

(defun ham-remote--redisplay ()
  "Repaint the panel if it is on screen."
  (setq ham-remote--redisplay-timer nil)
  (when (ham-remote--panel-visible-p)
    (with-current-buffer (get-buffer-create ham-remote-buffer-name)
      (let ((inhibit-read-only t)
            (line (line-number-at-pos)))
        (erase-buffer)
        (insert (ham-remote--render))
        (goto-char (point-min))
        (forward-line (1- line))))))

(defun ham-remote--schedule-redisplay ()
  "Coalesce repaints onto an idle timer."
  (unless ham-remote--redisplay-timer
    (setq ham-remote--redisplay-timer
          (run-with-idle-timer 0.1 nil #'ham-remote--redisplay))))

(defvar-keymap ham-remote-mode-map
  :doc "Keymap for `ham-remote-mode'."
  "s" #'ham-remote-start
  "S" #'ham-remote-stop
  "r" #'ham-remote-restart
  "R" #'ham-remote-show-radio-end
  "g" #'ham-remote--redisplay)

(define-derived-mode ham-remote-mode special-mode "Remote"
  "Major mode showing the state of the remote audio link."
  (setq-local cursor-type nil
              truncate-lines t))

;;;###autoload
(defun ham-remote ()
  "Open the panel showing the remote audio link."
  (interactive)
  (let ((buffer (get-buffer-create ham-remote-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ham-remote-mode) (ham-remote-mode)))
    (pop-to-buffer buffer)
    (ham-remote--redisplay)))

(provide 'ham-remote)
;;; ham-remote.el ends here
