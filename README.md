# ham.el

Amateur radio support for Emacs, by K6SM.

**`ham-rig.el`** is a transceiver control panel. It shows frequency, band, mode,
passband, VFO, split and tuning step; an S-meter while receiving; and power,
ALC, compression, SWR and supply voltage and current while transmitting. A
second panel adjusts every level and switch the radio offers. It speaks to the
radio through Hamlib's `rigctld`, and publishes what it sees on an event bus so
other packages can follow the radio.

**`ham-spacewx.el`** is a space weather panel: solar flux, sunspot number, X-ray
flux and its multi-day peak, proton flux, the planetary K and A indices, and the
real time solar wind. It reports the NOAA R, S and G scales as they stand and as
they peaked over the last day, and estimates the maximum usable frequency and
band conditions for your own location.

**`ham.el`** is the library underneath: an event bus, an asynchronous line
transport, Maidenhead and great-circle geodesy, a band plan, and frequency
parsing and formatting. It has no user interface.

Everything works in a terminal.

| File | Contents |
| --- | --- |
| `ham.el` | Event bus, TCP transport, geodesy, band plan. |
| `ham-rig.el` | Transceiver panel and controls panel. |
| `ham-remote.el` | Audio transport for operating over a network. |
| `ham-spacewx.el` | Space weather, NOAA scales and a propagation estimate. |

## Requirements

- Emacs 29.1 or later
- [Hamlib](https://hamlib.github.io/), for `rigctld`
- `curl`, optional, for `ham-spacewx` — standard on macOS and Linux, and
  shipped with Windows since 10/1803. Without it the panel falls back to
  Emacs's own `url.el`, whose connection setup can block the editor when the
  network is unreachable.
- An audio transport, optional, for `ham-remote` — [Mumble](https://www.mumble.info/)
  is the one to start with, and [Getting started with audio](#getting-started-with-audio)
  walks through it from nothing. `trx` and `zita-njbridge` are alternatives.

Developed on Emacs 29.3 and Hamlib 4.5.5, tested with a Yaesu FTDX10.

## Installation

```elisp
(add-to-list 'load-path "~/.emacs.d/lisp/ham/")
(require 'ham-rig)
```

## Running rigctld

Start one `rigctld` for the radio and leave it running:

```
rigctld -m 1042 -r /dev/ttyUSB0 -s 38400
```

`rigctl -l` lists model numbers; `1042` is the FTDX10.

Run **one** `rigctld` and point every program at it — this package, WSJT-X,
fldigi, your logger. It owns the serial port; opening that port directly locks
out everything else on the station.

With no radio to hand, Hamlib's dummy works:

```
rigctld -m 1 -P RIG
```

`-P RIG` makes the dummy accept PTT, which it otherwise refuses.

`ham-rig-host` may be any machine, so a `rigctld` across the network works
as well as a local one. [wfview](https://wfview.org/) provides `rigctld`
emulation, which gives you LAN remote operation with wfview carrying the audio.

## The rig panel

`M-x ham-rig` opens the panel and connects.

```
  FTDX-10   connected   localhost:4532

  14.074.000   20m   STEP 1 k

  VFO VFOA    MODE USB       BW 2400 Hz   SPLIT off

  RX  ████▏░░░░░░░░░░░░░░░░  S3
```

| Key | Action |
| --- | --- |
| `↑` `↓` | Tune one step |
| `M-↑` `M-↓` | Tune ten steps (also `PgUp` `PgDn`) |
| `←` `→` | Smaller / larger step |
| `.` | Choose a step |
| `f` | Set frequency: `14074`, `14.074` or `14.074.000` |
| `m` | Set mode |
| `b` | Change band |
| `v` | Swap VFO |
| `s` | Toggle split |
| `t` | Key or unkey |
| `T` | Panic unkey |
| `u` | Antenna tuner in or out |
| `A` | Run the tuner's tuning cycle |
| `P` | Switch the radio on or off |
| `C` | Controls panel |
| `g` | Poll everything now |
| `c` `d` | Connect / disconnect |
| `?` `h` | Every key, in a buffer |
| `i` | Capabilities the radio reported |
| `S` | Link statistics |

### Tuning

`↑` and `↓` tune by the current step; `←` and `→` change the step, which is
shown beside the band. Steps run from 1 Hz to 1 MHz, set by
`ham-rig-tuning-steps` and `ham-rig-default-tuning-step`.

The readout moves on the keypress and the next poll corrects it to what the
radio settled on, so holding a key tunes smoothly. Only the newest frequency is
sent.

### Transmitting

While keyed, the S-meter is replaced by a bar for each meter the radio reports,
and the elapsed transmission time:

```
  TX   12s
  PWR  ██████████████████░░░░  85 W
  ALC  ███████░░░░░░░░░░░░░░░
  COMP ██████████░░░░░░░░░░░░  12 dB
  SWR  ████████░░░░░░░░░░░░░░  2.40
  VDD  ███████████████████░░░  13.2 V
  ID   █░░░░░░░░░░░░░░░░░░░░░  1.8 A
```

- **SWR** runs 1:1 at the left to infinity at the right, scaled by reflection
  coefficient. Amber past 2:1, red past 3:1.
- **ALC** is a bar alone — the number Hamlib reports for it has no units.
  Amber past half scale, red past 80%.
- **Power** reads in watts, converted by the radio.
- **Compression, supply voltage and current** read in dB, volts and amps, as
  the radio reports them.

`ham-rig-tx-meters` chooses which meters appear, and only those the radio
reports are shown.

Two settings control how a meter is drawn:

- `ham-rig-meter-zones` sets where a bar turns amber and red. **The ALC
  thresholds are a starting point, not a specification** — Hamlib does not
  report where a radio's own ALC zone ends. Compare the bar against the
  radio's ALC marking and move them to match.
- `ham-rig-meter-ranges` sets the range a bar is drawn over, where the range
  Hamlib declares does not describe the readings. An FTDX10 declares supply
  voltage as 0 to 1 and then answers 13.25, so a bar drawn over the declared
  range sits at full scale whatever the radio is doing. **A bar stuck at one
  end means the range here needs correcting for your radio.**

### Transmit safety

- A watchdog unkeys the radio if a transmission runs too long.
- **Unkeying is confirmed, not assumed.** After commanding the radio off,
  `ham-rig` reads PTT back. If the radio still reports itself transmitting it
  commands the unkey again, up to `ham-rig-unkey-attempts` times, and warns you
  to use the front panel if it never succeeds.
- Emacs unkeys on exit.
- Losing the link while keyed warns, and unkeys again on reconnection.
- The event bus never keys the radio. Only a direct keystroke transmits.

The watchdog budget is `ham-rig-tx-timeout` (180 s) when the length of a
transmission is not known in advance, as with live voice. Where the length *is*
known, a caller declares it with `ham-rig-expect-transmission` and the budget
becomes that duration times `ham-rig-tx-watchdog-margin`, bounded below by
`ham-rig-tx-watchdog-floor` and above by `ham-rig-tx-timeout-max`. The antenna
tuner cycle uses this: it is held to about 25 seconds rather than three
minutes, so a tuner that jams keys the transmitter for seconds instead of
minutes.

CAT has no dead-man behaviour: if the control link dies mid-transmission,
nothing in software can unkey the radio. **Enable your transceiver's own TX
timeout timer.**

## The controls panel

`C`, or `M-x ham-rig-controls`.

```
  FTDX-10   controls

  LEVELS
    PREAMP       ######.... AMP1    IPO/AMP1/AMP2
    RFPOWER      #####..... 50 W    5%..100%
    DNR          ####...... 40%     0%..100%
    MICGAIN      ####...... 35%     0%..100%
    KEYSPD       ###....... 22      4..60
    IF           #####..... -200    -1200..1200

  FUNCTIONS
    TUNER        on
    VOX          off
```

| Key | Action |
| --- | --- |
| `←` `→` | Adjust, or toggle a switch |
| `M-←` `M-→` | Adjust ten steps (also `-` `+`) |
| `RET` `SPC` | Toggle a switch, or set a level |
| `=` | Type a value |
| `g` | Re-read everything |
| `?` `h` | Every key, in a buffer |

The list is built from the radio's own `\dump_caps` report, so it shows what
this radio has: IF shift, notch, transmit power, noise reduction, noise
blanker, CW speed and pitch, mic gain, VOX gain and delay, monitor level,
compression, break-in delay, preamp, attenuator, squelch, AF and RF gain, and
switches for the tuner, VOX, ANF, APF, manual notch and RIT. A different radio
gives a different panel.

Read-only meters stay out of this panel. Controls the radio reports with no
usable range are omitted — on the FTDX10 that is AGC, which takes named
settings Hamlib does not describe.

### Units

Hamlib reports most levels as a fraction rather than in the radio's own units.

- **Transmit power** reads in watts, converted by the radio.
- **Preamp and attenuator** read as switch positions.
- **Everything else normalised** reads as a percentage.

Two limits are worth knowing:

- Hamlib names a preamp position `10dB`, not `AMP1`. Supply your radio's words
  with `ham-rig-control-value-labels` and `ham-rig-control-labels`:

  ```elisp
  (setq ham-rig-control-value-labels
        '(("PREAMP" (0 . "IPO") (10 . "AMP1") (20 . "AMP2")))
        ham-rig-control-labels '(("NR" . "DNR")))
  ```

- Where Hamlib has already flattened a scale, the original is unrecoverable.
  The FTDX10's DNR runs 1 to 15 on the radio; Hamlib presents 0 to 1 in tenths,
  so it reads as a percentage.

Roofing filter and contour are not available: the FTDX10 backend exposes them
as neither level nor function.

## Operating remotely

`ham-rig-host` already reaches a `rigctld` on any machine. `ham-remote.el` adds
the audio, in both directions, and `M-x ham-remote` shows what it is doing:

```
  trx   radio.local   compressed

  RX audio  running   142s
  TX audio  running   142s

  PTT  receiving
```

| Key | Action |
| --- | --- |
| `s` `S` | Start / stop the audio |
| `r` | Restart |
| `R` | Show what to run at the radio end |
| `M` | Mumble client settings |
| `w` | Write a Mumble server configuration |
| `g` | Refresh |

No audio passes through Emacs. External programs carry it, and this package
starts them, restarts them if they die, sequences them against PTT, and reports
their state.

### Getting started with audio

If you have not used Mumble before, start here. Mumble is a voice chat system;
we are using it as a two-way audio link with a radio on one end. Nothing about
it is ham-specific, which is why its defaults are wrong for us in a few
important ways — this section gets you from nothing to a working link.

**Three pieces, on two machines.**

```
   your desk                          the radio
  ┌──────────────┐                  ┌──────────────────────┐
  │ Mumble       │                  │ Mumble client        │
  │ client       │ ◄──────────────► │ (mic = receiver out, │
  │ (headset)    │      audio       │  speaker = rig mic)  │
  │              │                  │                      │
  │ Emacs        │ ◄──────────────► │ rigctld              │
  │ ham-rig      │   rig control    │                      │
  │ ham-remote   │                  │ Mumble server ◄──────┼── usually here
  └──────────────┘                  └──────────────────────┘
```

Both ends run a Mumble **client**. One machine also runs the Mumble **server**,
which the two clients meet on. The server normally lives at the radio end — a
Raspberry Pi is plenty — but it can be anywhere both ends can reach.

The server is what makes this easier than a direct connection: only one machine
needs a reachable address, and it is the one that stays put.

#### 1. Install

| | Client | Server |
| --- | --- | --- |
| Debian, Ubuntu, Raspberry Pi OS | `sudo apt install mumble` | `sudo apt install mumble-server` |
| Fedora | `sudo dnf install mumble` | `sudo dnf install mumble-server` |
| Arch | `sudo pacman -S mumble` | `sudo pacman -S murmur` |
| macOS | `brew install --cask mumble` | run it on Linux instead |
| Windows | installer from mumble.info | installer from mumble.info |
| FreeBSD | `pkg install mumble` | `pkg install murmur` |

Install the **client** on both machines and the **server** on one of them.

The server binary is called `mumble-server` on newer packages and `murmurd` on
older ones; `ham-remote` looks for both, so you do not need to know which you
have.

#### 2. Set up the server

On Debian and Raspberry Pi OS the package asks the important questions for you:

```
sudo dpkg-reconfigure mumble-server
```

Say yes to starting at boot. It will ask you to set a **SuperUser** password —
that is the server's administrator account, and you only need it if you later
want to change server settings from inside a client. Write it down anyway.

Elsewhere, or to set it again later:

```
sudo mumble-server -ini /etc/mumble-server.ini -supw YOUR-PASSWORD
```

On older packages that binary is `murmurd`; the arguments are the same.

Then replace the stock configuration with one tuned for a radio link. In Emacs,
on the machine that will run the server:

```
M-x ham-remote-mumble-write-server-config
```

That writes a file (see `ham-remote-mumble-server-config` for where). Copy it
over `/etc/mumble-server.ini`, keeping a backup, and restart the service:

```
sudo systemctl restart mumble-server
```

Run it under the system's own service manager rather than from Emacs: the
server should be up whether or not anyone is logged in. `ham-remote` *can* run
it — set `ham-remote-mumble-run` to `server` or `both` — which is handy for
trying the whole thing out on one machine before you commit to wiring.

What it changes and why is in [Mumble](#mumble) below; the short version is
that it forces Opus, keeps the user count small, and stops the server writing
a log that would wear out an SD card.

**Open the port.** Mumble uses **64738**, both TCP and UDP. TCP carries the
control connection and UDP carries the voice; if UDP cannot get through, Mumble
still works but routes voice over TCP, which is noticeably worse. If the radio
is across the internet rather than the house, forward both on the router, or —
better — put both machines on a VPN and skip the forwarding entirely. You want
the VPN anyway: `rigctld` has no authentication of its own.

#### 3. Set up the client at your desk

Run `mumble` once by hand before involving Emacs. On first launch it offers two
wizards:

- The **Audio Wizard** picks your input and output devices and sets levels. Run
  it — device selection is the fiddly part and it does it well.
- The **Certificate Wizard** creates your identity. Mumble authenticates by
  certificate rather than by password, so accept the default and let it make
  one.

**Then undo some of what the Audio Wizard did.** It is tuned for a headset in a
quiet room and will have enabled things that ruin a radio link. Press `M` in
the `ham-remote` panel — or `M-x ham-remote-show-mumble-setup` — for the full
list; the ones that matter are echo cancellation, noise suppression and gain
control (all **off**) and transmit mode (**Push To Talk**).

Now tell `ham-remote` where the server is:

```elisp
(setq ham-remote-host "radio.local"        ; the machine running the server
      ham-remote-transport "mumble"
      ham-remote-mumble-user "K6SM"        ; your callsign
      ham-remote-mumble-run 'client)
```

`M-x ham-remote`, then `s`. The panel should show `Mumble  running`.

#### 4. Set up the client at the radio

The radio end runs a Mumble client too, with two differences: its microphone is
the receiver rather than a person, and it transmits **continuously** — there is
nobody there to key it.

Wire the audio first. You need the receiver's audio going into the machine's
input, and the machine's output going into the transmitter's audio input. Most
modern transceivers present a USB sound device that does both; otherwise an
interface like a SignaLink sits between. Pick that device — not the machine's
built-in one — in Mumble's Audio Wizard.

`R` in the panel prints the exact command and settings for this end.

Set the transmit level with the rig's ALC meter, not by ear: bring the audio up
until ALC just begins to move and stop there.

#### 5. Check it works

1. At your desk, `M-x ham-remote` and `s`. The panel shows `Mumble running`.
2. You should hear the band. If not, the problem is at the radio end's input.
3. `M-x ham-rig`, connect, and key with `t`. The panel's `MIC` should flip from
   `shut` to `open`, and the radio should transmit your voice.
4. Unkey. `MIC` goes back to `shut`.

That `MIC` line is worth watching. `ham-remote` holds the Mumble microphone
closed except while the rig is keyed, so your shack is not on the air between
overs — but that only works if Mumble is in **Push To Talk** mode. If `MIC`
says `open` when you are not transmitting, that setting is wrong.

#### When it does not work

| Symptom | Usually |
| --- | --- |
| No audio either way | Server not reachable: check port 64738 TCP **and** UDP |
| Audio breaks up | Raise the jitter buffer 10 ms at a time |
| Everything sounds far away and thin | Noise suppression or AGC still on |
| Weak signals vanish into silence | Noise suppression |
| Digital modes will not decode | Any of the three processors; or use a lossless back end |
| First syllable clipped | Mumble in voice-activated mode, not Push To Talk |
| `MIC open` with the rig unkeyed | Mumble not in Push To Talk mode |
| Delay grows the longer you talk | Buffering somewhere; restart the client |
| Hum on transmit | Ground loop — an isolating interface, not a software fix |

`M-x ham-remote-show-mumble-setup` lists every setting and what it is for.

### Choosing a transport

Which program carries the audio is a **back end**, selected by name in
`ham-remote-transport`:

| Back end | Carries | Needs |
| --- | --- | --- |
| `trx` | Opus over RTP; low bandwidth | `trx` |
| `zita-njbridge` | Uncompressed samples | `zita-njbridge`, JACK |
| `mumble` | Opus through a Mumble server | `mumble`, `mumble-server` |

Every command is a list of strings you can edit —
`ham-remote-trx-transmit-command` and friends — with `%h` for host, `%p` port,
`%d` device, `%r` sample rate, `%c` channels, `%m` the program, `%u` user,
`%n` channel and `%U` a `mumble://` URL. Correct them there if your build's
options differ; no code changes are needed. Register your own back end with
`ham-remote-register-transport`.

`trx` and `zita-njbridge` are pairs of one-way pipes: one process per
direction. Mumble is not — one client carries both ways, and a server sits in
the middle. A back end says which processes it needs, so both shapes work.

For `trx`, the latency control is the Opus frame size, `-f`, in samples: at
48 kHz the codec permits 120, 240, 480 or 960 — 2.5, 5, 10 or 20 ms. The
receiver's jitter buffer, `-j`, trades delay against tolerance of an uneven
network.

### Mumble

Mumble is the one back end that is not a pair of pipes between two hosts. A
server sits in the middle, which is why it is worth having: it crosses NAT from
both sides, it survives an address that changes, and more than one person can
listen to the same radio.

`ham-remote-mumble-run` says which halves this machine runs — `client` at the
operator end, `server` on the machine at the radio end, `both` to try it on one
box. `M-x ham-remote` starts and stops whichever apply, watches them, and
restarts them if they die.

**The microphone follows the transmitter.** Mumble is otherwise open all the
time, which puts the shack on the air between overs, or listening for a voice,
which clips the first syllable and opens on a cough. With
`ham-remote-mumble-follow-ptt` set, keying the rig runs `mumble rpc
starttalking` and unkeying runs `stoptalking`, so the microphone is open only
while the transmitter is. The panel shows `MIC open` or `MIC shut` — an open
microphone nobody noticed is the failure worth seeing. **This requires Mumble
to be in Push To Talk mode**; in continuous or voice-activated mode the gating
does nothing.

`M` prints the client settings a remote station wants. The ones that matter:

| Setting | Value | Why |
| --- | --- | --- |
| Echo cancellation | **off** | |
| Noise suppression | **off** | A weak signal is exactly what it removes |
| Amplification / AGC | **off** | |
| Transmit | Push To Talk | So the rig's PTT can drive it |
| Audio per packet | 10 ms | The main latency control |
| Quality | 72 kb/s | ≥64 kb/s enables Opus low delay mode |
| Jitter buffer | 20 ms, then raise | Jitter breaks audio; latency alone does not |
| Text to speech, sounds | off | They would go out over the air |

The first three are on by default and are each a model of a human voice in a
quiet room. What crosses this link is often neither — a signal at the noise
floor, or a modulated waveform carrying data. Leave them on and the band sounds
dead and digital modes stop decoding.

`w` writes a server configuration. It sets `opusthreshold=0`, which forces Opus
whatever connects: a server falls back to CELT the moment one old client
appears, which costs more CPU and sounds worse. On a Raspberry Pi Zero 2W that
is the difference between working and not. It also keeps `users` small and sets
`logdays=0`, since the server writes its log to SQLite and on a machine booting
off an SD card those writes are what wears it out.

The server neither mixes nor transcodes — it forwards packets — so its load is
per-client crypto and networking rather than audio work. A Pi handles a remote
station's two or three clients comfortably.

Mumble authenticates by certificate, so no password appears on any command
line, where every process list on the machine could read it. A server that
needs one should be saved in the client's own server list.

Mumble compresses, so `ham-remote-require-lossless` refuses it — see below.

### Compressed audio and digital voice

A back end declares whether it preserves the waveform. This matters for digital
voice: what crosses the link is then a modulated waveform rather than speech,
and a codec built to model the human voice will destroy it. Set
`ham-remote-require-lossless` and a compressing back end is refused, naming one
that would do instead.

### The radio end

The radio end runs its half under systemd, so it starts at boot and does not
depend on Emacs. `R` in the panel, or `M-x ham-remote-show-radio-end`, prints
the two commands for your current configuration, along with the `rigctld`
invocation.

Both need a tunnel: `rigctld` has no authentication or encryption at all.
WireGuard suits this better than SSH, whose forwarding is built for TCP while
the audio is UDP.

### Not yet done

**Nothing at the operator's end can unkey the transmitter once the network is
gone.** This is the same gap CAT has, made likelier by a longer link. A
radio-end watchdog is the next piece of work. Until it exists, remote operation
rests on the transceiver's own transmit timeout — **enable it**.

## Space weather

`M-x ham-spacewx` opens the panel. Nothing needs configuring first; it reads the
public feeds published by the NOAA Space Weather Prediction Center.

The second line carries the NOAA scales — radio blackout, radiation storm and
geomagnetic storm — as they stand now and as they peaked over the last 24 hours.
A storm that has already passed still shaped the day's propagation, so both
matter.

The propagation estimate comes first, because it is the question the rest of the
panel is evidence for. The indices behind it follow.

The panel lays itself out to fifty columns — `ham-spacewx-panel-width` — so it
can sit in a side window beside the log or the rig panel without wrapping:

```
Propagation for grid CM98jr
  MUF, 3000 km hop (MHz)          26.4
  MUF in 12 h (MHz)               9.7
  Absorption floor (MHz)          6.4
  Bands by day
    160m 80m 40m 30m 20m 17m 15m 12m 10m 6m
  Bands at night
    160m 80m 40m 30m 20m 17m 15m 12m 10m 6m

Solar wind (DSCOVR)
  Speed (km/s, 6 h, 250–800)
    ~~~~~~~------------~~~~~~~~=  527
  Bz (nT, 15 h, ±20)
    ~~~~-------~~~~======++++++=  5.0 north
```

A reading takes two lines. The first names it and gives, in one parenthesis,
everything about it that does not change between refreshes: its unit, how long
its trace covers, and the scale that trace is drawn to. The second draws the
trace and puts the number at the end of it, so every value in the panel lines up
on the right hand end of its own sparkline — which is where the eye already is.
The trace says what has been happening; the number finishes the sentence with
what is happening now, and the words after it say what that means.

Splitting them that way means the eye returning to the panel lands on what moved.
A unit and a scale do not change; the number does.

Sparklines are one width across the panel whatever the feed's cadence, so rows
covering the same period line up column for column. When a feed has aged out,
its age replaces the scale in the parenthesis: a number you cannot date matters
more than the height of its ramp. Bz is drawn about zero, since its sign is the
whole point, and reports its half height instead — a trace sitting low spent
that window southward.

Values, traces and the words beside them share one set of colours. Readings that
feed a NOAA scale are coloured on that scale, so the panel and the published
alert level agree. The rest use the same palette to mean quiet, degraded and
serious.

Two things sit outside that palette. What is in parentheses wears the same quiet
face as the panel's opening lines, because it is context rather than content and
should not compete with the readings. The propagation figures wear a colour of
their own, because nothing measured them: they are worked out from the indices
above them, and the colour says so on every row without a word of caveat on any
of them. An age in parentheses is the exception to the first rule — a reading
that has stopped being current should not read as quietly as one that has not.

| Key | Action |
| --- | --- |
| `g` | Read any feed whose data has passed its own interval |
| `G` | Read every feed now |
| `w` | Show the exact solar wind record in use |
| `c` | Discard stored readings |
| `?` | Explain the panel |

The same commands are on the **Space Wx** menu.

### When a feed fails

A failed read keeps the last good reading rather than blanking the row, and says
how old it is. Stale space weather is worth seeing as long as the panel is
honest about its age; an empty panel tells you nothing. Any reading past
`ham-spacewx-stale-after` carries its age, whatever the reason.

A machine resuming from sleep finds every feed timing out at once. The panel
notices the gap, waits for the network, and retries once.

A feed can also arrive whole and carry nothing. GOES publishes a flux of exactly
zero for every record while its X-ray instrument is down, rather than omitting
them, and zero is not a quiet sun — the long band sits near 1e-8 at solar
minimum and cannot physically reach zero. Drawn as data those zeros make a flat
trace along the bottom of the ramp, in the colour of a quiet reading: a picture
of six calm hours that were never observed. They are dropped instead, and the
panel says `no data: every flux reads zero`. `ham-spacewx-xray-floor` sets where
a measurement stops counting as one.

`M-x ham-spacewx-diagnose` re-reads every feed and reports what each answered:
the fields it carries, how many records survive being narrowed to one energy
channel, how many of those carry a measurement, and the current value of every
reading taken from it. The report updates itself as the feeds land. It is the
first thing to run when a row is empty, because it separates a moved endpoint
from a network problem from an instrument outage from a payload this package
does not understand.

### Solar wind

The real time solar wind files carry every reporting spacecraft in one document,
interleaved and not in time order. The panel sorts by timestamp, narrows to a
single spacecraft, and drops samples the feed grades as poor — reading a mixture
of DSCOVR and ACE is meaningless, since they sit at different points and are
calibrated separately.

`w` shows the exact record in use: spacecraft, timestamp and quality grade. Put
it beside NOAA's own plot when the two disagree.

`ham-spacewx-wind-spacecraft` follows SWPC's active flag by default, or pins to
one spacecraft so you can compare like with like.

### Propagation estimate

Set `ham-station-grid` to your locator and the panel opens with an estimated
maximum usable frequency for a 3000 km hop now and twelve hours out, an
absorption floor, and per-band summaries for day and night — the evening's bands
being the thing worth planning around. Now and twelve hours out are two rows
rather than one row and a parenthesis, so they share a column and can be
compared by looking down it.

The section is headed with the locator it was worked out for —
`Propagation for grid CM98jr` — because whose ionosphere this is matters more
than a reminder that it is modelled. That caveat is below, and in the help.

**This is a model, not a measurement.** It predicts the ionosphere from solar and
geomagnetic indices; an ionosonde network measures it directly. Where the two
disagree the ionosonde is right. The chain is the standard one: solar ultraviolet
ionises the F2 layer, so the critical frequency follows the solar zenith angle
and the level of solar activity; multiplying by an obliquity factor gives the
maximum usable frequency; the D layer, lit by the same sunlight and flooded by
flare X-rays, absorbs rather than refracts and sets a floor. A band is open
between the two. Geomagnetic storms depress the F2 layer in proportion to
geomagnetic latitude, which is why a storm closes paths from Alaska while
leaving equatorial ones alone. The F2 maximum lags local noon by a couple of
hours, because recombination at that height is slow.

The parameterisation follows [OpenHamClock](https://github.com/accius/openhamclock)
(MIT), so this panel and the figures published elsewhere agree rather than
differing by several MHz for no visible reason. Every coefficient is a
`defcustom`, so the model can be corrected against real soundings rather than
argued about.

## Configuration

`M-x customize-group RET ham-rig`, `RET ham-spacewx`, and `RET ham`.

| Option | Default | Meaning |
| --- | --- | --- |
| `ham-rig-host` `ham-rig-port` | `localhost` `4532` | Where `rigctld` listens |
| `ham-rig-fast-interval` | `0.2` | Seconds between frequency, PTT and meter polls |
| `ham-rig-slow-interval` | `1.0` | Seconds between mode, VFO and split polls |
| `ham-rig-tx-timeout` | `180` | Watchdog unkey when the duration is unknown |
| `ham-rig-tx-timeout-max` | `600` | Ceiling on the watchdog, whatever is declared |
| `ham-rig-tx-watchdog-margin` | `1.25` | Allowance over a declared duration |
| `ham-rig-unkey-attempts` | `3` | Unkey commands before warning the operator |
| `ham-rig-atu-timeout` | `20` | Expected length of a tuner cycle, in seconds |
| `ham-remote-host` | `radio.local` | Machine at the radio end |
| `ham-remote-transport` | `trx` | Which back end carries the audio |
| `ham-remote-mumble-run` | `client` | Which halves of Mumble this machine runs |
| `ham-remote-mumble-follow-ptt` | `t` | Microphone open only while keyed |
| `ham-remote-mumble-user` | login name | Name to join the server under |
| `ham-remote-mumble-channel` | `nil` | Channel to join, or the default |
| `ham-remote-mumble-port` | `64738` | Mumble's registered port |
| `ham-remote-mumble-bandwidth` | `72000` | Per-client ceiling, bits per second |
| `ham-remote-mumble-users` | `4` | Slots the server admits |
| `ham-remote-require-lossless` | `nil` | Refuse a back end that compresses |
| `ham-rig-meter-ranges` | VDD, ID, comp | Range to draw a meter over |
| `ham-rig-meter-zones` | SWR, ALC | Where a bar turns amber and red |
| `ham-remote-settle-delay` | `0.2` | Seconds from keying to audio being worth sending |
| `ham-rig-tuning-steps` | 1 Hz … 1 MHz | Steps `←` and `→` cycle |
| `ham-rig-tx-meters` | power, ALC, comp, SWR, VDD, ID | Meters shown while keyed |
| `ham-rig-meter-units` | comp, VDD, ID | Full scale for normalised meters |
| `ham-rig-meter-zones` | SWR at 2 and 3 | Where a meter turns amber and red |
| `ham-rig-controls-exclude` | `nil` | Controls to omit |
| `ham-rig-poll-when-hidden` | `nil` | Keep polling with no panel visible |
| `ham-frequency-format` | `dotted` | `14.074.000`, `khz` or `mhz` |
| `ham-band-default-frequencies` | digital calling | Where `b` moves on each band |
| `ham-station-grid` | `nil` | Your Maidenhead locator |
| `ham-spacewx-fetch-backend` | `auto` | `curl` subprocess, or Emacs's `url.el` |
| `ham-spacewx-panel-width` | `50` | Columns the panel lays itself out to |
| `ham-spacewx-metric-views` | per reading | Window and width of each sparkline |
| `ham-spacewx-noaa-scales` | R, S, G | Thresholds each scale's levels begin at |
| `ham-spacewx-severity-thresholds` | per reading | Where an unscaled reading turns |
| `ham-spacewx-wind-spacecraft` | `active` | Which spacecraft the wind comes from |
| `ham-spacewx-wind-speed-field` | `proton` | Proton or alpha particle speed |
| `ham-spacewx-max-quality` | `0` | Strictness of the feed's own grading |
| `ham-spacewx-stale-after` | `3600` | When a reading is called old |
| `ham-spacewx-xray-floor` | `1e-9` | Below this a flux is a gap, not a reading |
| `ham-spacewx-xray-long-band-regexp` | `0.1-0.8` | How the long band is spelled |
| `ham-spacewx-auto-refresh-interval` | `600` | Seconds between refreshes |
| `ham-spacewx-obliquity-factor` | `3.2` | M(3000)F2, turning foF2 into a MUF |
| `ham-spacewx-fof2-noon-per-sfi` | `0.04` | foF2 rise per solar flux unit |
| `ham-spacewx-f2-peak-hour` | `14.0` | Local hour of the F2 maximum |
| `ham-spacewx-bands` | 160m–6m | Bands the estimate reports on |

Polling stops when no panel is visible and nothing has subscribed.

`M-x ham-rig-show-stats` reports request count, timeouts, discarded replies,
errors, mean and maximum round-trip latency, and queue depth. Check it on a new
radio: rising latency or a queue that will not drain means
`ham-rig-fast-interval` is too short for the CAT rate.

## Following the radio from your own code

```elisp
(ham-subscribe ham-rig-topic-frequency 'my-logger
               (lambda (hz)
                 (message "now on %s" (ham-format-frequency hz))))
```

| Topic | Arguments |
| --- | --- |
| `ham-rig-topic-frequency` | frequency in Hz |
| `ham-rig-topic-mode` | mode string, passband in Hz |
| `ham-rig-topic-ptt` | `t` or `nil` |
| `ham-rig-topic-vfo` | VFO name |
| `ham-rig-topic-split` | `t` or `nil` |
| `ham-rig-topic-connection` | state symbol, detail string |

Events fire on change, not on every poll. Subscribing again with the same id
replaces the handler. Handlers run synchronously from a process filter and must
not block; one that signals an error cannot affect the others.

To read state directly: `ham-rig-frequency`, `ham-rig-current-mode`,
`ham-rig-ptt-p`, `ham-rig-connected-p`, `ham-rig-power-state`, and
`ham-rig-get` for the rest.

`ham-spacewx` publishes on `ham-spacewx-updated` with the source key and its
payload, and offers `ham-spacewx-kp`, `ham-spacewx-solar-flux`,
`ham-spacewx-sunspot-number`, `ham-spacewx-xray-flux`, `ham-spacewx-proton-flux`,
`ham-spacewx-solar-wind-speed`, `ham-spacewx-bz`, `ham-spacewx-scale-now`,
`ham-spacewx-muf` and `ham-spacewx-band-condition`.

`ham.el` also offers `ham-maidenhead-to-latlon` and `ham-latlon-to-maidenhead`
(4, 6 or 8 characters), `ham-great-circle` and `ham-grid-distance` returning
distance and bearing, `ham-band-for-frequency`, `ham-parse-frequency` and
`ham-format-frequency`.

## Credits

The propagation estimate's parameterisation is adapted from
[OpenHamClock](https://github.com/accius/openhamclock), MIT licensed.

Space weather data comes from the
[NOAA Space Weather Prediction Center](https://www.swpc.noaa.gov/), a work of
the United States government and in the public domain.

## License

GPL-3.0-or-later.
