# Known follow-ups

Findings from the whole-branch review that were consciously deferred rather than
fixed. None risk data loss or other processes' holds. Ordered roughly by value.

## Worth doing next

**Lid-closed holds: deferred rails.** Low Power Mode step-aside (overlaps the floor;
one more thing to poll), a per-hold floor override for humans at the CLI, and a
`status` line for "grant present but sudo refuses" (only detectable by a `sudo -n`
probe, which `status` deliberately never runs — today it surfaces at `on` time).

**Lid-closed holds: what the user is told about the flag.** Two findings from the
final review that change messaging, not safety. (1) When `pmset -g` cannot be read,
orphan cleanup assumes the flag is set (`?? true`, so it tries to clear) while
`status` assumes it is clear (`?? false`, so `flag_set` reads false). Report
"unknown" instead of guessing in either direction. (2) `LidClosedStatus.warning` is a
single field, so a stuck-flag or set-elsewhere warning overwrites the settings-file
warning; a corrupt `settings.json` plus a stuck flag hides the silent fallback to
floor 15. Smaller, same area: a corrupt `holds.json` is backed up and reset, which
also resets `lid_flag_owned`, so a flag teainate set then reads as someone else's;
the ended-hold alert in the app is a modal `NSAlert` rather than a notification;
timer expiry is noticed up to 30 s late because the watcher polls, so `status` can
briefly show a lid-closed hold whose caffeinate has already exited.

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

**Make the duration overflow trap impossible, not merely unreachable.**
`parseDuration` now caps at 30 days, so no CLI input can reach the
`String(Int(duration))` conversion in `caffeinateFlags` with an unbounded value.
But that conversion is still unguarded and `HoldOptions.duration` is a bare
`TimeInterval?`, so a future caller constructing `HoldOptions` directly — a new
menu duration picker, a test, programmatic use — could trap exactly as the CLI
used to. Either bound it at the `caffeinateFlags` layer too, or give durations a
type that cannot hold an out-of-range value.

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
- **Long holds render in minutes.** A 30-day hold reads `43200 min left`.
  `defaultLabel` should switch to hours and days past some threshold. Only
  reachable from the CLI — the menu's longest preset is 4 hours.
- **The spec says the skill ships in-repo at `skills/teainate/SKILL.md`.** It
  ships as a Swift string constant instead — a deliberate change (bundle-resource
  lookup differs between the CLI and the `.app`), but the spec was never updated.
