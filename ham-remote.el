;;; ham-remote.el --- Audio transport for remote operation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 K6SM

;; Author: K6SM
;; Version: 0.2.1
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
;; Audio has to go both ways:
;;
;;   radio end -> operator, so you hear the band
;;   operator -> radio end, so the radio hears you
;;
;; Which program carries them is a back end, chosen by name in
;; `ham-remote-transport'.  A back end says what processes it needs, and
;; there are two shapes of answer.  `trx' and `zita-njbridge' are pairs
;; of one-way pipes and run one process per direction.  `mumble' is a
;; client and a server, and runs one client that carries both ways.
;;
;; Lossless or not is not cosmetic: a digital voice mode puts a
;; modulated waveform on the link rather than speech, and a codec that
;; models the human voice will destroy it.  A back end declares which it
;; is, and `ham-remote-require-lossless' refuses to start a lossy one
;; when the waveform needs to survive.  Of the three here only
;; `zita-njbridge' is lossless.
;;
;; ---------------------------------------------------------------
;; Getting started, if you have not carried audio over a network
;; before
;;
;; Use Mumble.  It is voice chat software rather than anything
;; ham-specific, which means it is packaged everywhere and someone has
;; already solved the hard parts; what it does not know is a radio, and
;; that is what this package supplies.
;;
;; There are three pieces across two machines.  Both ends run a Mumble
;; client.  One machine also runs a Mumble server, which the two clients
;; meet on -- usually the machine at the radio, since that is the one
;; that stays put and needs a reachable address.  A small board computer
;; is enough; the server forwards packets rather than mixing them.
;;
;; Roughly:
;;
;;   1. Install `mumble' on both machines and `mumble-server' on one.
;;   2. On the server machine, M-x ham-remote-mumble-write-server-config
;;      and put the result where the service reads it.  It forces Opus,
;;      keeps the user count small, and stops the server writing a log
;;      that would wear out an SD card.
;;   3. Open port 64738, TCP and UDP.  Voice goes over UDP and falls
;;      back to TCP if it cannot, which works but is worse.
;;   4. Run `mumble' once by hand at each end and let it make a
;;      certificate; that is the identity, and there is no password to
;;      put on a command line.
;;   5. Undo what its audio wizard did.  M-x ham-remote-show-mumble-setup
;;      lists it.  Echo cancellation, noise suppression and gain control
;;      are on by default and each is a model of a human voice in a
;;      quiet room -- a weak signal is exactly what noise suppression
;;      exists to delete.
;;   6. Set `ham-remote-transport' to "mumble", M-x ham-remote, and `s'.
;;
;; The radio end differs from the operator end in two ways: its
;; microphone is the receiver rather than a person, and it transmits
;; continuously because nobody is there to key it.
;; `ham-remote-show-radio-end' prints that end's half.
;;
;; The operator's end is keyed by the transmitter.  Mumble is otherwise
;; open all the time, which puts the shack on the air between overs.
;; The panel shows MIC open or shut so an open microphone is something
;; you can see rather than something you discover later.
;; ---------------------------------------------------------------
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
(require 'url-util)
(require 'easymenu)
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
;;   %r  sample rate   %c  channel count    %m  the program itself
;;   %u  user name     %n  channel name     %U  a mumble:// URL
;;   %i  server configuration file
;;
;; A literal percent sign is %%.

(cl-defstruct (ham-remote-transport (:constructor ham-remote-transport-create)
                                    (:copier nil))
  "One way of carrying audio between the two ends of a link.

ROLES names the processes the operator end runs, and defaults to one
per direction.  A back end that carries both directions down a single
connection says so by naming one role, and ROLE-COMMAND then supplies
the command for each: RECEIVE and TRANSMIT are the two-process case
written out, and are what every back end used before one arrived that
did not fit it."
  name lossless receive transmit radio-receive radio-transmit summary
  roles role-command)

(defconst ham-remote--default-roles '(receive transmit)
  "The processes a transport runs when it does not say otherwise.")

(defun ham-remote-transport-role-list (transport)
  "Return the list of roles TRANSPORT needs at the operator end."
  (or (and (ham-remote-transport-roles transport)
           (funcall (ham-remote-transport-roles transport)))
      ham-remote--default-roles))

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
PROPERTIES is a plist of :host, :port, :device, :rate, :channels,
:program, :user, :channel-name, :url and :config."
  (mapcar
   (lambda (argument)
     (replace-regexp-in-string
      "%[hpdrcmun[:upper:]%]"
      (lambda (token)
        (pcase token
          ("%h" (format "%s" (plist-get properties :host)))
          ("%p" (format "%s" (plist-get properties :port)))
          ("%d" (format "%s" (plist-get properties :device)))
          ("%r" (format "%s" (plist-get properties :rate)))
          ("%c" (format "%s" (plist-get properties :channels)))
          ("%m" (format "%s" (plist-get properties :program)))
          ("%u" (format "%s" (plist-get properties :user)))
          ("%n" (format "%s" (plist-get properties :channel-name)))
          ("%U" (format "%s" (plist-get properties :url)))
          ("%i" (format "%s" (plist-get properties :config)))
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


;;;; Mumble

;; Mumble is not shaped like the other back ends.  They are pairs of
;; one-way pipes between two hosts; Mumble is a client/server system in
;; which one client carries both directions, and a server sits in the
;; middle.  That server is the reason it is worth having: it traverses
;; NAT from both sides, it survives a changing address, and more than
;; one operator can listen to the same radio.
;;
;; What is packaged here is the ham radio dialect of it, which differs
;; from the gaming default in ways that matter:
;;
;;   * Every voice processor is off.  Echo cancellation, noise
;;     suppression and automatic gain control are models of a human
;;     voice, and what travels this link is often not one -- a weak
;;     signal at the noise floor, or a modulated waveform carrying
;;     data.  They will "clean up" both into nothing.
;;   * The operator's microphone is gated by the transmitter rather
;;     than open.  Mumble's own voice activation would put the shack
;;     on the air between overs.
;;   * Opus is forced at the server.  A server that falls back to CELT
;;     because one old client appeared costs more CPU and sounds worse,
;;     which on a small single board computer is the difference between
;;     working and not.

(defcustom ham-remote-mumble-server-programs
  '("mumble-server" "murmurd" "murmur")
  "Names the Mumble server has been packaged under, best first.
Debian calls it `mumble-server\=' from 1.4 on and `murmurd\=' before that;
the BSDs call it `murmur\='.  The first one found is used."
  :type '(repeat string)
  :group 'ham-remote)

(defcustom ham-remote-mumble-client-programs '("mumble")
  "Names the Mumble client has been packaged under, best first."
  :type '(repeat string)
  :group 'ham-remote)

(defcustom ham-remote-mumble-port 64738
  "Port the Mumble server listens on.  64738 is the registered default."
  :type 'integer
  :group 'ham-remote)

(defcustom ham-remote-mumble-user (user-login-name)
  "Name to join the Mumble server under.
Your callsign is the useful thing to put here."
  :type 'string
  :group 'ham-remote)

(defcustom ham-remote-mumble-channel nil
  "Channel to join on connecting, or nil for the server's default."
  :type '(choice (const :tag "Server default" nil) string)
  :group 'ham-remote)

(defcustom ham-remote-mumble-run 'client
  "Which halves of Mumble this machine runs.

`client\=' connects to a server running somewhere else, which is the
operator end of an ordinary setup.  `server\=' runs only the server, for
a machine at the radio end whose job is to sit there and be connected
to.  `both\=' runs the pair, which is convenient for trying the thing out
on one machine and is otherwise unusual."
  :type '(choice (const :tag "Client only" client)
                 (const :tag "Server only" server)
                 (const :tag "Server and client" both))
  :group 'ham-remote)

(defcustom ham-remote-mumble-follow-ptt t
  "When non-nil, the operator's microphone opens only while keyed.

Mumble is otherwise either always open or listening for a voice.  Both
are wrong here: an open microphone puts the shack on the air between
overs, and voice activation clips the first syllable and trips on a
cough.  The transmitter already says exactly when to talk, so this
follows it."
  :type 'boolean
  :group 'ham-remote)

(defcustom ham-remote-mumble-bandwidth 72000
  "Ceiling the server puts on each client, in bits per second.

72000 is Mumble's maximum and what a good link should use: Opus at that
rate is transparent to anything a receiver produces.  Drop it towards
40000 on a link that cannot hold it, and expect a digital mode to
suffer first."
  :type 'integer
  :group 'ham-remote)

(defcustom ham-remote-mumble-users 4
  "How many clients the server admits at once.

Small on purpose.  A remote station is one operator and one radio end,
and a couple spare for someone listening in; every slot beyond that is
memory and crypto a small board has to find."
  :type 'integer
  :group 'ham-remote)

(defcustom ham-remote-mumble-server-config
  (expand-file-name "ham-remote-mumble.ini" user-emacs-directory)
  "Where to write the server configuration this package generates.
Set to an existing file of your own to use that instead; it is only
written when `ham-remote-mumble-write-server-config\=' is called."
  :type 'file
  :group 'ham-remote)

(defcustom ham-remote-mumble-client-command '("%m" "%U")
  "Command starting the Mumble client.
`%m\=' is the program and `%U\=' the mumble:// URL to connect to."
  :type '(repeat string)
  :group 'ham-remote)

(defcustom ham-remote-mumble-server-command '("%m" "-ini" "%i" "-fg" "-v")
  "Command starting the Mumble server.
`%m\=' is the program and `%i\=' the configuration file.  `-fg\=' keeps it in
the foreground, which is what lets this package watch and stop it
rather than losing track of a daemon that forked away."
  :type '(repeat string)
  :group 'ham-remote)

(defun ham-remote--program (candidates what)
  "Return the first of CANDIDATES on PATH, or signal naming WHAT."
  (or (seq-some #'executable-find candidates)
      (user-error "Cannot find %s.  Looked for: %s"
                  what (string-join candidates ", "))))

(defun ham-remote-mumble-url ()
  "Return the mumble:// URL for the configured server.

No password.  Mumble authenticates by certificate, and a password on a
command line is readable by every process list on the machine; a server
that wants one should be saved in the client's own server list."
  (format "mumble://%s@%s:%d%s"
          (url-hexify-string ham-remote-mumble-user)
          ham-remote-host
          ham-remote-mumble-port
          (if ham-remote-mumble-channel
              (concat "/" (url-hexify-string ham-remote-mumble-channel))
            "")))

(defun ham-remote--mumble-roles ()
  "Return the list of Mumble processes for `ham-remote-mumble-run'."
  (pcase ham-remote-mumble-run
    ('client '(link))
    ('server '(server))
    ('both '(server link))
    (_ '(link))))

(defun ham-remote--mumble-command (role)
  "Return the command for Mumble's ROLE."
  (pcase role
    ('server
     (ham-remote--expand
      ham-remote-mumble-server-command
      :program (ham-remote--program ham-remote-mumble-server-programs
                                    "the Mumble server")
      :config ham-remote-mumble-server-config))
    (_
     (ham-remote--expand
      ham-remote-mumble-client-command
      :program (ham-remote--program ham-remote-mumble-client-programs
                                    "the Mumble client")
      :url (ham-remote-mumble-url)
      :user ham-remote-mumble-user
      :host ham-remote-host
      :port ham-remote-mumble-port
      :channel-name (or ham-remote-mumble-channel "")))))

(defun ham-remote--mumble-rpc (action)
  "Ask a running Mumble client to ACTION, and return non-nil if it could.

Mumble takes these on its own command line and passes them to the
instance already running, so there is no socket to keep and nothing to
clean up if the client is not there."
  (when-let ((program (seq-some #'executable-find
                                ham-remote-mumble-client-programs)))
    (eq 0 (call-process program nil nil nil "rpc" action))))

(defun ham-remote-mumble-write-server-config (&optional file)
  "Write a Mumble server configuration for a remote station to FILE.

FILE defaults to `ham-remote-mumble-server-config\='.  What it sets that
a stock configuration does not:

  opusthreshold=0   Opus always, whatever connects.  A server drops to
                    CELT the moment one old client appears, which costs
                    more CPU and sounds worse -- on a small board that
                    is the difference between working and not.
  bandwidth         The ceiling each client may use.
  users             A handful, not a hall.
  logdays=0         Keep no log history.  The server writes it to a
                    SQLite file, and on a machine booting off an SD
                    card the writes are the thing that wears it out.

It does not set a password.  Mumble authenticates by certificate, and
a server on the open internet wants a firewall and a real look at
`serverpassword\=' before it is reachable."
  (interactive)
  (let ((file (or file ham-remote-mumble-server-config)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (ham-remote--mumble-server-config)))
    (message "ham-remote: wrote %s" file)
    file))

(defun ham-remote--mumble-server-config ()
  "Return the text of the generated Mumble server configuration."
  (string-join
   (list
    "; Written by ham-remote.  Edit freely; it is only rewritten when"
    "; M-x ham-remote-mumble-write-server-config is called again."
    ""
    (format "port=%d" ham-remote-mumble-port)
    (format "users=%d" ham-remote-mumble-users)
    (format "bandwidth=%d" ham-remote-mumble-bandwidth)
    ""
    "; Opus always, whatever connects.  Falling back to CELT for one"
    "; old client costs CPU this machine may not have to spare."
    "opusthreshold=0"
    ""
    "; No log history: the writes wear out an SD card for nothing."
    "logdays=0"
    ""
    "; Nothing here announces itself to the public server list."
    "registerName="
    "registerUrl="
    "allowping=false"
    ""
    "welcometext=<b>ham-remote</b><br />Voice processing off, Opus forced."
    "")
   "\n"))

(defun ham-remote--register-mumble-transport ()
  "Register the Mumble back end."
  (ham-remote-register-transport
   (ham-remote-transport-create
    :name "mumble"
    :lossless nil
    :summary "Opus through a Mumble server; crosses NAT, not fit for digital voice"
    :roles #'ham-remote--mumble-roles
    :role-command #'ham-remote--mumble-command)))

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
(ham-remote--register-mumble-transport)


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

(defun ham-remote--roles ()
  "Return the list of roles the configured transport needs here."
  (ham-remote-transport-role-list (ham-remote--current-transport)))

(defun ham-remote--command (role)
  "Return the operator-end command for ROLE."
  (let ((transport (ham-remote--current-transport)))
    (if (ham-remote-transport-role-command transport)
        (funcall (ham-remote-transport-role-command transport) role)
      (ham-remote--expand
       (funcall (if (eq role 'receive)
                    (ham-remote-transport-receive transport)
                  (ham-remote-transport-transmit transport)))
       :host ham-remote-host
       :port (if (eq role 'receive)
                 ham-remote-receive-port
               ham-remote-transmit-port)
       :device (if (eq role 'receive)
                   ham-remote-playback-device
                 ham-remote-capture-device)
       :rate ham-remote-sample-rate
       :channels ham-remote-channels))))

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
    (dolist (role (ham-remote-transport-role-list transport))
      (ham-remote--start-stream role))
    ;; A client takes a moment to come up, and one that was left talking
    ;; comes back talking.  Assert the microphone shut once it is there
    ;; rather than trusting the state it happened to start in.
    (when (equal ham-remote-transport "mumble")
      (run-at-time 3 nil #'ham-remote--close-microphone))
    (message "ham-remote: %s to %s" (ham-remote-transport-name transport)
             ham-remote-host)))

(defun ham-remote--close-microphone ()
  "Shut the Mumble microphone, whatever state it was left in.

Called when the link comes up and when it goes down.  A client that
was talking when something interrupted it stays talking, and the state
this package believes in has to be one it has actually asserted."
  (when (and ham-remote-mumble-follow-ptt (ham-remote--mumble-active-p))
    (with-demoted-errors "ham-remote: mumble: %S"
      (ham-remote--mumble-rpc "stoptalking"))))

;;;###autoload
(defun ham-remote-stop ()
  "Stop carrying audio."
  (interactive)
  (setq ham-remote--running nil)
  ;; Stop whatever is actually running, not only what the transport
  ;; configured now would have started: the setting may have been
  ;; changed while a link was up, and a process nobody is tracking any
  ;; more is a process nobody can stop.
  (dolist (entry ham-remote--streams)
    (ham-remote--stop-stream (car entry)))
  (ham-remote--schedule-redisplay)
  (message "ham-remote: stopped"))

(defun ham-remote-restart ()
  "Stop and start the audio streams."
  (interactive)
  (ham-remote-stop)
  (ham-remote-start))

(defun ham-remote-running-p ()
  "Return non-nil if every process the transport needs is up."
  (and ham-remote--running
       (cl-every (lambda (role)
                   (ham-remote--stream-live-p (ham-remote--stream role)))
                 (ham-remote--roles))))


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

(defun ham-remote--mumble-active-p ()
  "Return non-nil if this package has a Mumble client running."
  (and (equal ham-remote-transport "mumble")
       (ham-remote--stream-live-p (ham-remote--stream 'link))))

(defun ham-remote--on-ptt (keyed)
  "React to the transmitter being KEYED or not.

With Mumble the microphone follows the transmitter.  Anything else
either sends continuously, which puts the shack on the air between
overs, or waits for a voice, which clips the first syllable of every
transmission and opens on a cough."
  (when (and ham-remote-mumble-follow-ptt (ham-remote--mumble-active-p))
    (with-demoted-errors "ham-remote: mumble: %S"
      (ham-remote--mumble-rpc (if keyed "starttalking" "stoptalking"))))
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
  (if (equal ham-remote-transport "mumble")
      (ham-remote--show-mumble-radio-end)
    (ham-remote--show-pipe-radio-end)))

(defun ham-remote--show-mumble-radio-end ()
  "Show what to run at the radio end when the transport is Mumble."
  (with-current-buffer (get-buffer-create "*ham-remote-radio-end*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize "Radio end setup, Mumble\n\n" 'face 'bold))
      (insert "The radio end joins the same server as a second client,\n"
              "and transmits continuously: it has no operator to key it,\n"
              "and what it is sending is the receiver.\n\n")
      (insert (propertize "Audio both ways\n" 'face 'bold))
      (insert (format "  mumble %s\n\n"
                      (format "mumble://radio@%s:%d%s"
                              ham-remote-host ham-remote-mumble-port
                              (if ham-remote-mumble-channel
                                  (concat "/" ham-remote-mumble-channel) ""))))
      (insert (propertize "Its settings differ from this end\n" 'face 'bold))
      (insert "  Transmit           Continuous, not push to talk\n"
              "  Audio input        the receiver, not a microphone\n"
              "  Audio output       the transmitter's audio input\n"
              "  Everything else    as on the operator end: every voice\n"
              "                     processor off\n\n")
      (insert (propertize "If this machine also hosts the server\n" 'face 'bold))
      (insert "  M-x ham-remote-mumble-write-server-config, then run it\n"
              "  under systemd.  Set ham-remote-mumble-run to `server' or\n"
              "  `both' on that machine.\n\n")
      (insert (propertize "Rig control\n" 'face 'bold))
      (insert (format "  rigctld -m MODEL -r /dev/ttyUSB0 -s 38400 -T 0.0.0.0 -t %d\n\n"
                      ham-rig-port))
      (insert (propertize "Also needed\n" 'face 'bold))
      (insert "  Mumble carries its own audio encrypted, but rigctld does\n"
              "  not.  Tunnel the control link, or bind rigctld to the\n"
              "  tunnel address rather than to 0.0.0.0.\n\n")
      (insert "  The transceiver's own transmit timeout, enabled. Nothing\n"
              "  at this end can unkey the radio once the network is gone.\n")
      (goto-char (point-min)))
    (special-mode)
    (pop-to-buffer (current-buffer))))

(defun ham-remote--show-pipe-radio-end ()
  "Show what to run at the radio end for a one-way-pair transport."
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

;;;###autoload
(defun ham-remote-show-mumble-setup ()
  "Show the Mumble client settings a remote station wants.

These cannot be set from here: Mumble keeps them in its own
configuration and offers no way in.  They are worth getting right
anyway, because the defaults are tuned for a headset in a game and
several of them will quietly ruin a radio link."
  (interactive)
  (with-current-buffer (get-buffer-create "*ham-remote-mumble-setup*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize "Mumble settings for a remote station\n\n" 'face 'bold))
      (insert "Configure > Settings, with Advanced ticked.\n\n")

      (insert (propertize "Audio Input > Audio Processing\n" 'face 'bold))
      (insert "  Echo cancellation      OFF\n"
              "  Noise suppression      OFF\n"
              "  Amplification / AGC    OFF (drag to maximum)\n"
              "  Speech detection       n/a once transmit is push to talk\n\n")
      (insert "  These three are the ones that matter, and they are all on\n"
              "  by default.  Each is a model of a human voice in a quiet\n"
              "  room.  What travels this link is often neither: a signal\n"
              "  at the noise floor is exactly what noise suppression is\n"
              "  built to remove, and a modulated waveform carrying data\n"
              "  is not speech at all.  Leave them on and the band sounds\n"
              "  dead and every digital mode fails to decode.\n\n")

      (insert (propertize "Audio Input > Transmission\n" 'face 'bold))
      (insert "  Transmit               Push To Talk\n"
              "  Audio per packet       10 ms\n"
              "  Quality                72 kb/s\n\n")
      (insert "  Push to talk is what lets this package key the microphone\n"
              "  from the transmitter.  With ham-remote-mumble-follow-ptt\n"
              "  set, no shortcut key is needed: the rig's own PTT opens\n"
              "  and shuts it.  Leave Mumble in continuous or voice\n"
              "  activated mode and that gating does nothing.\n\n")

      (insert (propertize "Audio Output\n" 'face 'bold))
      (insert "  Default jitter buffer  20 ms to start\n"
              "  Output delay           minimum\n"
              "  Positional audio       OFF\n"
              "  Attenuate applications OFF\n\n")
      (insert "  Jitter, not latency, is what breaks remote audio.  A link\n"
              "  with a fifth of a second of delay and no jitter is\n"
              "  comfortable to operate; one with half that delay and a\n"
              "  jittery last mile is not.  Raise the buffer until the\n"
              "  breaking up stops and no further.\n\n")

      (insert (propertize "User Interface and Messages\n" 'face 'bold))
      (insert "  Text to speech         OFF\n"
              "  Connection sounds      OFF\n\n")
      (insert "  Both would otherwise be transmitted at the radio end.\n\n")

      (insert (propertize "This end\n" 'face 'bold))
      (insert (format "  Server               %s\n" (ham-remote-mumble-url)))
      (insert (format "  Runs here            %s\n" ham-remote-mumble-run))
      (insert (format "  Microphone follows   %s\n"
                      (if ham-remote-mumble-follow-ptt
                          "the transmitter" "nothing -- always open")))
      (insert (format "  Server config        %s\n\n"
                      ham-remote-mumble-server-config))
      (insert "  M-x ham-remote-show-radio-end for the other end.\n")
      (goto-char (point-min)))
    (special-mode)
    (pop-to-buffer (current-buffer))))


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

(defconst ham-remote--role-labels
  '((receive . "RX audio") (transmit . "TX audio")
    (link . "Mumble") (server . "Server"))
  "What each process is called in the panel.")

(defun ham-remote--role-label (role)
  "Return the panel label for ROLE."
  (or (alist-get role ham-remote--role-labels)
      (capitalize (symbol-name role))))

(defun ham-remote--render ()
  "Return the panel contents."
  (let* ((transport (ham-remote-transport-named ham-remote-transport))
         (roles (and transport (ham-remote-transport-role-list transport)))
         (mumble (equal ham-remote-transport "mumble")))
    (concat
     "\n  "
     (propertize (or ham-remote-transport "no transport") 'face 'ham-rig-label)
     "   "
     (propertize (if (and mumble (eq ham-remote-mumble-run 'server))
                     (format "hosting on :%d" ham-remote-mumble-port)
                   ham-remote-host)
                 'face 'ham-rig-label)
     (if (and transport (ham-remote-transport-lossless transport))
         (propertize "   lossless" 'face 'ham-rig-rx)
       (propertize "   compressed" 'face 'ham-rig-label))
     "\n\n"
     (mapconcat (lambda (role)
                  (ham-remote--describe-stream role
                                               (ham-remote--role-label role)))
                roles "")
     "\n  "
     (propertize "PTT " 'face 'ham-rig-label)
     (if (ham-rig-ptt-p)
         (propertize "transmitting" 'face 'ham-rig-tx)
       (propertize "receiving" 'face 'ham-rig-rx))
     ;; With Mumble the microphone is a thing this package holds open or
     ;; shut, so the panel says which -- an open microphone the operator
     ;; has not noticed is the failure worth seeing.
     (if (and mumble ham-remote-mumble-follow-ptt)
         (concat (propertize "   MIC " 'face 'ham-rig-label)
                 (if (and (ham-rig-ptt-p) (ham-remote--mumble-active-p))
                     (propertize "open" 'face 'ham-rig-tx)
                   (propertize "shut" 'face 'ham-rig-rx)))
       "")
     "\n\n  "
     (propertize (if mumble
                     "s start  S stop  r restart  R radio end  M settings"
                   "s start  S stop  r restart  R radio end")
                 'face 'ham-rig-label)
     "\n  "
     (propertize (if mumble
                     "w write server config  g refresh  q quit"
                   "g refresh  q quit")
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
  "M" #'ham-remote-show-mumble-setup
  "w" #'ham-remote-mumble-write-server-config
  "g" #'ham-remote--redisplay
  "q" #'quit-window)

(easy-menu-define ham-remote-mode-menu ham-remote-mode-map
  "Menu for `ham-remote-mode'."
  '("Remote"
    ["Start" ham-remote-start :keys "s"]
    ["Stop" ham-remote-stop :keys "S"]
    ["Restart" ham-remote-restart :keys "r"]
    "---"
    ["Radio end setup" ham-remote-show-radio-end :keys "R"]
    ["Mumble settings" ham-remote-show-mumble-setup :keys "M"]
    ["Write Mumble server config" ham-remote-mumble-write-server-config
     :keys "w"]
    "---"
    ["Customize" (lambda () (interactive) (customize-group 'ham-remote))]
    "---"
    ["Bury panel" quit-window :keys "q"]))

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
