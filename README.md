# teainate

A macOS menu bar app and CLI for keeping your Mac awake, plus a Claude Code skill
so Claude can hold the Mac awake for long-running work.

## Why

`caffeinate` already does the hard part. teainate adds the two things it lacks:
a way to see what is currently holding your Mac awake, and shared state between
the menu bar and the command line.

## Install

```bash
git clone https://github.com/dtrouton/teainate.git
cd teainate
./scripts/make-app.sh release
cp -r Teainate.app /Applications/
open /Applications/Teainate.app
```

Then click **Install Claude Code skill…** in the menu.

## Usage

```bash
teainate status              # what is keeping this Mac awake?
teainate status --json       # machine-readable

teainate on                          # indefinitely
teainate on --for 45m                # 45 minutes
teainate on --for 2h --ac-only       # 2 hours, give up if unplugged
teainate on --display                # keep the screen on too
teainate on --session                # until this Claude Code session ends

teainate off --id h_3f2a
teainate off --all
teainate off --untracked      # terminate caffeinate processes teainate didn't start
```

`teainate on --session` walks up the process tree looking for a `claude` ancestor.
If none is found (for example, run outside a Claude Code session) it fails loudly —
a non-zero exit and an error on stderr — rather than silently falling back to an
indefinite hold. Use `--for` instead in that case.

### Modes

| Axis | Options | caffeinate flag |
| --- | --- | --- |
| Duration | forever / timed / until a process exits | — / `-t` / `-w` |
| Power | always / only while plugged in | `-i` / `-s` |
| Display | screen may sleep / stay on | — / `-d` |

The default is `-i`: the system stays awake but the screen is free to sleep,
which is what you want for long builds and Claude Code sessions.

A label (`--label`) is just a note shown alongside a hold — it never replaces the
countdown, so a labelled timed hold still shows something like `build — 42 min left`.

### Lid-closed holds

`caffeinate` cannot survive closing the lid: that is an explicit sleep request, not
idle sleep. teainate's `--lid-closed` modifier sets the kernel `SleepDisabled` flag
(`pmset -a disablesleep 1`) for exactly the life of one hold:

```bash
teainate on --lid-closed --for 2h
teainate on --lid-closed --session
```

It needs a one-time grant from the menu (**Enable lid-closed holds…**), which writes
`/etc/sudoers.d/teainate-<you>` allowing exactly two commands: `pmset -a disablesleep 1`
and `0`. Nothing else can run through it, and **Disable lid-closed holds…** removes it.

Safety rails: a battery floor (default 15%, set from the menu) ends the hold before
the battery drains; command-line holds must have a duration (max 8 h) or a watched
process; and every teainate read clears a flag left behind by a crash. A closed
MacBook under sustained load runs hot — use judgement.

Each lid-closed hold is a `teainate lid-watch` watcher process rather than a bare
`caffeinate`; the watcher runs `caffeinate -w <its own pid>` so a dead watcher can
never leave an orphaned caffeinate.

### Untracked caffeinate processes

teainate can only track holds it started itself. `teainate status` also lists any
other `caffeinate` process it finds running (started by you, another tool, or a
previous crashed run) under "caffeinate processes not managed by teainate", and
`teainate off --untracked` will terminate those. This is kept separate from
`teainate off --all`, which only ever touches teainate's own holds — teainate
cannot prove an untracked process is safe to kill, so that action must always be
requested explicitly.

## How it works

Each hold is a real `caffeinate` child process. teainate records the PIDs it
spawned in `~/Library/Application Support/teainate/holds.json`; the menu bar app
and CLI are both plain clients of that file, which is why they always agree and
why the CLI works with the app closed.

Every `caffeinate` assertion looks identical in `pmset -g assertions`, so keeping
our own records is the only way to tell teainate's holds from anyone else's.

Process names are read from `ps`'s `ucomm` field, not `comm` — `comm` reports the
executable's full path, which for a process launched by absolute path (as
teainate launches `caffeinate`) truncates to something like `/usr/bin/caffein`
and silently breaks name matching.

On every read, teainate drops any recorded hold whose PID is gone or now belongs
to a process that is not `caffeinate` — this is what makes the state file safe to
trust after a crash. Since 0.2.1 each record also carries the process's exact
start time (`process_started_at`, read from the kernel with `proc_pidinfo`), and
reconciliation requires both the PID and the start time to match, so a recycled
PID is never adopted. Records written by earlier versions match by name only
until they end.

## Development

```bash
swift test --filter TeainateCoreTests        # fast, hermetic
swift test                                   # includes integration tests
./scripts/make-app.sh debug && open Teainate.app
```

The integration tests in `Tests/TeainateIntegrationTests` spawn and terminate real
`caffeinate` processes and read real `pmset` state, so they are slower and less
hermetic than `TeainateCoreTests`. That is also why they live in a separate test
target.

Known limitations and planned work are in [`docs/followups.md`](docs/followups.md).

## License

MIT — see [LICENSE](LICENSE).
