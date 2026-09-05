# Known follow-ups

Findings from the whole-branch review that were consciously deferred rather than
fixed. None risk data loss or other processes' holds. Ordered roughly by value.

## Worth doing next

**Lid-closed holds: deferred rails.** Low Power Mode step-aside (overlaps the floor;
one more thing to poll), a per-hold floor override for humans at the CLI, and a
`status` line for "grant present but sudo refuses" (only detectable by a `sudo -n`
probe, which `status` deliberately never runs — today it surfaces at `on` time).

**Lid-closed holds: what the user is told about the flag.** Two findings still
open, both about the app rather than the CLI or `status`: the ended-hold alert is
a modal `NSAlert` rather than a notification, and timer expiry is noticed up to
30 s late because the watcher polls, so `status` can briefly show a lid-closed
hold whose caffeinate has already exited.

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
- **Two version constants** — `TeainateVersion.current` and
  `CFBundleShortVersionString` — with nothing tying them together. The skill's
  staleness check keys off the Swift one, so bumping only the plist leaves every
  installed skill claiming to be current.
- **`On.validate()` hand-rolls duration error text via `ValidationError`**,
  duplicating the messages `Errors.swift` already builds. One source of truth
  would keep them from drifting apart.
- **The corrupt-state-file warning has two gaps.** `loadRaw` reports a reset even when
  moving the corrupt file to `.bak` failed (both `FileManager` calls are `try?`), so
  the warning can promise a preserved file that does not exist; and if the mutation
  that discovered the corruption throws before persisting (the reachable case is
  `onLidClosed`'s "sleep disabled elsewhere" pre-flight), the reset stamp is lost
  while the file has already been moved, so that one recovery goes unreported.
- **The corrupt-state-file warning rides in `lid_closed.warnings`.** It is suppressed
  whenever lid-closed dependencies are absent, which never happens in production
  (CLI and app always supply a watcher path) but is the wrong home for a warning
  about `holds.json`. A top-level `warnings` list on `Status` would be honest; the
  spec placed it where it is.
- **`stateResetAt` is never cleared and the ten-minute check is one-sided.** A
  backwards clock step makes the warning reappear until the clock catches up. A
  `0 ..< stateResetWarningPeriod` range check closes it.
- **`On.run`'s `noClaudeAncestor` catch is now a no-op.** It rethrows a
  `FriendlyError` whose text is byte-identical to what ArgumentParser prints for the
  original `ServiceError`; the `do`/`catch` can go.
- **"Sudo pmset exited with status…" reads oddly.** The opening was capitalised to
  satisfy the sentence test; "The sudo pmset command exited with status…" is the
  natural fix.
- **A process-kind hold cannot say which process it is watching.** `watched_pid`
  is recorded but never surfaced, so "until session exits" is all the user gets.
- **Long holds render in minutes.** A 30-day hold reads `43200 min left`.
  `defaultLabel` should switch to hours and days past some threshold. Only
  reachable from the CLI — the menu's longest preset is 4 hours.
- **The spec says the skill ships in-repo at `skills/teainate/SKILL.md`.** It
  ships as a Swift string constant instead — a deliberate change (bundle-resource
  lookup differs between the CLI and the `.app`), but the spec was never updated.
