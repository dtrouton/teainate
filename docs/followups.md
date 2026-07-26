# Known follow-ups

Findings from the whole-branch review that were consciously deferred rather than
fixed. None risk data loss or other processes' holds. Ordered roughly by value.

## Worth doing next

**Distinguish "pmset failed" from "nothing else is holding the Mac awake."**
`status()` swallows a `pmset` failure with `(try? ...) ?? []`, and
`PMSetAssertionReader` never checks `terminationStatus`. Three different
conditions — no other assertions, `pmset` failing, output we could not parse —
all render as an empty `foreign_assertions`. That is the field a user consults to
answer "why won't my Mac sleep?", so an empty list needs to mean empty. Make the
reader distinguish failure, and let the CLI and menu say "unavailable" rather than
implying nothing is there.

**Stop leaking raw Swift enum names to the user.** `teainate status` with the
state file locked prints `Error: lockTimeout`. `HoldStoreError` and `ServiceError`
have no human-readable descriptions, so any error not specially caught surfaces as
its Swift case name. Conform them to `CustomStringConvertible`.

**Cap `--for`.** `teainate on --for 9223372036854775807` traps in
`String(Int(duration))` with `Double value cannot be converted to Int`. It crashes
*after* passing `On.validate()`, which is exactly where a trap should be
impossible. Nothing is left behind — it traps before spawning — but reject
anything beyond a sane bound (say 30 days) in `parseDuration` instead.

**Close the PID-recycling gap properly.** `reconcile` drops holds whose PID now
belongs to a non-`caffeinate` process, but a PID recycled by *another*
`caffeinate` is adopted as ours. On a machine running Claude Code that is not
far-fetched: session `caffeinate` processes respawn constantly, making them a
likely recycling target. The fix is recording each process's start time
(`ps -o lstart=`) alongside its PID and requiring both to match. The docs and
README now describe the limitation accurately; this would remove it.

## Smaller

- **`{{CLI_PATH}}` is not substituted in one place in the skill template**
  (`SkillInstaller.swift`, the "safe to chain" example). An agent copying that
  pattern runs bare `teainate` and may hit `command not found` — in the one case
  where a non-zero exit is supposed to mean "the hold failed".
- **Escape no longer dismisses the reclaim dialog.** Binding Return to Cancel
  overwrote its default Escape binding. Safety is intact (Release needs a
  deliberate click) but Escape should still cancel. A button cannot hold two key
  equivalents, so this needs a small rethink rather than a one-liner.
- **The app alerts on one failure and silently swallows three.** `start()` shows
  an alert when `on` throws; `release`, `releaseAll`, and `reclaimUntracked` use
  `try?` and show nothing. Displayed state stays truthful because `refresh()`
  re-queries, but a click that does nothing deserves an explanation.
- **The same process appears in two sections of `status`** — once under "Also
  keeping this Mac awake" (from `pmset`) and again under "not managed by
  teainate" (from `ps`, with its flags). Each section earns its place, but four
  lines describing two processes makes the reader work.
- **`--for X --session` is rejected, but `off --id X --all` is accepted** with
  `--all` silently ignored. Validate it the same way.
- **State-file corruption recovers silently.** The spec says warn; the code moves
  the file to `.bak` and continues without telling anyone.
- **Two version constants** — `TeainateVersion.current` and
  `CFBundleShortVersionString` — with nothing tying them together. The skill's
  staleness check keys off the Swift one, so bumping only the plist leaves every
  installed skill claiming to be current.
- **The `"caffeinate"` literal is compared in three places.** One constant.
- **A process-kind hold cannot say which process it is watching.** `watched_pid`
  is recorded but never surfaced, so "until session exits" is all the user gets.
- **The spec says the skill ships in-repo at `skills/teainate/SKILL.md`.** It
  ships as a Swift string constant instead — a deliberate change (bundle-resource
  lookup differs between the CLI and the `.app`), but the spec was never updated.
