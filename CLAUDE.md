# teainate

macOS menu bar app + CLI that keeps the Mac awake by spawning `caffeinate` child
processes, plus a Claude Code skill exposing the same control.

## Commands

```bash
swift test --filter TeainateCoreTests   # fast, hermetic — everything is faked
swift test                              # adds integration tests (real processes)
./scripts/make-app.sh debug             # assembles Teainate.app
.build/debug/teainate status            # drive the CLI
```

No Xcode project. `swift build` plus the script produces everything.

## Safety: this machine probably runs Claude Code

**Never run `teainate off --untracked`, and never trigger the app's "Release
untracked caffeinate…" action, while developing.** It terminates `caffeinate`
processes teainate did not start — which on any machine running Claude Code means
other live sessions' holds, including possibly your own. `off --all` is safe: it
only touches teainate's own holds.

When testing, only ever terminate PIDs your own test spawned, give every spawned
`caffeinate` a short `-t` backstop, and clean up with `defer` so a failed
assertion cannot leave the Mac awake.

**Never run `sudo pmset -a disablesleep` from a test, and never call `set()` or
`clear()` on a real `SudoSleepFlagController` in one.** `isSet()` is unprivileged
(`pmset -g`, no `sudo`) and fine to call directly. The real-process watcher test
passes `--no-flag`. If this machine has the grant, a test that called `set()` or
`clear()` would touch the real flag and could end a real lid-closed hold —
possibly one keeping another session alive.

## Three traps that already caused Critical bugs

**Use `ucomm=`, never `comm=`.** `ps -o comm=` reports the executable *path*, and
truncates it to the column width when other fields follow. The spawner execs
`/usr/bin/caffeinate` by absolute path, so `comm` yields `/usr/bin/caffein` and
every `command == "caffeinate"` comparison fails. That silently dropped every hold
during reconciliation while its `caffeinate` kept running — Mac awake, nothing
shown in `status`, no way to release it.

**Never identify a process by its reported name.** The Claude Code CLI reports its
*version* (`2.1.220`) as its process name; only its command line says `claude`.
Ancestor matching goes through `identifyingName(of:)`, which takes the basename of
the command line's first token. Matching `ucomm` directly meant `--session` — the
entire point of the skill — could never work for anyone.

**The watcher's `ucomm` is `teainate`, not `caffeinate`.** A lid-closed hold's
recorded PID is the `teainate lid-watch` process, not a bare `caffeinate` child, so
`reconcile` has to be kind-aware: `caffeinate` for ordinary holds, `teainate` for
lid-closed ones. `RealLidWatchTests` is the only test that proves it — everything
hermetic fakes the process table and would pass either way.

All three bugs passed the full test suite. See below for why.

## What the test suite cannot see

Every unit test fakes the process table, hardcoding `command: "caffeinate"` — the
exact value both bugs above proved wrong. **A green suite is not evidence that
anything involving `ps` or `pmset` works.**

Any change touching process identification, spawning, or reconciliation needs a
test that pairs the *real* `SystemCaffeinateSpawner` with the *real*
`PSProcessSnapshotter`. `realSpawnedCaffeinateSurvivesReconciliation` in
`HoldStoreTests.swift` is the pattern to copy — it is the only shape of test that
could have caught the `ucomm` bug.

Beware fixture values that hide bugs: both countdown tests originally used 2520
seconds, an exact multiple of 60, which is the one value class where integer
truncation is invisible. A live hold reported "0 min left" for 49 of its 60
seconds with both tests green.

## Architecture

`TeainateCore` holds all logic behind `Sendable` protocols (`CaffeinateSpawning`,
`ProcessSnapshotting`, `AssertionReading`) so it is testable without touching the
system. The CLI and the AppKit app are thin clients.

- **Core must never import AppKit.** The app and CLI must never spawn processes
  directly — everything goes through `TeainateService`.
- **`MenuRenderer` contains no decisions.** It translates `[MenuItem]` into an
  `NSMenu`. Every show/enable/check decision belongs in `MenuModel.swift`, where it
  is unit-tested without instantiating any UI.
- **State is a JSON file guarded by `flock`, with no daemon.** That is what lets
  the CLI work when the app is closed, including over SSH. Both surfaces are plain
  clients of `~/Library/Application Support/teainate/holds.json`, so they cannot
  disagree.
- **Every read reconciles** recorded PIDs against the live process table and drops
  dead ones. A stale record can survive a crash but never survives the next read.
- **Spawn before recording, and clean up if recording fails.** A record must never
  describe a process that does not exist, and a spawned process must never go
  unrecorded — an untracked `caffeinate` holds the Mac awake with no way to release
  it through the UI.

## Conventions

- Swift 6.3, `swiftLanguageModes: [.v6]` — strict concurrency, everything `Sendable`.
- Swift Testing (`import Testing`, `#expect`), not XCTest.
- JSON uses snake_case keys.
- Only external dependency: swift-argument-parser.
- Failures the user asked for must fail loudly: non-zero exit, stderr. `CleanExit`
  prints to stdout and exits 0, which made a failed `--session` look like success
  to anything chaining on it. Use `FriendlyError` instead.

## Known limitations

`docs/followups.md` — reviewed, deliberately deferred, and honest about what is not
implemented. Worth reading before assuming a gap is an oversight.
