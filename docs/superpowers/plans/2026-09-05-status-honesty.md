# Status Honesty and PID Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every message teainate prints true (sentences not case names, "unavailable" not "nothing", "unknown" not a guess) and identify a hold's process by PID and exact start time.

**Architecture:** Core error enums gain `CustomStringConvertible`; `Status` gains `pmsetAvailable`; `LidClosedStatus` gets a nullable `flagSet` and a `warnings` list; `HoldStore` records when it reset a corrupt file; a new `ProcessStartTimeReading` protocol wraps `proc_pidinfo` and `reconcile` compares start times when a record has one; `caffeinateFlags` clamps durations and `on` refuses over-long ones.

**Tech Stack:** Swift 6.3 strict concurrency, Swift Testing, `proc_pidinfo(PROC_PIDTBSDINFO)` from `Darwin`.

**Spec:** `docs/superpowers/specs/2026-09-05-status-honesty-design.md`

## Global Constraints

- Core never imports AppKit; `MenuRenderer` contains no decisions; every show/enable decision is in `MenuModel.swift`.
- Swift Testing (`import Testing`, `#expect`); every new type `Sendable`; JSON keys snake_case.
- **No test may call `set()`/`clear()` on the real `SudoSleepFlagController`, run `sudo`, or touch `/etc/sudoers.d`.** This machine currently HAS the sudoers grant installed, so a stray real call would change the real kernel flag. `teainate off --untracked` is never run. Every spawned `caffeinate` gets a short `-t` and `defer` cleanup.
- Existing state files must still load: every new `Hold`/`StoreState` field decodes with `decodeIfPresent`.
- Every new init parameter has a default so existing call sites compile unchanged.
- Version bumps 0.2.0 → 0.2.1 in both `Version.swift` and `Resources/Info.plist`.
- Run `swift test --filter TeainateCoreTests` after every task; full `swift test` after Tasks 6 and 7.

---

## File map

| File | Responsibility |
| --- | --- |
| `Sources/TeainateCore/Errors.swift` (new) | `CustomStringConvertible` for every Core error enum. |
| `Sources/teainate/Teainate.swift` | Delete `friendlyDescription`; rely on error descriptions. |
| `Sources/TeainateCore/AssertionReading.swift` | `AssertionReadError`, `terminationStatus` check. |
| `Sources/TeainateCore/TeainateService.swift` | `Status.pmsetAvailable`, `LidClosedStatus` changes, `durationTooLong`, start-time recording. |
| `Sources/TeainateCore/StatusRendering.swift`, `MenuModel.swift` | "unavailable" line, warnings loop. |
| `Sources/TeainateCore/Hold.swift` | `ProcessStartTime`, `Hold.processStartedAt`, `StoreState.stateResetAt`, clamped `caffeinateFlags`. |
| `Sources/TeainateCore/HoldStore.swift` | Start-time-aware `reconcile`, reset recording. |
| `Sources/TeainateCore/ProcessStartTime.swift` (new) | `ProcessStartTimeReading`, `ProcPIDInfoStartTimeReader`. |
| `Sources/TeainateCore/SkillInstaller.swift`, `Version.swift`, `Resources/Info.plist`, `README.md`, `docs/followups.md` | Text, version, cleanup. |

---

### Task 1: Human-readable errors

**Files:**
- Create: `Sources/TeainateCore/Errors.swift`
- Modify: `Sources/teainate/Teainate.swift`, `Sources/TeainateCore/HoldStore.swift` (doc only)
- Test: `Tests/TeainateCoreTests/ErrorDescriptionTests.swift`

**Interfaces:**
- Produces: `CustomStringConvertible` conformances for `ServiceError`, `HoldStoreError`, `SleepFlagError`, `SettingsError`, `GrantError`, `DurationParseError`, `ProcessSnapshotError`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import TeainateCore

/// A description is user-facing if it reads as a sentence: it has a space and is not
/// the bare Swift case name.
private func isSentence(_ error: any Error) -> Bool {
    let text = "\(error)"
    return text.contains(" ") && !text.hasPrefix(".") && text.first?.isUppercase == true
}

@Test func serviceErrorsReadAsSentences() {
    let cases: [ServiceError] = [
        .noClaudeAncestor, .spawnFailed("boom"), .lidClosedUnavailable, .lidClosedNotEnabled,
        .lidClosedGrantBroken("sudo: a password is required"),
        .batteryBelowFloor(percent: 12, floor: 15), .notOnACPower, .sleepDisabledElsewhere,
        .sleepFlagStuck("x"),
    ]
    for error in cases { #expect(isSentence(error), "\(error)") }
    #expect("\(ServiceError.batteryBelowFloor(percent: 12, floor: 15))".contains("12%"))
    #expect("\(ServiceError.sleepFlagStuck("x"))".contains("sudo pmset -a disablesleep 0"))
}

@Test func storeFlagSettingsGrantDurationSnapshotErrorsReadAsSentences() {
    let all: [any Error] = [
        HoldStoreError.lockTimeout,
        SleepFlagError.commandFailed(status: 1, message: "denied"),
        SettingsError.floorOutOfRange(51),
        GrantError.invalidUsername,
        DurationParseError.invalid("5x"), DurationParseError.tooLong("99d"),
        ProcessSnapshotError.psFailed(status: 1),
    ]
    for error in all { #expect(isSentence(error), "\(error)") }
    #expect("\(HoldStoreError.lockTimeout)".contains("try again"))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ErrorDescriptionTests`
Expected: FAIL — `"\(HoldStoreError.lockTimeout)"` is `lockTimeout`.

- [ ] **Step 3: Implement `Errors.swift`**

```swift
import Foundation

// Every Core error prints as a sentence. ArgumentParser renders an uncaught error as
// `Error: \(error)`, and the app shows `"\(error)"` in alerts, so these descriptions
// are the user-facing text on both surfaces.

extension ServiceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noClaudeAncestor:
            return "No Claude Code session found in this process tree. Use --for instead, e.g. teainate on --for 45m"
        case .spawnFailed(let message):
            return "Could not start the process: \(message)"
        case .lidClosedUnavailable:
            return "Lid-closed holds are not available in this build."
        case .lidClosedNotEnabled:
            return "Lid-closed holds are not enabled. Enable them from the Teainate menu (Enable lid-closed holds…) first."
        case .lidClosedGrantBroken(let message):
            return "Lid-closed holds are enabled but sudo refused: \(message). Disable and re-enable them from the Teainate menu."
        case .batteryBelowFloor(let percent, let floor):
            return "Battery at \(percent)%, at or below the \(floor)% floor. Plug in, or raise the floor from the Teainate menu."
        case .notOnACPower:
            return "--ac-only with --lid-closed needs the Mac to be plugged in now."
        case .sleepDisabledElsewhere:
            return "Sleep is already disabled outside teainate (pmset disablesleep). An ordinary hold will work with the lid closed until that is cleared."
        case .sleepFlagStuck(let message):
            return "The hold failed and the sleep-disabled flag could not be cleared: \(message). Run: sudo pmset -a disablesleep 0"
        }
    }
}

extension HoldStoreError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .lockTimeout:
            return "Another teainate process is holding the state file; try again in a moment."
        }
    }
}

extension SleepFlagError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .commandFailed(let status, let message):
            return "sudo pmset exited with status \(status): \(message)"
        }
    }
}

extension SettingsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .floorOutOfRange(let value):
            return "Battery floor \(value)% is outside \(batteryFloorRange.lowerBound)–\(batteryFloorRange.upperBound)%."
        }
    }
}

extension GrantError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidUsername:
            return "Your macOS username contains characters that cannot be written into a sudoers rule."
        }
    }
}

extension DurationParseError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalid(let text):
            return "Invalid duration '\(text)'. Use 45m, 2h, or a bare number of minutes."
        case .tooLong(let text):
            return "Duration '\(text)' is longer than the \(maxDurationDays) day maximum."
        }
    }
}

extension ProcessSnapshotError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .psFailed(let status):
            return "Could not read the process table (ps exited with status \(status))."
        }
    }
}
```

- [ ] **Step 4: Simplify the CLI**

In `Sources/teainate/Teainate.swift`: delete `friendlyDescription(_:)` entirely. In `On.run`, replace

```swift
        let hold: Hold
        do {
            hold = try service.on(options)
        } catch let error as ServiceError {
            if let message = friendlyDescription(error) { throw FriendlyError(description: message) }
            throw error
        }
```

with `let hold = try service.on(options)`. Keep the existing `noClaudeAncestor` catch around `resolveSessionPID` but make it `throw FriendlyError(description: "\(ServiceError.noClaudeAncestor)")` so the text lives in one place. `FriendlyError` stays for CLI-only messages (`off --id` not found).

- [ ] **Step 5: Run the tests, then a real check**

Run: `swift test --filter TeainateCoreTests` — PASS.

Hand check of the one error that used to leak, without touching any hold: hold the state lock from another process for eight seconds and run `status`.

```bash
swift build
python3 -c "import fcntl,time,os; p=os.path.expanduser('~/Library/Application Support/teainate/holds.json.lock'); f=open(p,'w'); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(8)" &
sleep 1; .build/debug/teainate status; echo "exit=$?"; wait
```

Expected: `Error: Another teainate process is holding the state file; try again in a moment.` and `exit=1`.

- [ ] **Step 6: Commit**

```bash
git add Sources/TeainateCore/Errors.swift Sources/teainate/Teainate.swift Tests/TeainateCoreTests/ErrorDescriptionTests.swift
git commit -m "feat(core): every error prints as a sentence"
```

---

### Task 2: pmset availability

**Files:**
- Modify: `Sources/TeainateCore/AssertionReading.swift`, `Sources/TeainateCore/TeainateService.swift`, `Sources/TeainateCore/StatusRendering.swift`, `Sources/TeainateCore/MenuModel.swift`, `Sources/TeainateCore/Errors.swift`
- Test: `Tests/TeainateCoreTests/ServiceTests.swift`, `OutputTests.swift`, `MenuModelTests.swift`

**Interfaces:**
- Produces: `AssertionReadError.pmsetFailed(status:)`; `Status.pmsetAvailable: Bool` (init param `pmsetAvailable: Bool = true`, key `pmset_available`).

- [ ] **Step 1: Write the failing tests**

In `ServiceTests.swift`, extend `statusSurvivesAssertionReaderFailure`:

```swift
    let status = try service.status()
    #expect(status.foreignAssertions.isEmpty)
    #expect(status.pmsetAvailable == false)
```

and add:

```swift
@Test func pmsetAvailableWhenReaderSucceeds() throws {
    let service = makeService(snapshotter: StubSnapshotter(table: liveTable(100)))
    #expect(try service.status().pmsetAvailable == true)
}

@Test func statusJSONCarriesPmsetAvailable() throws {
    let service = makeService()
    let json = String(decoding: try Status.encoder.encode(try service.status()), as: UTF8.self)
    #expect(json.contains("\"pmset_available\" : true"))
}
```

In `OutputTests.swift` (give the `status(...)` helper a `pmsetAvailable: Bool = true` parameter passed through):

```swift
@Test func rendersUnavailableAssertionsInsteadOfNothing() {
    let text = renderStatus(status(awake: false, pmsetAvailable: false))
    #expect(text.contains("Other sleep assertions: unavailable (pmset failed)"))
    #expect(!text.contains("Also keeping this Mac awake"))
}
```

In `MenuModelTests.swift` (same helper change):

```swift
@Test func menuShowsUnavailableAssertions() {
    let items = buildMenu(status: status(pmsetAvailable: false), preferences: MenuPreferences(), skillState: .current)
    #expect(titles(items).contains("Other sleep assertions: unavailable (pmset failed)"))
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TeainateCoreTests` — compile error on `pmsetAvailable`.

- [ ] **Step 3: Implement**

`AssertionReading.swift`:

```swift
public enum AssertionReadError: Error, Equatable {
    case pmsetFailed(status: Int32)
}
```

and in `PMSetAssertionReader.assertions()`, after `waitUntilExit()`:

```swift
        guard process.terminationStatus == 0 else {
            throw AssertionReadError.pmsetFailed(status: process.terminationStatus)
        }
```

`Errors.swift`: add

```swift
extension AssertionReadError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .pmsetFailed(let status):
            return "Could not read sleep assertions (pmset exited with status \(status))."
        }
    }
}
```

`TeainateService.swift`: `Status` gains `public let pmsetAvailable: Bool`, init param `pmsetAvailable: Bool = true` (append after `lidClosed`), coding key `pmsetAvailable = "pmset_available"`. In `status()`:

```swift
        // pmset failing must not hide our own holds — but it must not read as
        // "nothing else is holding the Mac awake" either.
        let foreignResult = Result { try assertionReader.assertions() }
        let foreign = (try? foreignResult.get()) ?? []
        let pmsetAvailable = (try? foreignResult.get()) != nil
```

and pass `pmsetAvailable: pmsetAvailable` into `Status`.

`StatusRendering.swift`: replace the `if !status.foreignAssertions.isEmpty` block with

```swift
    if !status.pmsetAvailable {
        lines.append("")
        lines.append("Other sleep assertions: unavailable (pmset failed)")
    } else if !status.foreignAssertions.isEmpty {
        // ...existing body...
    }
```

`MenuModel.swift`: same shape around the "Also keeping this Mac awake" section, emitting `MenuItem(title: "Other sleep assertions: unavailable (pmset failed)", isEnabled: false)` after a separator.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter TeainateCoreTests` — PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateCore Tests/TeainateCoreTests
git commit -m "feat(core): say when pmset is unavailable instead of listing nothing"
```

---

### Task 3: Lid-closed messaging and state-reset warning

**Files:**
- Modify: `Sources/TeainateCore/TeainateService.swift`, `Sources/TeainateCore/Hold.swift`, `Sources/TeainateCore/HoldStore.swift`, `Sources/TeainateCore/StatusRendering.swift`, `Sources/TeainateCore/MenuModel.swift`
- Test: `Tests/TeainateCoreTests/LidClosedServiceTests.swift`, `HoldStoreTests.swift`, `OutputTests.swift`, `MenuModelTests.swift`

**Interfaces:**
- Produces: `LidClosedStatus.flagSet: Bool?`, `LidClosedStatus.warnings: [String]` (key `warnings`; `warning` removed); `StoreState.stateResetAt: Date?` (key `state_reset_at`); `stateResetWarningPeriod: TimeInterval = 600`.

Spec refinement (record in the spec's section 3 as part of this task): the corrupt-file warning is persisted as `state_reset_at` and shown for ten minutes, not carried transiently, because the app's 15 s refresh would otherwise consume a transient flag before the user ever saw it.

- [ ] **Step 1: Write the failing tests**

`LidClosedServiceTests.swift` — update every `.warning` use to `.warnings` (e.g. `status.lidClosed.warnings.isEmpty`, `status.lidClosed.warnings.contains { $0.contains("sudo pmset -a disablesleep 0") }`) and every `flagSet == false` stays valid (`Bool? == false`). Add to `FakeFlag` a `var failIsSet = false` that makes `isSet()` throw `SleepFlagError.commandFailed(status: 1, message: "pmset -g failed")`. Add:

```swift
@Test func unreadableFlagIsReportedAsUnknownNotFalse() throws {
    let rig = Rig(table: [:])
    rig.flag.failIsSet = true
    let status = try rig.service.status()
    #expect(status.lidClosed.flagSet == nil)
    #expect(status.lidClosed.flagSetBy == nil)
    #expect(status.lidClosed.warnings.contains { $0.contains("Could not read the sleep-disabled flag") })
}

@Test func settingsWarningSurvivesAFlagWarning() throws {
    let rig = Rig(table: [:])
    try FileManager.default.createDirectory(at: rig.settings.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "{ nope".write(to: rig.settings.fileURL, atomically: true, encoding: .utf8)
    rig.flag.value = true                    // set by someone else
    let warnings = try rig.service.status().lidClosed.warnings
    #expect(warnings.contains { $0.contains("settings.json") })
    #expect(warnings.contains { $0.contains("outside teainate") })
}

@Test func corruptStateFileWarnsForTenMinutesThenStops() throws {
    let rig = Rig(table: [:])
    try FileManager.default.createDirectory(at: rig.stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "{ not json".write(to: rig.stateFile, atomically: true, encoding: .utf8)

    #expect(try rig.service.status().lidClosed.warnings.contains { $0.contains("state file was corrupt") })
    rig.clock.advance(by: 601)
    #expect(try rig.service.status().lidClosed.warnings.isEmpty)
}
```

(`Rig` already has a mutable clock from the previous branch; if its API differs, use it — the requirement is advancing `now` past 600 s.)

`HoldStoreTests.swift`:

```swift
@Test func corruptFileRecordsWhenItWasReset() throws {
    let url = tempFile()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "{ not valid json".write(to: url, atomically: true, encoding: .utf8)
    let now = Date(timeIntervalSince1970: 5_000)
    let store = HoldStore(fileURL: url, snapshotter: FakeSnapshotter(table: [:]), now: { now })
    #expect(try store.readState().stateResetAt == now)
    // Persisted: a second store on the same file still sees it.
    #expect(try HoldStore(fileURL: url, snapshotter: FakeSnapshotter(table: [:])).readState().stateResetAt == now)
}
```

`OutputTests.swift` and `MenuModelTests.swift`: update `LidClosedStatus(...)` constructions to `flagSet:` `Bool?` values and `warnings: [...]`; the existing warning tests pass `warnings: ["The sleep-disabled flag is set…"]`. Add one test each that two warnings render as two `⚠ ` lines.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TeainateCoreTests` — compile errors.

- [ ] **Step 3: Implement**

`Hold.swift` — `StoreState` gains `public var stateResetAt: Date?` (init param default nil, key `state_reset_at`, `decodeIfPresent`, nil in the legacy branch).

`HoldStore.swift`:

```swift
/// How long `status` keeps warning after a corrupt state file was backed up and reset.
public let stateResetWarningPeriod: TimeInterval = 600

public struct HoldStore: Sendable {
    private let fileURL: URL
    private let snapshotter: any ProcessSnapshotting
    private let now: @Sendable () -> Date

    public init(fileURL: URL, snapshotter: any ProcessSnapshotting,
                now: @escaping @Sendable () -> Date = { Date() }) { ... }
```

`loadRaw()` returns `(state: StoreState, wasReset: Bool)`; the catch branch returns `(StoreState(), true)`. In `mutateState`:

```swift
        var (state, wasReset) = loadRaw()
        if wasReset { state.stateResetAt = now() }
```

`TeainateService.swift` — `LidClosedStatus`:

```swift
    public let flagSet: Bool?          // nil: pmset -g could not be read
    public let flagSetBy: String?      // "teainate" / "other"; nil unless flagSet == true
    public let warnings: [String]
    // init(enabled:flagSet:flagSetBy:batteryFloor:lastEnded:warnings:), key `warnings`
    public static let unavailable = LidClosedStatus(enabled: false, flagSet: false, flagSetBy: nil,
        batteryFloor: defaultBatteryFloor, lastEnded: nil, warnings: [])
```

`lidClosedStatus(_:)`:

```swift
        let flagSet: Bool? = try? lid.flag.isSet()
        let (settings, settingsWarning) = lid.settings.read()
        let liveLid = state.holds.contains(where: \.lidClosed)
        let flagSetBy: String? = flagSet == true ? (state.lidFlagOwned ? "teainate" : "other") : nil

        var warnings: [String] = []
        if let settingsWarning { warnings.append(settingsWarning) }
        if flagSet == nil {
            warnings.append("Could not read the sleep-disabled flag (pmset -g failed).")
        } else if state.lidFlagOwned && !liveLid && flagSet == true {
            warnings.append("The sleep-disabled flag is set and teainate cannot clear it. Run: sudo pmset -a disablesleep 0")
        } else if flagSet == true && !state.lidFlagOwned {
            warnings.append("Sleep is disabled outside teainate (pmset disablesleep); this Mac will not sleep with the lid closed until that is cleared.")
        }
        if let reset = state.stateResetAt, now().timeIntervalSince(reset) < stateResetWarningPeriod {
            warnings.append("The state file was corrupt and has been reset; if this Mac will not sleep, run: sudo pmset -a disablesleep 0")
        }
```

Note `clearOrphanedFlag` keeps `(try? lid.flag.isSet()) ?? true`; add a comment: "Unknown means attempt the clear; `status` reports unknown rather than guessing the other way."

`StatusRendering.swift` / `MenuModel.swift`: replace the single-warning `if let` with `for warning in lid.warnings { … "⚠ \(warning)" … }`.

The state-reset warning is not lid-specific but lives in `lidClosed.warnings` because that is the only warnings channel; the text says what to check.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter TeainateCoreTests` — PASS.

- [ ] **Step 5: Spec refinement**

In `docs/superpowers/specs/2026-09-05-status-honesty-design.md` section 3, replace the "transient, non-persisted `recoveredFromCorruptFile`" sentence with the persisted `state_reset_at` + ten-minute window description.

- [ ] **Step 6: Commit**

```bash
git add Sources/TeainateCore Tests/TeainateCoreTests docs/superpowers/specs/2026-09-05-status-honesty-design.md
git commit -m "feat(core): report an unreadable sleep flag as unknown; keep every warning"
```

---

### Task 4: Duration bound

**Files:**
- Modify: `Sources/TeainateCore/Hold.swift`, `Sources/TeainateCore/TeainateService.swift`, `Sources/TeainateCore/Errors.swift`
- Test: `Tests/TeainateCoreTests/HoldFlagTests.swift`, `ServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

`HoldFlagTests.swift`:

```swift
// Int(TimeInterval.greatestFiniteMagnitude) traps. The clamp is the backstop for any
// caller that bypasses parseDuration.
@Test func absurdDurationIsClampedNotTrapped() {
    let flags = caffeinateFlags(for: opts(duration: .greatestFiniteMagnitude))
    #expect(flags == ["-i", "-t", String(Int(maxDurationSeconds))])
}
```

`ServiceTests.swift`:

```swift
@Test func onRefusesDurationAboveTheCap() {
    let service = makeService(snapshotter: StubSnapshotter(table: liveTable(100)))
    #expect(throws: ServiceError.durationTooLong) {
        try service.on(HoldOptions(duration: maxDurationSeconds + 1, source: .cli))
    }
}
```

- [ ] **Step 2: Run to verify they fail** — the first traps or fails; the second does not compile.

- [ ] **Step 3: Implement**

`caffeinateFlags`: `flags.append(contentsOf: ["-t", String(Int(min(duration, maxDurationSeconds)))])`.

`ServiceError` gains `case durationTooLong`; description: `"Durations are limited to \(maxDurationDays) days."`. At the top of `on(_:)`:

```swift
        if let duration = options.duration, duration > maxDurationSeconds {
            throw ServiceError.durationTooLong
        }
```

Update `serviceErrorsReadAsSentences` in Task 1's test to include `.durationTooLong`.

- [ ] **Step 4: Run the tests** — `swift test --filter TeainateCoreTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateCore Tests/TeainateCoreTests
git commit -m "fix(core): bound durations at the flag layer and in the service"
```

---

### Task 5: Process start time — reader, record field, reconcile

**Files:**
- Create: `Sources/TeainateCore/ProcessStartTime.swift`
- Modify: `Sources/TeainateCore/Hold.swift`, `Sources/TeainateCore/HoldStore.swift`
- Test: `Tests/TeainateCoreTests/ProcessStartTimeTests.swift`, `HoldStoreTests.swift`

**Interfaces:**
- Produces: `ProcessStartTime { seconds: Int64, microseconds: Int32 }` (Codable, keys `seconds`/`microseconds`); `protocol ProcessStartTimeReading { func startTime(of pid: pid_t) -> ProcessStartTime? }`; `ProcPIDInfoStartTimeReader`; `Hold.processStartedAt: ProcessStartTime?` (key `process_started_at`, init param default nil, `decodeIfPresent`); `reconcile(_:against:startTime:)` with `startTime: (pid_t) -> ProcessStartTime? = { _ in nil }`; `HoldStore.init(..., startTimes: any ProcessStartTimeReading = ProcPIDInfoStartTimeReader())`.

- [ ] **Step 1: Write the failing tests**

`ProcessStartTimeTests.swift`:

```swift
import Testing
import Foundation
@testable import TeainateCore

@Test func readsOwnStartTime() {
    let reader = ProcPIDInfoStartTimeReader()
    let mine = reader.startTime(of: getpid())
    #expect(mine != nil)
    // Started after 2020 and not in the future.
    #expect((mine?.seconds ?? 0) > 1_577_836_800)
    #expect(Double(mine?.seconds ?? .max) <= Date().timeIntervalSince1970)
    #expect((0..<1_000_000).contains(Int(mine?.microseconds ?? -1)))
}

@Test func missingProcessHasNoStartTime() {
    #expect(ProcPIDInfoStartTimeReader().startTime(of: 999_999) == nil)
}

@Test func startTimeIsStable() {
    let reader = ProcPIDInfoStartTimeReader()
    #expect(reader.startTime(of: getpid()) == reader.startTime(of: getpid()))
}

@Test func startTimeRoundTripsThroughJSONExactly() throws {
    let time = ProcessStartTime(seconds: 1_757_000_000, microseconds: 123_456)
    let data = try Hold.encoder.encode(time)
    #expect(try Hold.decoder.decode(ProcessStartTime.self, from: data) == time)
}
```

`HoldStoreTests.swift`:

```swift
private let t1 = ProcessStartTime(seconds: 1_000, microseconds: 1)
private let t2 = ProcessStartTime(seconds: 1_000, microseconds: 2)

private func stamped(_ id: String, pid: pid_t, startedAt: ProcessStartTime?) -> Hold {
    var h = hold(id, pid: pid)
    h.processStartedAt = startedAt
    return h
}

@Test func reconcileKeepsHoldWhoseStartTimeMatches() {
    let kept = reconcile([stamped("a", pid: 100, startedAt: t1)], against: table((100, "caffeinate")),
                         startTime: { _ in t1 })
    #expect(kept.map(\.id) == ["a"])
}

@Test func reconcileDropsRecycledPIDWithDifferentStartTime() {
    // Same pid, same name, one microsecond later: a different process.
    let kept = reconcile([stamped("a", pid: 100, startedAt: t1)], against: table((100, "caffeinate")),
                         startTime: { _ in t2 })
    #expect(kept.isEmpty)
}

@Test func reconcileDropsStampedHoldWhoseStartTimeCannotBeRead() {
    let kept = reconcile([stamped("a", pid: 100, startedAt: t1)], against: table((100, "caffeinate")),
                         startTime: { _ in nil })
    #expect(kept.isEmpty)
}

@Test func legacyRecordWithoutStartTimeMatchesByNameOnly() {
    let kept = reconcile([stamped("a", pid: 100, startedAt: nil)], against: table((100, "caffeinate")),
                         startTime: { _ in t2 })
    #expect(kept.map(\.id) == ["a"])
}

@Test func storeUsesItsStartTimeReader() throws {
    struct FixedReader: ProcessStartTimeReading {
        let value: ProcessStartTime?
        func startTime(of pid: pid_t) -> ProcessStartTime? { value }
    }
    let url = tempFile()
    let writer = HoldStore(fileURL: url, snapshotter: FakeSnapshotter(table: table((100, "caffeinate"))),
                           startTimes: FixedReader(value: t1))
    try writer.mutate { $0.append(stamped("a", pid: 100, startedAt: t1)) }
    let recycled = HoldStore(fileURL: url, snapshotter: FakeSnapshotter(table: table((100, "caffeinate"))),
                             startTimes: FixedReader(value: t2))
    #expect(try recycled.read().isEmpty)
}

@Test func oldRecordDecodesWithNilStartTime() throws {
    // Extend `oldArrayShapedStateFileStillLoads`: add
    // #expect(state.holds.first?.processStartedAt == nil)
}
```

- [ ] **Step 2: Run to verify they fail** — compile errors.

- [ ] **Step 3: Implement `ProcessStartTime.swift`**

```swift
import Darwin
import Foundation

/// A process's start time as the kernel reports it, to the microsecond. Two processes
/// that reuse a PID cannot share one; comparing it alongside the PID closes the
/// recycling gap. Stored as integers so the JSON round trip is exact (ISO-8601 dates
/// would lose the microseconds).
public struct ProcessStartTime: Codable, Sendable, Equatable, Hashable {
    public let seconds: Int64
    public let microseconds: Int32

    public init(seconds: Int64, microseconds: Int32) {
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

public protocol ProcessStartTimeReading: Sendable {
    /// nil when the process is gone, or belongs to another user (EPERM). Every hold
    /// process is ours, so nil for a recorded pid means "not the process we spawned".
    func startTime(of pid: pid_t) -> ProcessStartTime?
}

/// `proc_pidinfo(PROC_PIDTBSDINFO)` — the same field `ps -o lstart` prints, without
/// parsing text and without losing the microseconds.
public struct ProcPIDInfoStartTimeReader: ProcessStartTimeReading {
    public init() {}

    public func startTime(of pid: pid_t) -> ProcessStartTime? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessStartTime(seconds: Int64(info.pbi_start_tvsec),
                                microseconds: Int32(info.pbi_start_tvusec))
    }
}
```

`Hold.swift`: add `public var processStartedAt: ProcessStartTime?`, init param `processStartedAt: ProcessStartTime? = nil` (last), coding key `processStartedAt = "process_started_at"`, `decodeIfPresent` in `init(from:)`.

`HoldStore.swift`:

```swift
/// Drops holds whose PID is gone, now belongs to a process of the wrong kind, or —
/// when the record carries a start time — to a process started at a different instant.
/// A record without a start time (written before 0.2.1) matches by name only.
public func reconcile(
    _ holds: [Hold],
    against table: [pid_t: ProcessSnapshot],
    startTime: (pid_t) -> ProcessStartTime? = { _ in nil }
) -> [Hold] {
    holds.filter { hold in
        guard table[hold.caffeinatePID]?.command == expectedProcessName(for: hold) else { return false }
        guard let recorded = hold.processStartedAt else { return true }
        return startTime(hold.caffeinatePID) == recorded
    }
}
```

`HoldStore` stores `startTimes` (init param default `ProcPIDInfoStartTimeReader()`) and calls `reconcile(state.holds, against: try snapshotter.snapshot(), startTime: startTimes.startTime(of:))`. Update the doc comment that still points at followups for PID recycling. The `RealLidWatchTests` and `realSpawnedCaffeinateSurvivesReconciliation` calls keep compiling via the default.

- [ ] **Step 4: Run the tests** — `swift test --filter TeainateCoreTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateCore Tests/TeainateCoreTests
git commit -m "feat(core): identify hold processes by PID and exact start time"
```

---

### Task 6: Record start times in the service, real-process proof

**Files:**
- Modify: `Sources/TeainateCore/TeainateService.swift`
- Test: `Tests/TeainateCoreTests/ServiceTests.swift`, `Tests/TeainateIntegrationTests/RealCaffeinateTests.swift`

**Interfaces:**
- Consumes: `ProcessStartTimeReading`, `Hold.processStartedAt`.
- Produces: `TeainateService.init(..., startTimes: any ProcessStartTimeReading = ProcPIDInfoStartTimeReader())`; `standard()` passes the same reader to the store and the service.

- [ ] **Step 1: Write the failing tests**

`ServiceTests.swift` (extend `makeService` with `startTimes: (any ProcessStartTimeReading)? = nil`, passing it to both `HoldStore` and `TeainateService` when non-nil):

```swift
private struct StubStartTimes: ProcessStartTimeReading {
    var times: [pid_t: ProcessStartTime]
    func startTime(of pid: pid_t) -> ProcessStartTime? { times[pid] }
}

@Test func onRecordsTheSpawnedProcessStartTime() throws {
    let t = ProcessStartTime(seconds: 1_000, microseconds: 7)
    let service = makeService(snapshotter: StubSnapshotter(table: liveTable(100)),
                              startTimes: StubStartTimes(times: [100: t]))
    let hold = try service.on(HoldOptions(source: .cli))
    #expect(hold.processStartedAt == t)
    #expect(try service.status().holds.map(\.id) == [hold.id])
}

@Test func holdWhoseProcessDiedInstantlyIsStillRecordedThenReconciledAway() throws {
    // startTime returns nil right after spawn: record without a stamp; the next read
    // drops it by pid/name as before.
    let service = makeService(snapshotter: StubSnapshotter(table: [:]),
                              startTimes: StubStartTimes(times: [:]))
    let hold = try service.on(HoldOptions(source: .cli))
    #expect(hold.processStartedAt == nil)
    #expect(try service.status().holds.isEmpty)
}
```

`RealCaffeinateTests.swift`:

```swift
// The recycling gap, closed: a record that carries process A's start time must not
// adopt process B just because B reuses A's pid and name. We cannot force the kernel to
// reuse a pid, so the test transplants A's stamp onto B's pid — the exact state a
// recycled record would be in.
@Test func realStartTimeDistinguishesTwoCaffeinateProcesses() throws {
    let spawner = SystemCaffeinateSpawner()
    let reader = ProcPIDInfoStartTimeReader()
    let a = try spawner.spawn(flags: ["-i", "-t", "20"])
    defer { spawner.terminate(pid: a) }
    let b = try spawner.spawn(flags: ["-i", "-t", "20"])
    defer { spawner.terminate(pid: b) }

    let startA = try #require(reader.startTime(of: a))
    let table = try PSProcessSnapshotter().snapshot()

    var genuine = Hold(id: "a", kind: .timer, label: nil, source: .cli, caffeinatePID: a, flags: ["-i"],
                       startedAt: Date(), expiresAt: nil, watchedPID: nil, display: false, acOnly: false)
    genuine.processStartedAt = startA
    #expect(reconcile([genuine], against: table, startTime: reader.startTime(of:)).map(\.id) == ["a"])

    var recycled = genuine
    recycled.id = "recycled"
    recycled.caffeinatePID = b                    // b's pid, a's start time
    #expect(reconcile([recycled], against: table, startTime: reader.startTime(of:)).isEmpty)
}

@Test func realServiceRecordsStartTimeAndSurvivesReads() throws {
    let (service, _) = realService()
    let hold = try service.on(HoldOptions(duration: 20, source: .cli))
    defer { _ = try? service.off(id: nil) }
    #expect(hold.processStartedAt != nil)
    #expect(hold.processStartedAt == ProcPIDInfoStartTimeReader().startTime(of: hold.caffeinatePID))
    #expect(try service.status().holds.map(\.id) == [hold.id])
}
```

- [ ] **Step 2: Run to verify they fail** — compile error on `startTimes:`.

- [ ] **Step 3: Implement**

`TeainateService` gains `private let startTimes: any ProcessStartTimeReading`, init param `startTimes: any ProcessStartTimeReading = ProcPIDInfoStartTimeReader()` (append), and `standard()` creates one reader and passes it to both `HoldStore(fileURL:snapshotter:startTimes:)` and the service. In both `on` paths, immediately after the spawn returns `pid`:

```swift
        // Read before recording: a stamp taken later could belong to a recycled pid.
        let startedAt = startTimes.startTime(of: pid)
```

and pass `processStartedAt: startedAt` into `Hold(...)`.

- [ ] **Step 4: Run everything**

Run: `swift test` — PASS (both integration tests included).

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateCore Tests
git commit -m "feat(core): record process start times and prove them against real caffeinate"
```

---

### Task 7: Skill, version, docs, followups cleanup

**Files:**
- Modify: `Sources/TeainateCore/SkillInstaller.swift`, `Sources/TeainateCore/Version.swift`, `Resources/Info.plist`, `README.md`, `docs/followups.md`
- Test: `Tests/TeainateCoreTests/SkillInstallerTests.swift`

- [ ] **Step 1: Failing test**

```swift
@Test func skillExplainsPmsetAvailability() {
    let text = renderSkillTemplate(cliPath: "/x/teainate")
    #expect(text.contains("pmset_available"))
}
```

- [ ] **Step 2: Skill text** — in the "Checking state" section, after the sentence about `foreign_assertions`, add: "If `pmset_available` is false, `foreign_assertions` is empty because `pmset` could not be read, not because nothing else is holding the Mac awake — say so rather than concluding the Mac is free to sleep. `lid_closed.flag_set` is `null` when the kernel flag could not be read; `lid_closed.warnings` lists anything the user should know."

- [ ] **Step 3: Version** — `0.2.1` in `Version.swift` and `Resources/Info.plist`.

- [ ] **Step 4: README** — replace the paragraph ending "which is not implemented." with: "Since 0.2.1 each record also carries the process's exact start time (`process_started_at`, read from the kernel with `proc_pidinfo`), and reconciliation requires both the PID and the start time to match, so a recycled PID is never adopted. Records written by earlier versions match by name only until they end."

- [ ] **Step 5: followups.md** — delete the entries now resolved: "Lid-closed holds: what the user is told about the flag" (keep only the two sub-items still open as a shorter entry: the modal `NSAlert`, and the 30 s expiry lag), "Distinguish pmset failed…", "Stop leaking raw Swift enum names…", "Make the duration overflow trap impossible…", "Close the PID-recycling gap properly", and in Smaller: "State-file corruption recovers silently" and "The `"caffeinate"` literal is compared in three places". Keep everything else.

- [ ] **Step 6: Run everything** — `swift test` PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/TeainateCore/SkillInstaller.swift Sources/TeainateCore/Version.swift Resources/Info.plist README.md docs/followups.md Tests/TeainateCoreTests/SkillInstallerTests.swift
git commit -m "docs: status honesty and PID identity; bump to 0.2.1"
```
