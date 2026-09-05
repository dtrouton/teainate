# teainate — status honesty and PID identity

**Date:** 2026-09-05
**Status:** Approved

## Purpose

Five follow-ups from `docs/followups.md` that share one theme: what teainate tells
the user must be true, and what it records must identify the right process.

1. Errors print as sentences, never as Swift case names.
2. `status` distinguishes "pmset failed" from "nothing else is holding the Mac awake".
3. Lid-closed status reports an unreadable kernel flag as unknown, never guesses in
   opposite directions, and never drops a warning because another one arrived.
4. A hold's process is identified by PID **and** start time, closing the recycling gap.
5. An out-of-range duration cannot reach `String(Int(duration))`.

## Non-goals

- Low Power Mode step-aside, per-hold floor override, and the "grant present but sudo
  refuses" status line stay deferred.
- No change to the sudoers grant, the watcher loop, or the lid-closed pre-flight rules.

## 1. Human-readable errors

Every Core error enum conforms to `CustomStringConvertible` with a user-facing
sentence: `ServiceError`, `HoldStoreError`, `SleepFlagError`, `SettingsError`,
`GrantError`, `DurationParseError`, `ProcessSnapshotError`. The sentences are the
ones the CLI's `friendlyDescription` uses today, moved into Core so the app's alerts
say the same thing. The CLI's switch is deleted; `On.run` wraps any thrown `Error`
whose type is one of these enums in `FriendlyError(description: "\(error)")`.
`HoldStoreError.lockTimeout` reads "Another teainate process is holding the state
file; try again in a moment."

Test: one test per enum iterating every case (or a representative of each
associated-value case) and asserting the description contains a space and does not
equal the case name.

## 2. pmset availability

`PMSetAssertionReader.assertions()` checks `terminationStatus` and throws
`AssertionReadError.pmsetFailed(status:)` on non-zero exit. Output that parses to
zero assertions is **not** an error: `pmset -g assertions` legitimately lists none.

`Status` gains `pmsetAvailable: Bool` (JSON `pmset_available`). When the reader
throws, `status()` sets it false and leaves `foreignAssertions` empty. Rendering:

- CLI text: `Other sleep assertions: unavailable (pmset failed)` in place of the
  "Also keeping this Mac awake" section.
- Menu: a disabled row with the same text where that section would be.
- JSON: consumers that ignore the new field see today's shape.
- Skill: one added sentence — if `pmset_available` is false, say so rather than
  concluding nothing else is holding the Mac awake.

## 3. Lid-closed messaging

`LidClosedStatus.flagSet` becomes `Bool?`; nil (JSON `null`) means `pmset -g` could
not be read. `flagSetBy` is nil whenever `flagSet` is not true. `warning: String?`
becomes `warnings: [String]` (JSON `warnings`), appended in this order: settings-file
warning, flag warnings, state-file warning. Orphan cleanup keeps treating an
unreadable flag as "assume set, attempt the clear"; `status` no longer contradicts it
by reporting `false`, it reports unknown plus the warning "Could not read the
sleep-disabled flag (pmset -g failed)."

`HoldStore` reports a corrupt-file reset: `mutateState` records that `loadRaw` backed
the file up, and `StoreState` carries a transient, non-persisted `recoveredFromCorruptFile`
flag the service turns into the warning "The state file was corrupt and has been
reset; if this Mac will not sleep, run: sudo pmset -a disablesleep 0". This also
closes the "state-file corruption recovers silently" item.

Renderers (`renderStatus`, `buildMenu`) print every warning, one line each, prefixed
`⚠ `.

## 4. PID identity

`Hold` gains `processStartedAt: Date?` (JSON `process_started_at`): the exact start
time of the recorded process, read with `proc_pidinfo(PROC_PIDTBSDINFO)` immediately
after spawn. Both spawners (`caffeinate` and the watcher) return the PID as today;
the service reads the start time through a new protocol:

```swift
public protocol ProcessStartTimeReading: Sendable {
    /// nil when the process is gone or not ours to inspect.
    func startTime(of pid: pid_t) -> Date?
}
```

`ProcPIDInfoStartTimeReader` is the real implementation. `reconcile` gains a second
input, the start-time reader, and keeps a hold only if the live process has the
expected name **and**, when the record carries `processStartedAt`, the live start time
equals it (compare to the microsecond: both values come from the same kernel field).
Records without the field keep name-only matching so existing state files are not
dropped on upgrade. `HoldStore` owns the reader alongside the snapshotter; tests
inject a fake.

If `startTime(of:)` returns nil right after a successful spawn (the process died
instantly), the service still records the hold with `processStartedAt == nil`; the
next reconcile drops it by name/PID as today.

Tests: hermetic — same PID, different start time is dropped; same PID, same start
time is kept; legacy record with nil start time is kept by name. Real-process —
spawn caffeinate, read its start time, reconcile keeps it against the real
snapshotter and real reader; then spawn a second caffeinate and confirm a record
carrying the first process's start time but the second's PID is dropped.

## 5. Duration bound

`HoldOptions.init` stays non-throwing (it is used everywhere), but `caffeinateFlags`
clamps: `min(duration, maxDurationSeconds)` before `Int(...)`, and `TeainateService.on`
throws `ServiceError.durationTooLong` when `options.duration > maxDurationSeconds`
so the clamp is a backstop, not a silent change. Test: `HoldOptions(duration:
.greatestFiniteMagnitude)` through `on` throws; `caffeinateFlags` on the same options
returns `-t` with `maxDurationSeconds`, not a trap.

## Compatibility

`holds.json` gains one optional field per hold; old files load. `status --json` gains
`pmset_available` and changes `lid_closed.warning` to `lid_closed.warnings` and
`lid_closed.flag_set` to nullable. The skill text is updated for both. Version stays
0.2.0 → 0.2.1 so installed skills refresh.

## Testing

Hermetic `TeainateCoreTests` for everything; one new real-process test in
`TeainateIntegrationTests` for item 4. No test touches the real flag or the sudoers
directory. No manual checklist: nothing here changes lid or flag behaviour.
