# ham.el

Amateur radio support for Emacs, by K6SM.

**`ham-rig.el`** is a transceiver control panel. It shows frequency, band, mode,
passband, VFO, split and tuning step; an S-meter while receiving; and power,
ALC, compression, SWR and supply voltage and current while transmitting. A
second panel adjusts every level and switch the radio offers. It speaks to the
radio through Hamlib's `rigctld`, and publishes what it sees on an event bus so
other packages can follow the radio.

**`ham.el`** is the library underneath: an event bus, an asynchronous line
transport, Maidenhead and great-circle geodesy, a band plan, and frequency
parsing and formatting. It has no user interface.

Everything works in a terminal.

| File | Contents |
| --- | --- |
| `ham.el` | Event bus, TCP transport, geodesy, band plan. |
| `ham-rig.el` | Transceiver panel and controls panel. |
| `test/` | 181 unit tests, 27 end-to-end tests. |

## Requirements

- Emacs 29.1 or later
- [Hamlib](https://hamlib.github.io/), for `rigctld`

Developed on Emacs 29.3 and Hamlib 4.5.5, against a Yaesu FTDX10.

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
| `L` | Diagnostic log (needs `ham-debug`) |

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
  VDD  ██████████████████░░░░  14 V
  ID   ███████████████░░░░░░░  18 A
```

- **SWR** runs 1:1 at the left to infinity at the right, scaled by reflection
  coefficient. The bar is amber past 2:1 and red past 3:1
  (`ham-rig-meter-zones`).
- **Power** reads in watts, converted by the radio.
- **Compression, supply voltage and current** read in dB, volts and amps.
  Hamlib reports these as a fraction of a full scale it does not name, so
  `ham-rig-meter-units` supplies that end of the scale. **The defaults are
  estimates — calibrate them against your radio's own meters.**
- **ALC** is a bar alone; the number Hamlib reports for it has no units.

`ham-rig-tx-meters` chooses which meters appear, and only those the radio
reports are shown.

### Transmit safety

- A watchdog unkeys after `ham-rig-tx-timeout` seconds, 180 by default.
- Emacs unkeys on exit.
- Losing the link while keyed warns, and unkeys again on reconnection.
- The event bus never keys the radio. Only a direct keystroke transmits.

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

## Configuration

`M-x customize-group RET ham-rig`, and `RET ham`.

| Option | Default | Meaning |
| --- | --- | --- |
| `ham-rig-host` `ham-rig-port` | `localhost` `4532` | Where `rigctld` listens |
| `ham-rig-fast-interval` | `0.2` | Seconds between frequency, PTT and meter polls |
| `ham-rig-slow-interval` | `1.0` | Seconds between mode, VFO and split polls |
| `ham-rig-tx-timeout` | `180` | Watchdog unkey, in seconds |
| `ham-rig-tuning-steps` | 1 Hz … 1 MHz | Steps `←` and `→` cycle |
| `ham-rig-tx-meters` | power, ALC, comp, SWR, VDD, ID | Meters shown while keyed |
| `ham-rig-meter-units` | comp, VDD, ID | Full scale for normalised meters |
| `ham-rig-meter-zones` | SWR at 2 and 3 | Where a meter turns amber and red |
| `ham-rig-controls-exclude` | `nil` | Controls to omit |
| `ham-rig-poll-when-hidden` | `nil` | Keep polling with no panel visible |
| `ham-frequency-format` | `dotted` | `14.074.000`, `khz` or `mhz` |
| `ham-band-default-frequencies` | digital calling | Where `b` moves on each band |
| `ham-debug` | `nil` | Log every line to `*ham-log*` |

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

`ham.el` also offers `ham-maidenhead-to-latlon` and `ham-latlon-to-maidenhead`
(4, 6 or 8 characters), `ham-great-circle` and `ham-grid-distance` returning
distance and bearing, `ham-band-for-frequency`, `ham-parse-frequency` and
`ham-format-frequency`.

## Testing

```
make check     # compile with warnings as errors, checkdoc, both suites
make test      # 181 unit tests, no radio or rigctld needed
make live      # 27 end-to-end tests against a real rigctld
make compile   # compile only
```

`make live` starts its own `rigctld -m 1 -P RIG` on a free port and skips
itself if `rigctld` is absent.

`package-lint` is not part of `make check`, since it is MELPA-only and would
make the target need the network. Run it from a checkout of
[package-lint](https://github.com/purcell/package-lint); both files are clean.

## Status

Both files compile clean with warnings as errors and pass `checkdoc`,
`package-lint` and 208 tests.

Frequency, mode, passband, VFO, split, PTT, tuning and the meters are confirmed
against an FTDX10. The controls panel is built from that radio's reported
capabilities and tested against them.

VFO mode (`rigctld -o`) is detected and warned about, not supported. Run
`rigctld` without `-o`.

## Licence

GPL-3.0-or-later.
