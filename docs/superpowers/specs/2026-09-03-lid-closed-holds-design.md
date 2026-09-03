# teainate — lid-closed holds

**Date:** 2026-09-03
**Status:** Approved

## Purpose

Let a hold survive closing the MacBook lid, on battery, with no external display.
The driving case is the same as before: a long Claude Code session or build that
must finish while the laptop is shut and carried somewhere.

`caffeinate` cannot do this. A power assertion only blocks *idle* sleep; closing
the lid is an explicit sleep request that no assertion overrides. The 2026-07-26
spec's claim that `caffeinate` keeps an Apple Silicon MacBook awake lid-closed
was wrong and is superseded here.

What does work is the kernel's `SleepDisabled` flag, set with
`pmset -a disablesleep 1`. It is a veto that survives the lid-close event.
Confirmed firsthand on Apple Silicon under macOS 26.3 by the Sleepless project;
this feature must still be verified by hand on the target machine before it is
called done (see Testing).

The flag has none of `caffeinate`'s safety properties. It is global, it needs
root, and it never clears itself. A MacBook shut in a bag with the flag set runs
hot and drains flat. Every part of this design exists to give the flag the
properties a `caffeinate` child process has for free: it lives exactly as long as
one hold, and it cannot outlive a crash.

## Goals

- A lid-closed hold is an ordinary hold with one more modifier, from the menu,
  the CLI, or the Claude Code skill.
- The flag is set only while a lid-closed hold is live, and is cleared by the
  next teainate read after any crash.
- A battery floor ends the hold before the battery drains.
- Everything works with the menu bar app closed, including over SSH.
- Nothing runs as root except `pmset -a disablesleep 0|1`, and nothing else can
  be run through the grant.

## Non-goals

- Low Power Mode step-aside. Overlaps almost entirely with the floor, and adds a
  second thing to poll. Deferred to `docs/followups.md`.
- Thermal monitoring. The README will carry the warning.
- Clamshell mode with an external display. Apple already handles that.

## Decisions taken during design

| Question | Decision |
| --- | --- |
| Modifier, separate switch, or automatic? | **Modifier** on a hold. The veto lives and dies with the hold, so existing expiry paths define when it clears. |
| Indefinite lid-closed holds? | **Menu only.** The CLI requires `--for`, `--session`, or `--until-pid`. The floor is the limit for a human at the menu. |
| Who sets the battery floor? | **The menu**, persisted in a settings file. The CLI and skill read it and cannot override it. |
| How to get root? | **One-time sudoers grant** from the menu, two literal commands. `sudo -n` afterwards. |
| Who enforces the rails with the app closed? | **A watcher child process** owned by the hold, in place of a bare `caffeinate`. |

## Architecture

### The watcher

For an ordinary hold the recorded PID is a `caffeinate` process and the OS ends
it. For a lid-closed hold the recorded PID is a **watcher**: the `teainate`
binary run as a hidden subcommand. The watcher owns one `caffeinate` child,
polls the rails, and clears the flag on its way out.

```
teainate lid-watch --id h_3f2a --floor 15 --state-file <path> --caffeinate "-i -t 7200" [--watch-pid 6707] [--ac-only] [--label <label>]
```

Every existing invariant still holds. The hold's PID is a real child that was
spawned before it was recorded. Reconciliation drops it when it dies. Release is
SIGTERM to that PID. The single model change is that reconciliation must accept
the process name this hold kind expects: `caffeinate` for ordinary holds,
`teainate` for lid-closed ones, both read from `ucomm`.

The app locates the binary at the bundled CLI path it already uses for skill
installation (`Teainate.app/Contents/MacOS/teainate`). The CLI uses its own
executable path.

**The caffeinate child** is spawned as `caffeinate -i [-d] [-t N] -w <watcher pid>`.
Tying it to the watcher's own PID means that if the watcher dies for any reason,
SIGKILL included, its `caffeinate` releases by itself. This path can never leave
an orphan `caffeinate`. The user's watched PID for a session hold cannot share
that `-w`, so the watcher polls it instead. (`-t` and `-w` combine; only the
utility form of `caffeinate` ignores them. The integration tests verify this.)

**The loop** runs every 30 seconds and exits on the first check that fails:

1. The `caffeinate` child is still alive. This covers timer expiry.
2. The user's watched PID, if any, is still alive.
3. Power. On battery: the percentage is above the floor. With `--ac-only`: the
   power source is still AC, because `caffeinate -s` going inactive on battery
   would otherwise be silently defeated by the flag. On AC without `--ac-only`
   the floor does not apply. A Mac reporting no battery skips the check.

A parse failure of `pmset -g batt` counts as unknown, is logged once, and does
not end the hold. Ending holds on a format change would make the feature
unreliable, not safer.

**Exit**, on every path including SIGTERM from a release: terminate the
`caffeinate` child; take the store lock; remove this hold's record; clear the
flag and the ownership marker only if no other live lid-closed hold remains.
Two concurrent lid-closed holds share one flag and the last one out clears it.
The watcher appends one line to `lid-watch.log` beside the state file, for
example `h_3f2a ended: battery 14% at floor 15%`. Because the hold's record is
removed on exit, the reason is kept in a top-level `last_ended` entry in state
(id, label, reason, timestamp) so `status` can show why the most recent
lid-closed hold ended on its own.

### Setting the flag

`on` for a lid-closed hold does the privileged step itself, in this order:

1. Run every pre-flight check (below). Any failure: nothing has been touched.
2. Persist the ownership marker (teainate may have set the flag).
3. `sudo -n /usr/bin/pmset -a disablesleep 1`.
4. Spawn the watcher.
5. Record the hold.

Step 2 comes before the privileged call so a crash between here and step 5
(SIGINT during sudo, spawn, or `ps`) still leaves the marker set — the next
read then treats the flag as teainate's to check on, rather than something
set outside teainate. If step 3, 4, or 5 fails, `on` clears the flag before
rethrowing. This extends the existing rule — spawn before recording, clean up
if recording fails — to the flag. If clearing also fails, the error says so
explicitly: that is the one outcome that leaves the Mac unable to sleep.

### Ownership marker and orphan cleanup

`holds.json` gains one top-level boolean, `lid_flag_owned`, true while
teainate may have set the flag, and one nullable timestamp,
`lid_flag_pending_since`, set alongside it while an `on` call for a lid-closed
hold is still in flight (step 2 above). On every read, after reconciliation:

- Marker true, no live lid-closed hold, and the pending stamp is either unset
  or older than a 60-second grace period: the flag was orphaned by a
  SIGKILLed watcher or a crash. Clear the flag (needs the grant) and the
  marker.
- Marker true, no live lid-closed hold, and the pending stamp is within the
  grace period: an `on` call elsewhere (another process, or the app's
  periodic refresh) is still setting the flag up. Touch nothing and let it
  finish — clearing here would otherwise race that `on` call, which sets the
  marker before the privileged `pmset` call and the watcher spawn, both of
  which happen with the state file's lock released.
- Marker true, no live lid-closed hold, flag already clear: drop the marker
  for free, without a `pmset`/`sudo` call — this is what a reboot (or a failed
  `sudo -n` call that never actually set the flag) looks like on the next read.
- Marker false, flag set: something outside teainate set it. Report it in
  `status`. Never touch it — the same rule as untracked `caffeinate` processes.

Reboot clears the flag regardless.

### Privilege

Two Core protocols, faked in unit tests like the spawner:

- `SleepFlagControlling` — `set()`, `clear()` via `sudo -n`; `isSet()` via
  `pmset -g`, unprivileged.
- `PrivilegeGranting` — `isGranted()`, `grant()`, `revoke()`. `isGranted()` is a
  read of the sudoers file's existence and content, never a `sudo -n` probe, so
  `status` stays cheap and can never prompt.

The only privileged code in the app target is the one
`do shell script … with administrator privileges` call that writes the grant.
It shows the standard macOS admin dialog, then:

1. Writes `/etc/sudoers.d/teainate-<username>` (mode 0440) containing exactly:
   ```
   <username> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
   ```
2. Validates it with `visudo -c -f`, deleting it on failure.

`<username>` is looked up at grant time, never taken from input. sudoers matches
arguments literally, so nothing else can be run through the rule. The per-user
file name means two users on one Mac cannot overwrite each other's grant. Revoke
is the same dialog deleting the file.

### Settings file

`settings.json` beside `holds.json`, one key for now:

```json
{ "battery_floor": 15 }
```

Valid 5–50, default 15. The menu writes it. `on` reads it and copies the value
into the hold record, so a change never alters a running hold, matching how the
other modifiers apply only to the next activation. A missing file yields 15
silently — that is every user's starting state, before the menu has ever written
one. An empty file, invalid JSON, or an out-of-range value yields 15 plus a
warning in `status` — never a crash, never a riskier value.

### Hold record

`Hold` and `HoldOptions` gain:

| Field | JSON key | Default when absent |
| --- | --- | --- |
| `lidClosed: Bool` | `lid_closed` | `false` |
| `batteryFloor: Int?` | `battery_floor` | `nil` |

`caffeinatePID` keeps its name; for a lid-closed hold it is the watcher's PID.

The state file changes from a bare array to an object:

```json
{
  "holds": [ … ],
  "lid_flag_owned": false,
  "last_ended": { "id": "h_3f2a", "label": "build", "reason": "battery 14% at floor 15%", "at": "…" }
}
```

The loader accepts both shapes. Existing files decode unchanged.

## Pre-flight checks

Run by `on` before anything is set or spawned. Each is a distinct, loud error:

| Condition | Result |
| --- | --- |
| Grant missing | Refused: *enable lid-closed holds from the Teainate menu first*. |
| Grant present but `sudo -n` fails | Refused, with the sudo error. `status` shows *grant present but not working*. |
| CLI with no `--for`, `--session`, or `--until-pid` | Refused: *indefinite lid-closed holds are menu-only*. |
| CLI `--for` above 8 hours | Refused, not clamped. One named constant. |
| On battery at or below the floor | Refused: *battery at 12%, below the 15% floor*. |
| Flag set, marker false | Refused: *sleep is already disabled outside teainate; an ordinary hold will work with the lid closed until that is cleared*. Proceeding would mean clearing someone else's flag on exit, or a hold whose floor protects nobody. |
| Flag set, marker true | Allowed. Another lid-closed hold is live; this one joins it. |
| No battery present | Allowed; floor skipped. |
| Revoke grant while a lid-closed hold is live | Refused from the menu. |

## Menu bar UI

A third modifier under the existing two:

```
Only while plugged in
Keep display on
Allow closing the lid              (greyed, "enable below", until granted)
```

When checked, every duration item and "Keep awake indefinitely" produce a
lid-closed hold. Live lid-closed holds render as
`build — 42 min left, lid ok, off at 15%`.

Below the skill installer, a new group:

```
Enable lid-closed holds…           →  Lid-closed holds enabled ✓  (disabled) once granted
Battery floor: 15%                 ▸  5 / 10 / 15 / 20 / 30 / 40 / 50
Disable lid-closed holds…             (greyed while a lid-closed hold is live)
```

The header shows the cannot-clear warning (below) when it applies. When a
lid-closed hold ends on its own while the app is running, the app posts a
notification with the recorded reason.

All show/enable/check decisions stay in `MenuModel.swift`.

## CLI

```
teainate on --lid-closed --for 2h [--label …]
teainate on --lid-closed --session
teainate on --lid-closed --until-pid 6707
```

No `--battery-floor` flag. `status` shows the floor on each lid-closed hold,
whether the grant is present, the most recent `last_ended` reason, and a
warning if the flag is set outside teainate. `status --json` gains per hold
`lid_closed` and `battery_floor`, and a top-level block:

```json
"lid_closed": {
  "enabled": true, "flag_set": true, "flag_set_by": "teainate",
  "last_ended": { "id": "h_3f2a", "label": "build", "reason": "…", "at": "…" }
}
```

`flag_set_by` is `"teainate"`, `"other"`, or `null`.

`teainate lid-watch` is hidden from `--help`. It is not for humans.

## Claude Code skill

One short new section. Use `--lid-closed` only when the user has said they will
close the laptop or take it somewhere. Always pair it with `--session` or
`--for`. If it fails because it is not enabled, tell the user to enable it from
the Teainate menu; do not try to work around it. The skill never mentions the
floor.

## Error handling

All failures are non-zero exit plus stderr, via `FriendlyError`, per the existing
convention. The pre-flight table above covers refusals. Two runtime cases:

- **Orphan cleanup cannot clear the flag** because the grant was revoked after a
  crash. `status` and the menu header show: *sleep-disabled flag is set and
  teainate cannot clear it; run `sudo pmset -a disablesleep 0`*. This is the one
  state where teainate tells the user to run a command, because nothing else can
  fix it.
- **Floor hit.** The hold ends, the reason is recorded, the app notifies if
  running. The CLI has no way to notify, which is why the reason persists in
  state.
- **Grant present but sudo refuses it** (revoked entitlement, corrupted sudoers
  file, and the like) surfaces only when `on` actually tries the privileged step
  and `sudo -n` fails — not in `status`, which reads the sudoers file's presence
  and never probes `sudo`, so it stays cheap and can never prompt. See
  `docs/followups.md` for the deferred `status` line.

## Testing

CLAUDE.md is explicit: a green suite is not evidence that anything involving
`ps` or `pmset` works. This feature adds a third such boundary, `sudo`.

**Hermetic unit tests** (`TeainateCoreTests`), with `SleepFlagControlling`,
`PrivilegeGranting`, and a `BatteryReading` protocol all faked:

- Watcher argument construction, including `-w <own pid>` on the child.
- Every pre-flight refusal, each with its distinct error, no spawn, no flag set.
- `on` ordering: set, spawn, record. Spawn failure clears the flag. Record
  failure terminates the watcher and clears the flag. Clear failure is reported.
- Last-watcher-out: two lid-closed holds; first exit leaves the flag, second
  clears it.
- Orphan reconciliation: marker true with no live lid-closed hold clears flag and
  marker. Marker false with the flag set: untouched, reported.
- Battery parsing over real captured `pmset -g batt` output: AC, battery,
  charging, no battery. Fixtures include floor − 1 and floor + 1, never the floor
  itself, so an off-by-one cannot hide.
- Watcher loop decisions as a pure function of (child alive, watched alive,
  power source, percent, floor, ac-only) → continue / end(reason).
- Menu model: modifier greyed without the grant; disable greyed with a live
  hold; floor submenu marks the current value; header shows the cannot-clear
  warning.
- Settings decoding: missing file → 15 silently; empty file, invalid JSON, and
  out-of-range each → 15 plus a warning.
- State decoding: bare-array and object shapes both load.

**Real-process tests** (`TeainateIntegrationTests`), short `-t` backstops and
`defer` cleanup throughout, never touching the real flag:

- A real watcher process, spawned with a flag controller that is faked, snapshot
  with the real `PSProcessSnapshotter`, kept by reconciliation, terminated, and
  its `caffeinate` child confirmed gone. This is the one shape of test that
  would catch a `ucomm` mismatch on the watcher's name.
- `caffeinate -i -t 3 -w <pid>` released by the timer while the watched process
  lives, and by the process exiting while the timer lives. The no-orphan design
  rests on this.
- The watcher's SIGTERM path ends the child and writes the reason log.

**Manual checklist**, required before this ships. Nothing here can be automated:
setting the real flag needs the grant and closing the lid needs a human.

1. Grant from the menu. Confirm `pmset -g | grep SleepDisabled` is 0 or absent.
2. On battery above the floor, take a 10-minute lid-closed hold. Confirm
   `SleepDisabled 1`.
3. Run `while sleep 60; do date >> ~/awake.log; done`, close the lid for ten
   minutes, open it. The log must have ten entries.
4. Wait for expiry. Confirm the flag is gone and `status` is empty.
5. Set the floor above the current battery level. Take a lid-closed hold on
   battery. It must be refused. Plug in, take it, unplug: it must end at the next
   poll with the reason recorded.
6. `kill -9` a watcher. Run `teainate status`. Flag and marker must be gone.
7. Revoke from the menu. Confirm the sudoers file is gone and `on --lid-closed`
   is refused.

## Open questions

None. Low Power Mode step-aside and a per-hold floor override are recorded in
`docs/followups.md` as deliberately deferred.
