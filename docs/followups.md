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

- **Escape no longer dismisses the reclaim dialog.** Binding Return to Cancel
  overwrote its default Escape binding. Safety is intact (Release needs a
  deliberate click) but Escape should still cancel. A button cannot hold two key
  equivalents, so this needs a small rethink rather than a one-liner.
- **A corrupt-state-file reset can go unreported.** If the mutation that discovered the
  corruption throws before persisting (the reachable case is `onLidClosed`'s "sleep
  disabled elsewhere" pre-flight), the reset stamp is lost while the file has already
  been moved to `.bak`. Narrow; the next read starts clean rather than warning. (The
  `.bak` move itself is best-effort by design and the warning never claims otherwise.)
- **The corrupt-state-file warning rides in `lid_closed.warnings`.** It is suppressed
  whenever lid-closed dependencies are absent, which never happens in production
  (CLI and app always supply a watcher path) but is the wrong home for a warning
  about `holds.json`. A top-level `warnings` list on `Status` would be honest; the
  spec placed it where it is.
