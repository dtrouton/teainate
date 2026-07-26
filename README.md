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
trust after a crash. It does **not** protect against a PID being recycled by
*another* `caffeinate` process (for example, a different Claude Code session's):
that gets adopted as one of teainate's own. Closing that gap would mean also
recording and matching each process's start time, which is not implemented.

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
