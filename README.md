# ham
Amateur Radio support for Emacs

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
| `test/` | 90 unit tests and 19 end-to-end tests. |

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
| `f` | Set frequency. Accepts `14074`, `14.074` or `14.074.000`. |
| `m` | Set mode, completing over the modes the radio reports. |
| `b` | Move to a band, using `ham-band-default-frequencies`. |
| `v` | Toggle between VFO A and VFO B. |
| `s` | Toggle split. |
| `t` | Key or unkey the transmitter. |
| `T` | Panic unkey — drops the queue and unkeys immediately. |
| `g` | Force an immediate poll of everything. |
| `c` / `d` | Connect / disconnect. |
| `?` | Show the capabilities the radio reported. |
| `S` | Show link statistics: request count, timeouts, errors, latency, queue depth. |
| `L` | Show the diagnostic log (needs `ham-debug`). |

`M-x ham-rig-show-stats` is worth watching when you first connect a real radio.
Mean and maximum round-trip latency and queue depth tell you whether the default
0.2 second fast poll interval is sensible at your CAT rate; if latency is
climbing or the queue is not draining, raise `ham-rig-fast-interval`.

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
