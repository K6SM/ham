# ham.el

Amateur radio support for Emacs, by K6SM.

`ham-rig.el` gives you a transceiver control panel in a buffer: frequency, mode,
passband, VFO, split, an S-meter while receiving, and ALC and SWR while
transmitting. It reads and controls the radio through Hamlib's `rigctld`, and it
publishes what it sees on an event bus so other packages can follow the radio
without knowing anything about Hamlib.

`ham.el` is the library underneath. It has no user interface and is not
interesting on its own unless you are writing something against it.

Everything here works in a terminal. None of it requires a graphical Emacs.

| File | What it is |
| --- | --- |
| `ham.el` | Base library: event bus, async TCP transport, geodesy, band plan. |
| `ham-rig.el` | Transceiver control panel, speaking to `rigctld`. |
| `test/` | 147 unit tests and 27 end-to-end tests. |

The prefix is `ham-`. `ham.el` owns the bare `ham-` prefix and `ham-rig.el` owns
`ham-rig-`, following the `org.el` / `org-agenda.el` pattern. Further packages
are planned on the same base: space weather, DX cluster spots, a greyline map,
CW sending, and contest logging.

## Requirements

- Emacs 29.1 or later
- [Hamlib](https://hamlib.github.io/) — specifically the `rigctld` daemon

Developed against Emacs 29.3 and Hamlib 4.5.5.

## Installation

Put `ham.el` and `ham-rig.el` on your load path and require the latter, which
pulls in the former:

```elisp
(add-to-list 'load-path "~/.emacs.d/lisp/ham/")
(require 'ham-rig)
```

## Running rigctld

Start one `rigctld` against your radio and leave it running:

```
rigctld -m 1042 -r /dev/ttyUSB0 -s 38400
```

`rigctl -l` lists model numbers. `1042` is the FTDX10; use your own.

**Start exactly one `rigctld` and point everything at it.** It owns the serial
port, and every other program — this package, WSJT-X, fldigi, your logger —
connects to the daemon rather than to the radio. Opening the rig's serial port
directly from Emacs would lock out every other program on the station.

To try the panel with no radio attached, Hamlib's dummy rig works fine:

```
rigctld -m 1
```

The dummy declares `PTT type: None` and refuses to key, so add `-P RIG` if you
want to exercise the transmit path against it.

If you run [wfview](https://wfview.org/), its `rigctld` emulation works too:
point `ham-rig-port` at wfview and you have LAN remote operation, with audio
handled by a program qualified to handle audio. Nothing here changes.

## Usage

`M-x ham-rig` opens the panel and connects if it is not already connected.

```
  localhost:4532   connected   FTDX10

  14.074.000   20m

  VFO VFOA    MODE USB       BW 2400 Hz   SPLIT off

  RX  ████▏░░░░░░░░░░░░░░░░  S3
```

Keys in the panel:

| Key | Action |
| --- | --- |
| `↑` / `↓` | Tune up / down one step. |
| `M-↑` / `M-↓` | Tune ten steps. `PgUp` / `PgDn` do the same. |
| `←` / `→` | Smaller / larger tuning step. |
| `.` | Pick a tuning step by name. |
| `f` | Set frequency. Accepts `14074`, `14.074` or `14.074.000`. |
| `m` | Set mode, completing over the modes the radio reports. |
| `b` | Move to a band, using `ham-band-default-frequencies`. |
| `v` | Toggle between VFO A and VFO B. |
| `s` | Toggle split. |
| `t` | Key or unkey the transmitter. |
| `T` | Panic unkey — drops the queue and unkeys immediately. |
| `g` | Force an immediate poll of everything. |
| `c` / `d` | Connect / disconnect. |
| `C` | Open the controls panel. |
| `?` | Show the capabilities the radio reported. |
| `S` | Show link statistics: request count, timeouts, errors, latency, queue depth. |
| `L` | Show the diagnostic log (needs `ham-debug`). |

### Tuning

The arrow keys work like a tuning knob with a step button. `↑` and `↓` move by
the current step, `←` and `→` change what that step is, and the panel shows it
next to the band. Steps come from `ham-rig-tuning-steps` and run from 1 Hz to
1 MHz by default; `ham-rig-default-tuning-step` picks the one you start on.

The readout moves the instant you press a key rather than waiting for the next
poll, so holding a key feels continuous. The poll that follows replaces the
displayed value with whatever the radio actually settled on, which is what
corrects for a rig that quantises to its own step. Only the most recent
frequency is ever sent: a held key does not queue up hundreds of sets for the
link to replay after you stop.

`M-x ham-rig-show-stats` is worth watching when you first connect a real radio.
Mean and maximum round-trip latency and queue depth tell you whether the default
0.2 second fast poll interval is sensible at your CAT rate; if latency is
climbing or the queue is not draining, raise `ham-rig-fast-interval`.

## Controls

`C` in the panel, or `M-x ham-rig-controls`, opens a list of everything the
radio can adjust: IF shift, notch, TX power, noise reduction, noise blanker,
CW speed, mic gain, VOX gain and delay, monitor level, compression, break-in
delay, CW pitch, preamp, attenuator, squelch, AF and RF gain, and switches for
the tuner, VOX, ANF, APF, manual notch, RIT and the rest.

| Key | Action |
| --- | --- |
| `←` / `→` | Adjust the control on this line, or toggle it if it is a switch. |
| `M-←` / `M-→` | Adjust by ten steps. `-` and `+` work too. |
| `RET` / `SPC` | Toggle a switch, or prompt for a level. |
| `=` | Type an exact value. |
| `g` | Re-read everything. |

Nothing in that list is written down anywhere in this package. It is built from
what the radio reports through `\dump_caps`, which describes each level as
`NAME(min..max/step)` — so the ranges, the increments and the number of decimal
places all come from the rig, and a different radio produces a different panel
with no code change. Read-only meters are recognised by appearing under
Hamlib's `Get level` but not `Set level`, and are kept out of a panel whose
purpose is changing things.

Two consequences worth knowing:

- **Hamlib normalises many levels to 0..1** rather than the radio's own units.
  TX power and mic gain read as fractions, not watts or the number on the front
  panel.
- **A control Hamlib describes as `0..0/0` is omitted**, because there is
  nothing to adjust. On the FTDX10 that is AGC and METER: the radio has an AGC,
  but it takes named settings rather than a number and Hamlib does not describe
  it as a range here.

Roofing filter and contour are not offered because the FTDX10 backend does not
expose them as either a level or a function. Reaching them would mean sending
raw CAT, which is specific to one radio and is a deliberate departure from
everything else here.

Controls are re-read a few at a time rather than all at once — a rig with forty
of them would otherwise need forty extra requests a second on top of the
frequency and meter polls, which a serial link cannot carry. Opening the panel
reads everything once so it fills immediately; after that the round robin keeps
it current, and any control you change is re-read straight away.

## Transmit safety

This package can key your transmitter, so read this part.

- A watchdog unkeys after `ham-rig-tx-timeout` seconds (default 180). Setting it
  to `nil` disables it, which you should not do.
- Emacs unkeys on exit through `kill-emacs-hook`.
- If the link drops while keyed, you get a loud warning, and the unkey is sent
  again as soon as the connection comes back.
- The event bus never keys the radio. A spot click may retune it; only a direct
  user action may transmit. A malformed line from a cluster can never become an
  unintended transmission.

There is one gap that cannot be closed from Emacs: CAT has no dead-man
behaviour, so if the control link dies while the radio is keyed, nothing
software-side can unkey it. **Enable your transceiver's own TX timeout timer.**
That is the real backstop; everything above is a convenience on top of it.

## Configuration

`M-x customize-group RET ham-rig` and `M-x customize-group RET ham`. The options
most worth knowing:

| Option | Default | Meaning |
| --- | --- | --- |
| `ham-rig-host` / `ham-rig-port` | `localhost` / `4532` | Where `rigctld` is listening. |
| `ham-rig-fast-interval` | `0.2` | Seconds between frequency, PTT and S-meter polls. |
| `ham-rig-slow-interval` | `1.0` | Seconds between mode, VFO, split, SWR and ALC polls. |
| `ham-rig-tx-timeout` | `180` | Watchdog unkey, in seconds. |
| `ham-rig-poll-when-hidden` | `nil` | Keep polling with no panel visible and nothing subscribed. |
| `ham-rig-controls-poll-batch` | `4` | Controls re-read per slow poll. |
| `ham-rig-controls-exclude` | `nil` | Control names to leave out of the panel. |
| `ham-frequency-format` | `dotted` | `14.074.000`, or `khz`, or `mhz`. |
| `ham-band-default-frequencies` | digital calling frequencies | Where `b` takes you on each band. |
| `ham-debug` | `nil` | Log every line in and out to `*ham-log*`. |

By default the package stops polling when no panel is visible and no other
package has subscribed, so a rig nobody is looking at costs no serial bandwidth.

## Following the radio from your own code

`ham-rig` publishes on an event bus in `ham.el`. Subscribe with a topic, an id
of your choosing, and a function; subscribing again with the same id replaces
the previous function, so re-evaluating your config is harmless.

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

Events fire only when a value actually changes, not on every poll. Handlers must
not block: they are called synchronously from a process filter. A handler that
signals an error is contained and cannot break the bus or the other subscribers.

To read current state rather than react to changes:
`ham-rig-frequency`, `ham-rig-current-mode`, `ham-rig-ptt-p`,
`ham-rig-connected-p`, and `(ham-rig-get 'passband)` and friends for the rest.

`ham.el` also carries utilities worth reusing: `ham-maidenhead-to-latlon` and
`ham-latlon-to-maidenhead` (4, 6 or 8 characters), `ham-great-circle` and
`ham-grid-distance` returning distance and bearing, `ham-band-for-frequency`,
and `ham-parse-frequency` / `ham-format-frequency`.

## Design notes

Worth knowing if you plan to change anything:

- **Emacs is the control surface and the state store, never the signal path.**
  Anything touching audio samples or needing sub-10ms determinism belongs in an
  external process.
- **No hardcoded rig model.** Capabilities come from `\dump_caps` at connect
  time, so an FTDX10 and an IC-7300 are the same code path.
- **Extended response mode.** Commands are prefixed with `+` so replies are
  self-describing and RPRT-terminated, which prevents the failure where one
  dropped reply misattributes every later value.
- **One request in flight, behind a bounded queue.** Poll requests are dropped
  under backpressure; user requests never are.
- **Polling is decoupled from redisplay.** The panel repaints only when
  something changed, coalesced through an idle timer.
- All I/O is asynchronous. The one place this package blocks is unkeying during
  `kill-emacs-hook`, which is the correct trade.

Three details of Hamlib's wire format are worth knowing before you touch the
parser, because all three are easy to get wrong and fail silently:

- Levels answer with a bare number on a line of their own. There is no
  `Level Value:` label, so `l STRENGTH`, `l SWR` and `l ALC` are read
  positionally.
- `\chk_vfo` is not terminated by `RPRT`. It needs its own terminator, or it
  holds the single in-flight slot until the request times out.
- Hamlib does not echo back the VFO name that was set. Ask for `VFOB` and a rig
  with two receivers reports `Sub`, so VFO identity is compared by side.

## Testing

```
make check     # byte-compile with warnings as errors, checkdoc, then both suites
make test      # 147 unit tests, no radio and no rigctld needed
make live      # 27 end-to-end tests against a real rigctld
make compile   # byte-compile only
```

`make live` starts its own `rigctld -m 1 -P RIG` on a free port and drives it
over a real socket, so it needs Hamlib installed but no radio. It skips itself
if `rigctld` is not on `PATH`. `-P RIG` is required because the dummy rig
otherwise refuses to key, which would leave the transmit path untested.

Batch Emacs has no command loop, so the poll timers never fire on their own; the
live harness dispatches due timers by hand.

## Status

Both files byte-compile cleanly with warnings as errors, pass `checkdoc` and
`package-lint`, and pass 174 tests including end-to-end tests against a real
`rigctld`.

Read and control of frequency, mode, passband, VFO, split, PTT and the meters
is confirmed working against an FTDX10. The controls panel is built from that
radio's reported capabilities and tested against them, but has so far been
exercised against Hamlib's dummy backend rather than against the radio itself.

VFO mode (`rigctld -o`) is detected and warned about, but not supported:
commands would need to carry an explicit VFO argument. Run `rigctld` without
`-o`.

## Licence

GPL-3.0-or-later, matching Emacs.
