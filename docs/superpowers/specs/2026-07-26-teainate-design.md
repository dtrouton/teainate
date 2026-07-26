# teainate — design

**Date:** 2026-07-26
**Status:** Approved

## Purpose

A macOS menu bar app for controlling sleep prevention, plus a Claude Code skill
exposing the same control. The driving use case is keeping the Mac awake so long
Claude Code sessions can run to completion, typically with the screen off.

## Goals

- Set and release sleep-prevention holds from the menu bar.
- See what is currently keeping the Mac awake — including holds teainate did not
  create.
- Give Claude Code full read/write control through a skill, working whether or
  not the menu bar app is running.

## Non-goals

- Scheduling ("keep awake every weekday 9–5").
- Syncing state across machines.
- Replacing `pmset` for general power management.

## Background

`caffeinate(8)` already provides every primitive we need:

| Flag | Effect |
| --- | --- |
| `-i` | Prevent idle system sleep, on any power source. |
| `-s` | Prevent system sleep, **valid only on AC power**. |
| `-d` | Prevent display sleep. |
| `-t <secs>` | Release the assertion after a timeout. |
| `-w <pid>` | Release the assertion when that process exits. |

teainate does not reimplement these. It spawns `caffeinate` with the right flags
and keeps a record of what it spawned.

Two findings from the target machine (Apple M4, macOS 26.5) shaped the design:

1. Every `caffeinate` assertion is anonymous — `pmset -g assertions` reports all
   of them as `"caffeinate command-line tool"`. There is no way to distinguish
   our holds from another tool's by inspecting the system. **We must keep our own
   record of the PIDs we spawn.**
2. Multiple concurrent holds are normal. The machine already had two live
   `caffeinate -i -t 300` processes from Claude Code sessions. A single global
   on/off switch would stomp them.

An earlier draft of this design claimed `caffeinate` cannot keep a MacBook awake
with the lid closed. That is false on Apple Silicon and has been removed.

## Architecture

One SwiftPM package, three targets:

- **`TeainateCore`** (library) — hold model, state persistence, `caffeinate`
  spawning, `pmset` parsing, skill installation. No UI, no argument parsing.
- **`teainate`** (executable) — argument parsing over Core.
- **`Teainate.app`** — AppKit `NSStatusItem`, `LSUIElement=true`, over Core.

No Xcode project. `swift build` produces both binaries; a script assembles the
`.app` bundle.

### Why a file, not a daemon

State lives in `~/Library/Application Support/teainate/holds.json`. The CLI and
the app are both plain clients of that file.

The alternative — app owns `IOPMAssertion`s, CLI talks to it over IPC — was
rejected because it makes Claude Code depend on the app running, which breaks the
SSH and headless cases.

A pure-`pmset` stateless design was also rejected: it cannot carry metadata
(label, source, expiry) and, per finding 1, cannot identify our own holds.

### State reconciliation

A hold record can outlive its process (crash, `kill -9`). Every read therefore
reconciles before reporting: `kill(pid, 0)` each recorded PID, drop the dead
entries, rewrite the file. A stale entry can exist but never survives a read.

Writes take an `flock` on the state file so the app and CLI cannot interleave a
read-modify-write.

### Hold record

```json
{
  "id": "h_3f2a",
  "kind": "forever | timer | process",
  "label": "2h timer",
  "source": "menu | cli | claude",
  "caffeinate_pid": 6707,
  "flags": ["-i", "-t", "7200"],
  "started_at": "2026-07-26T10:07:31Z",
  "expires_at": "2026-07-26T12:07:31Z",
  "watched_pid": null,
  "display": false,
  "ac_only": false
}
```

## Mode model

Three orthogonal axes, mapping directly onto `caffeinate` flags:

| Axis | Options | Flag |
| --- | --- | --- |
| Duration | forever / timed / until a process exits | — / `-t <secs>` / `-w <pid>` |
| Power policy | always / only while plugged in | `-i` / `-s` |
| Display | screen may sleep / keep screen on | — / add `-d` |

The axes compose freely: "2 hours, but give up if I unplug" is `-s -t 7200`.

"Only while plugged in" requires no power monitoring on our side — `-s` is
inactive on battery by definition, so the Mac resumes normal sleep behaviour on
unplug and the assertion reactivates on replug.

**Defaults: forever, always, screen may sleep** (`-i`) — matching the primary use
case of long Claude Code runs with the screen off.

## Menu bar UI

Teacup icon: empty when idle, steaming when any hold is active.

```
● Awake — 42 min left
─────────────────────────────
Keep awake for  ▸   15m / 30m / 1h / 2h / 4h
Keep awake indefinitely
─────────────────────────────
☑ Only while plugged in
☐ Keep display on
─────────────────────────────
Active holds
  ⏱  2h timer — 42 min left        ✕
  ⧗  Claude Code session (pid 6707) ✕
─────────────────────────────
Also keeping this Mac awake
  Claude · powerd
─────────────────────────────
Install Claude Code skill…
Turn off all
Quit
```

The checkbox modifiers apply to the *next* activation; they do not retroactively
change a running hold.

The "Also keeping this Mac awake" section lists foreign assertions from `pmset`,
read-only and visually separated from our own. It answers "teainate is off, so
why is my Mac still up?".

Holds are released individually via `✕`, or all at once.

## CLI

```
teainate status [--json]
teainate on  [--for 45m] [--session | --until-pid PID]
             [--ac-only] [--display] [--label "..."]
teainate off [--all | --id <id>]
```

`--for` accepts `45m`, `2h`, `90` (bare number = minutes).

### `--session` and the ephemeral-shell problem

Claude Code spawns a fresh shell per Bash invocation, so `$PPID` refers to a
process that exits milliseconds later. `--until-pid $PPID` would release the hold
almost immediately.

`--session` therefore walks *up* the process tree from its own parent to find the
long-lived `claude` ancestor and pins `-w` to that PID. The hold auto-releases
when the session genuinely ends — including on crash — and needs no re-upping.

If no `claude` ancestor is found, `--session` exits non-zero with a message
directing the user to `--for`. It does not silently fall back to a hold that
would leak or expire uselessly.

### `status --json`

```json
{
  "awake": true,
  "holds": [
    {
      "id": "h_3f2a",
      "kind": "timer",
      "label": "2h timer",
      "source": "menu",
      "expires_at": "2026-07-26T12:07:31Z",
      "remaining_seconds": 2520,
      "display": false,
      "ac_only": false
    }
  ],
  "foreign_assertions": [
    { "pid": 640, "process": "Claude", "type": "NoIdleSleepAssertion" }
  ]
}
```

Human-readable output is the default; `--json` is for the skill.

## Claude Code skill

Ships in-repo at `skills/teainate/SKILL.md`, installed to
`~/.claude/skills/teainate/`.

The skill description triggers on phrasings like "keep the mac awake", "don't let
it sleep", and "why won't my mac sleep", and instructs Claude to take a
`--session` hold before starting any long-running build, migration, or test run.

### Installation from the UI

The menu bar offers installation directly, because the skill must be able to
locate the CLI and `~/.local/bin` is not reliably on the PATH of the shell Claude
Code spawns.

Install performs two steps:

1. Write `SKILL.md` from a template, substituting the CLI's **absolute path**,
   resolved at install time from `Teainate.app/Contents/MacOS/teainate`. This
   removes any PATH dependency.
2. Symlink `~/.local/bin/teainate` for terminal convenience. Best-effort; the
   skill works without it.

Neither step requires admin rights.

Install also writes `~/.claude/skills/teainate/.teainate-install.json`, recording
the CLI path it baked into `SKILL.md` and the teainate version that wrote it.
This manifest is what the three-state check below reads; without it the skill is
treated as stale and offered for update.

The menu item is three-state, evaluated when the menu opens:

| Condition | Menu item |
| --- | --- |
| `~/.claude/skills/teainate/SKILL.md` absent | **Install Claude Code skill…** |
| Present, recorded CLI path valid, version current | **Claude Code skill installed ✓** (disabled) |
| Present, but recorded path missing or version older | **Update Claude Code skill** |

The third state catches the app being moved after install, which would otherwise
leave the skill pointing at a path that no longer exists.

## Error handling

| Situation | Behaviour |
| --- | --- |
| `caffeinate` fails to spawn | No record written; surface the error. Never record a hold that does not exist. |
| State file corrupt / unparseable | Back up to `holds.json.bak`, start clean, warn. Never crash the app over it. |
| Recorded PID dead | Dropped silently during reconciliation. Normal, not an error. |
| `--session` finds no `claude` ancestor | Exit non-zero, suggest `--for`. |
| `pmset` parse failure | Foreign assertions shown as unavailable; own holds still reported. Degrades partially, never fatally. |
| `flock` contention | Block briefly with timeout; fail with a clear message rather than corrupting state. |

## Testing

`TeainateCore` holds all logic, with the process spawner and `pmset` reader
behind protocols so they can be faked. Unit coverage:

- Flag composition for every combination of the three axes.
- Duration parsing (`45m`, `2h`, `90`, and invalid input).
- Reconciliation when recorded PIDs are dead, alive, or recycled.
- Concurrent read-modify-write under `flock`.
- `pmset -g assertions` parsing, using captured real output as a fixture —
  including the multiple-anonymous-`caffeinate` case that motivated the design.
- Process-tree ancestor walk, including the no-ancestor failure path.
- Skill install: fresh install, up-to-date detection, and stale-path detection.

Integration tests spawn real `caffeinate` processes and assert against real
`pmset` output, then clean up.

## Open questions

None.
