# Fan Control

A native macOS fan and temperature utility for Apple Silicon, written in Swift/SwiftUI.
Menu-bar app: live sensor dashboard, per-fan manual and sensor-based control,
multi-input Smart and Cool profiles, and saved presets.

## Build and install

```bash
./build.sh                      # build, install to /Applications, restart
sudo ./install-helper.sh        # once: installs the privileged fan-write helper
```

`build.sh` installs to `/Applications` and restarts the app, so the running app
is always the build you just made. Pass `--no-install` to build without touching
the running app — needed before `swift run selftest` or `swift run analyze`,
which drive the same fans and will fight it.

## Profiles

Two built-in profiles evaluate several inputs at once and run the fan at
whichever is closest to trouble. They answer different questions, and the
difference is noise.

**Smart — cool without being noisy.** The everyday choice. What makes it smart
is not a higher threshold but an earlier, gentler one: heat that is never allowed
to accumulate never has to be removed in a hurry. A curve that starts at 70 C and
rises slowly holds a lower steady-state temperature than one that waits for 88 C
and then has to shout. Its ceilings are capped at 3800 rpm — roughly the lower
half of the fan's range — so it can run constantly without ever becoming the
loudest thing in the room, and every leg falls back to the fan minimum so it is
silent at idle.

**Cool — cool, unconditionally.** Louder, and meant to be. Every leg starts
earlier, rises faster and is allowed further than its Smart counterpart, and it
holds a 2400 rpm floor on AC even when every input is cold. Skin knees sit only
a couple of degrees above a comfortable idle, so it starts working before the
case is warm rather than after.

Cool's demand is greater than Smart's at every point in the input space. That is
not an assumption — the self-test sweeps 552 temperature/power combinations and
asserts it, with the tightest observed margin printed.

Both watch CPU, SoC, GPU, memory, power delivery, SSD, battery and both skin
surfaces. The point of the extra legs is the cases a CPU curve is structurally
blind to: a sustained multi-hundred-GB write heats the NAND with almost no
compute, and charging heats the battery with none at all. On an idle-but-charging
machine the leg actually driving the fans is usually `battery`, not `cpu`.

Every knee is set against measurement rather than taste. The governing one:
across ~380 s spanning a CPU hot-point of 98.9 C, the firmware never raised
either fan above its minimum. Apple's firmware prefers to soak and throttle, so a
knee at 70 C is already well ahead of it. `FanEngine` additionally records the
firmware's own demand while a fan is on auto and treats it as a hard lower bound,
so no profile can ever command less air than auto would have.

A thermal backstop sits above every profile: if any group exceeds its limit for
5 consecutive seconds the fans go to maximum. No profile leg reaches the fan's
true ceiling, so "fans at absolute maximum" stays an unambiguous fault signal.

## Measuring a profile

```bash
./build.sh --no-install      # keep the app stopped
swift run analyze all 180    # or: analyze smart 180
```

Runs each profile through 25% idle, 50% all-core load, 25% recovery, and reports
mean and peak fan speed, temperatures, skin temperatures and which leg was
driving. Idle numbers prove nothing about a fan curve, which is why the load
phase exists. Quit the app first; it drives the same fans.

## Running the checks

```bash
swift run selftest
```

Quit the app first. The self-test drives the fans directly, so with the app also
running you get two writers fighting over the same SMC keys and confusing
failures that look like the assertion loop breaking. The same applies to any
other fan utility — only one thing can own the fans at a time.

## How it is put together

| Component | Role |
|---|---|
| `Sources/SMCKitCore` | The AppleSMC user-client ABI: key enumeration, typed read/write, codecs for `flt`/`sp78`/`fpe2`/`fp88`/`ui8`…`ui32`/`si8`/`si16`/`flag` |
| `Sources/FanControlKit` | Sensor catalog and grouping, fan modes and curve maths, preset storage, settings, helper client |
| `Sources/smcwrite` | The only code that runs as root. Writes fan keys and nothing else |
| `Sources/FanControlApp` | SwiftUI menu-bar app, main window, fan editor, preferences |
| `Sources/analyze` | Profile analyser: drives a profile through idle/load/recover and reports what it actually did |
| `Sources/selftest` | Runnable checks: curve and multi-leg maths, profile invariants, fake-sensor rejection, plus live hardware hold and profile tests |

Reading sensors needs no privilege. Only writing a fan target does, so that one
operation lives in a separate ~110 KB setuid-root binary.

## Three things that are easy to get wrong

**1. A manual fan target is not self-sustaining, and not self-clearing either.**

Set a target once and it can silently stop applying: at mid-range targets the
SMC hands the fan back to the firmware roughly two seconds after the last
write, while the UI still reports manual control. The app therefore re-asserts
every managed fan every 0.5 s (`FanEngine.assertInterval`), batched into a
single privileged call per tick.

Measured on M4 Pro, one write of 2600 rpm at t=0: still `MANUAL` at t=1 s,
released by t=2 s, firmware target restored by t=3 s. This is time-based, not
connection-scoped — holding the writing SMC connection open across the timeout
changes nothing — so a one-shot helper process suffices and no resident root
daemon is needed.

But the reverse is **not** guaranteed. A fan commanded to its maximum on a hot
machine has been observed holding `MANUAL` indefinitely with no writer alive at
all (>20 s after the controlling process was killed). Never assume an abandoned
fan will free itself. The app releases fans explicitly:

- on Quit, via `applicationWillTerminate`
- on `SIGTERM`/`SIGINT`/`SIGHUP`, via signal sources — AppKit does not run the
  delegate for these, so without them `pkill` leaves fans pinned
- on the next launch, by releasing any fan the hardware reports as manual while
  its configured mode is auto, which recovers from a `SIGKILL`

`SIGKILL` cannot be caught, so it can still strand fans until the app is
relaunched. `sudo /usr/local/libexec/fancontrol-smcwrite auto-all` clears it
from a terminal.

**2. Published sensor labels can be wrong; measure instead.**

`Ts0P`/`Ts1P` are widely published as "SSD Controller". They are not. Under 88 s
of sustained NAND writes that moved the real NAND sensor +3.4 C they moved
+0.03 C, and under a 120 s all-core burn that moved the die +23.7 C they moved
+0.37 C. They respond to neither, only to accumulated whole-machine energy, with
94% monotonic behaviour and a still-rising curve 150 s after load ended. They are
top-case skin sensors, and they are what the Cool profile binds to.

Two corollaries that bit an earlier version of this catalogue: the `Ta*` family
is NOT room air — its hottest member peaked at 59 C and rose 12 C under load, so
binding "keep the case cool" to an "ambient" group tracked the SoC instead. And
six `Ta*` keys report exactly 9.10 forever; a power-gated core cluster can report
exactly 40.00 across fifty keys at once. Both sit inside any sane temperature
band. They are rejected structurally — bit-identical agreement across siblings on
a round number — rather than by a key blocklist, so it keeps working on hardware
nobody has characterised.

**3. Core sensors go dead when clusters power-gate.**
Of 322 `T*` keys, ~244 read plausibly at any moment, but *which* ones changes:
idle P-core clusters report near zero. Binding a fan curve to a single raw core
key gives you garbage the moment that core parks. Bind to an aggregate
("CPU (hottest core)") — the max over currently-live sensors in a group.
Readings outside 1–125 °C are treated as not reporting.

A sensor-based curve whose sensor cannot be read commands **maximum** RPM
rather than minimum: failing loud is the only safe direction for a thermal
control loop.

## Security note

The helper is setuid root. Its argument parser accepts a fan index and an RPM
value only, clamped to that fan's own hardware min/max read back from the SMC
at write time. It cannot be used to write arbitrary SMC keys, so a compromised
or impersonating local process gains nothing beyond changing fan speed.

(For comparison, the commercial app this was modelled on exposes a general
"write any SMC key" operation over XPC from its root helper.)

## Not implemented

- Localization (the original ships ~40 languages; this is English only)
- SMART temperatures for external/USB drives — internal SSD temps come from
  the SMC and are shown
- Update checker, licensing, uninstaller
