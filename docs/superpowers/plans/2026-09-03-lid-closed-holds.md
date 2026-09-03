# Lid-Closed Holds Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--lid-closed` modifier that keeps a MacBook awake with the lid shut by setting the kernel `SleepDisabled` flag for exactly the life of one hold, with a battery floor and crash-safe cleanup.

**Architecture:** A lid-closed hold's recorded PID is a *watcher* (the `teainate` binary run as a hidden `lid-watch` subcommand) instead of a bare `caffeinate`. The service sets the flag through a literal two-command sudoers grant, spawns the watcher, and records the hold plus an ownership marker. The watcher owns one `caffeinate -w <own pid>` child, polls battery and liveness every 30 s, and clears the flag when the last lid-closed hold ends. Every read clears an orphaned flag the marker says teainate owns.

**Tech Stack:** Swift 6.3 (`swiftLanguageModes: [.v6]`), Swift Testing, swift-argument-parser, `/usr/bin/pmset`, `/usr/bin/sudo -n`, `/usr/sbin/visudo`.

**Spec:** `docs/superpowers/specs/2026-09-03-lid-closed-holds-design.md`

## Global Constraints

- Core must never import AppKit. App and CLI never spawn processes directly; everything goes through `TeainateService` (the `lid-watch` subcommand runs Core's `LidWatchRunner`, which is Core).
- `MenuRenderer` contains no decisions. Every show/enable/check decision lives in `MenuModel.swift`.
- Use `ucomm=` process names, never `comm=`. The constant for the watcher's name is `"teainate"`; for caffeinate it is `"caffeinate"`.
- JSON keys are snake_case. Every new type is `Sendable`. Tests use `import Testing` and `#expect`.
- Failures the user asked for fail loudly: non-zero exit on stderr via `FriendlyError`.
- **Never run `sudo pmset -a disablesleep` from a test.** Real-process tests pass `--no-flag` to the watcher and never construct `SudoSleepFlagController`. Every spawned `caffeinate` gets a short `-t` and a `defer` cleanup.
- Default battery floor 15, valid 5…50, choices 5/10/15/20/30/40/50. CLI lid-closed `--for` cap 8 hours. Rail check interval 30 s.
- Sudoers rule, exactly: `<user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0`, file `/etc/sudoers.d/teainate-<user>` mode 0440.
- Run `swift test --filter TeainateCoreTests` after every task; the full `swift test` after Tasks 9, 10 and 15.

---

## File map

| File | Responsibility |
| --- | --- |
| `Sources/TeainateCore/Hold.swift` | `Hold`/`HoldOptions` gain `lidClosed`, `batteryFloor`; `caffeinateFlags` omits `-w` for lid-closed. |
| `Sources/TeainateCore/HoldStore.swift` | `StoreState` (holds + `lid_flag_owned` + `last_ended`), `readState`/`mutateState`, kind-aware `reconcile`, `ownedPIDs`. |
| `Sources/TeainateCore/Battery.swift` (new) | `BatteryState`, `parseBatteryOutput`, `BatteryReading`, `PMSetBatteryReader`. |
| `Sources/TeainateCore/SleepFlag.swift` (new) | `SleepFlagControlling`, `parseSleepDisabled`, `SudoSleepFlagController`. |
| `Sources/TeainateCore/SudoersGrant.swift` (new) | `PrivilegeGranting`, `SudoersGrant` (rule, path, install/remove scripts, `isGranted`). |
| `Sources/TeainateCore/Settings.swift` (new) | `Settings`, `SettingsStore`, floor constants. |
| `Sources/TeainateCore/Paths.swift` | `settingsFile`, `lidWatchLog`. |
| `Sources/TeainateCore/LidWatch.swift` (new) | `WatcherEndReason`, `watcherDecision`, `LidWatchConfig`, `lidWatchArguments`, `watcherChildFlags`, `LidWatchRunner`, `StopFlag`, `ProcessLiveness`. |
| `Sources/TeainateCore/TeainateService.swift` | `LidClosedDependencies`, `WatcherSpawning`, lid-closed `on`, orphan cleanup, `LidClosedStatus`. |
| `Sources/TeainateCore/StatusRendering.swift` | Lid modifiers in `describe`, lid-closed lines in `renderStatus`. |
| `Sources/TeainateCore/MenuModel.swift` | New actions, preference, modifier row, enable/floor/disable group, submenu support. |
| `Sources/TeainateCore/Duration.swift` | `maxLidClosedDurationSeconds`, `lidClosedCommandLineProblem`. |
| `Sources/TeainateCore/SkillInstaller.swift` | Skill text for `--lid-closed`. |
| `Sources/teainate/Teainate.swift` | `--lid-closed` on `on`, hidden `lid-watch` subcommand, error mapping. |
| `Sources/TeainateApp/MenuRenderer.swift` | Submenu rendering. |
| `Sources/TeainateApp/AppDelegate.swift` | New actions, admin script runner, ended-hold alert. |

---

### Task 1: Hold fields and the state-file object shape

**Files:**
- Modify: `Sources/TeainateCore/Hold.swift`
- Modify: `Sources/TeainateCore/HoldStore.swift`
- Test: `Tests/TeainateCoreTests/HoldStoreTests.swift`, `Tests/TeainateCoreTests/HoldFlagTests.swift`

**Interfaces:**
- Produces: `Hold.lidClosed: Bool`, `Hold.batteryFloor: Int?` (init params appended with defaults `false`/`nil`); `HoldOptions.lidClosed: Bool` (param after `label`, default `false`); `EndedHold`; `StoreState { holds, lidFlagOwned, lastEnded }`; `HoldStore.readState()`, `HoldStore.mutateState(_:)`. `read()`/`mutate(_:)` keep working.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TeainateCoreTests/HoldStoreTests.swift`:

```swift
@Test func oldArrayShapedStateFileStillLoads() throws {
    let url = tempFile()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let legacy = """
    [{"ac_only":false,"caffeinate_pid":100,"display":false,"flags":["-i"],"id":"a",
      "kind":"forever","source":"cli","started_at":"1970-01-01T00:00:00Z"}]
    """
    try legacy.write(to: url, atomically: true, encoding: .utf8)
    let store = HoldStore(fileURL: url, snapshotter: FakeSnapshotter(table: table((100, "caffeinate"))))

    let state = try store.readState()
    #expect(state.holds.map(\.id) == ["a"])
    #expect(state.holds.first?.lidClosed == false)
    #expect(state.holds.first?.batteryFloor == nil)
    #expect(state.lidFlagOwned == false)
    #expect(state.lastEnded == nil)
}

@Test func statePersistsAsObjectWithMarkerAndLastEnded() throws {
    let url = tempFile()
    let store = HoldStore(fileURL: url, snapshotter: FakeSnapshotter(table: [:]))
    let ended = EndedHold(id: "h_x", label: "build", reason: "battery 14% at floor 15%",
                          at: Date(timeIntervalSince1970: 1_000))
    try store.mutateState { state in
        state.lidFlagOwned = true
        state.lastEnded = ended
    }
    let raw = try String(contentsOf: url, encoding: .utf8)
    #expect(raw.contains("\"lid_flag_owned\" : true"))
    #expect(raw.contains("\"last_ended\""))

    let reread = try store.readState()
    #expect(reread.lidFlagOwned == true)
    #expect(reread.lastEnded == ended)
}

@Test func lidClosedHoldRoundTripsItsFields() throws {
    let store = HoldStore(fileURL: tempFile(), snapshotter: FakeSnapshotter(table: table((100, "teainate"))))
    var lid = hold("l", pid: 100)
    lid.lidClosed = true
    lid.batteryFloor = 20
    try store.mutate { $0.append(lid) }
    let back = try store.read().first
    #expect(back?.lidClosed == true)
    #expect(back?.batteryFloor == 20)
}
```

(The `table((100, "teainate"))` fixture will only keep the hold after Task 2; for now the third test is expected to fail on reconciliation too. That is fine: it goes green in Task 2.)

Append to `Tests/TeainateCoreTests/HoldFlagTests.swift`:

```swift
// A lid-closed hold's caffeinate is spawned by the watcher, which needs the single
// `-w` slot for its own pid. The user's watched process is polled by the watcher instead.
@Test func lidClosedFlagsOmitTheWatchedPID() {
    var options = opts(watchedPID: 6707)
    options.lidClosed = true
    #expect(caffeinateFlags(for: options) == ["-i"])
}

@Test func lidClosedKeepsTimerAndDisplayFlags() {
    var options = opts(duration: 600, display: true)
    options.lidClosed = true
    #expect(caffeinateFlags(for: options) == ["-i", "-d", "-t", "600"])
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TeainateCoreTests`
Expected: compile errors (`readState`, `lidClosed`, `EndedHold` undefined).

- [ ] **Step 3: Extend `Hold.swift`**

In `HoldOptions`, add a stored property and init parameter (keep argument order: after `label`, before `source`):

```swift
    public var label: String?
    /// Keep the Mac awake even with the lid closed. Needs the sudoers grant; see LidWatch.swift.
    public var lidClosed: Bool
    public var source: HoldSource

    public init(
        duration: TimeInterval? = nil,
        watchedPID: pid_t? = nil,
        acOnly: Bool = false,
        display: Bool = false,
        label: String? = nil,
        lidClosed: Bool = false,
        source: HoldSource
    ) {
        self.duration = duration
        self.watchedPID = watchedPID
        self.acOnly = acOnly
        self.display = display
        self.label = label
        self.lidClosed = lidClosed
        self.source = source
    }
```

In `caffeinateFlags(for:)`, change the `-w` branch:

```swift
    // The watcher of a lid-closed hold owns caffeinate's single `-w` slot (see
    // `watcherChildFlags`); it polls the user's watched pid itself.
    if let pid = options.watchedPID, !options.lidClosed {
        flags.append(contentsOf: ["-w", String(pid)])
    }
```

In `Hold`, add two properties, two init parameters (appended, defaulted), two coding keys, and an explicit decoder so files written before this feature still load:

```swift
    public var acOnly: Bool
    /// True when `caffeinatePID` is a `teainate lid-watch` watcher rather than caffeinate.
    public var lidClosed: Bool
    /// The battery floor this hold was taken with. Never changes after the fact.
    public var batteryFloor: Int?

    public init(
        id: String, kind: HoldKind, label: String?, source: HoldSource,
        caffeinatePID: pid_t, flags: [String], startedAt: Date, expiresAt: Date?,
        watchedPID: pid_t?, display: Bool, acOnly: Bool,
        lidClosed: Bool = false, batteryFloor: Int? = nil
    ) {
        // ...existing assignments...
        self.lidClosed = lidClosed
        self.batteryFloor = batteryFloor
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, label, source, flags, display
        case caffeinatePID = "caffeinate_pid"
        case startedAt = "started_at"
        case expiresAt = "expires_at"
        case watchedPID = "watched_pid"
        case acOnly = "ac_only"
        case lidClosed = "lid_closed"
        case batteryFloor = "battery_floor"
    }

    /// Explicit so records written before lid-closed holds existed still decode.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(HoldKind.self, forKey: .kind)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        source = try c.decode(HoldSource.self, forKey: .source)
        caffeinatePID = try c.decode(pid_t.self, forKey: .caffeinatePID)
        flags = try c.decode([String].self, forKey: .flags)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        watchedPID = try c.decodeIfPresent(pid_t.self, forKey: .watchedPID)
        display = try c.decode(Bool.self, forKey: .display)
        acOnly = try c.decode(Bool.self, forKey: .acOnly)
        lidClosed = try c.decodeIfPresent(Bool.self, forKey: .lidClosed) ?? false
        batteryFloor = try c.decodeIfPresent(Int.self, forKey: .batteryFloor)
    }
```

Add, at the end of `Hold.swift`:

```swift
/// Why the most recent lid-closed hold ended on its own. The hold's record is removed
/// when it ends, so this is the only place `status` can learn the reason.
public struct EndedHold: Codable, Sendable, Equatable {
    public var id: String
    public var label: String?
    public var reason: String
    public var at: Date

    public init(id: String, label: String?, reason: String, at: Date) {
        self.id = id
        self.label = label
        self.reason = reason
        self.at = at
    }
}

/// Everything in `holds.json`. `lidFlagOwned` is true while teainate believes it set the
/// kernel sleep-disabled flag; it is the fact orphan cleanup keys off.
public struct StoreState: Codable, Sendable, Equatable {
    public var holds: [Hold]
    public var lidFlagOwned: Bool
    public var lastEnded: EndedHold?

    public init(holds: [Hold] = [], lidFlagOwned: Bool = false, lastEnded: EndedHold? = nil) {
        self.holds = holds
        self.lidFlagOwned = lidFlagOwned
        self.lastEnded = lastEnded
    }

    enum CodingKeys: String, CodingKey {
        case holds
        case lidFlagOwned = "lid_flag_owned"
        case lastEnded = "last_ended"
    }

    /// Accepts both the current object shape and the original bare array.
    public init(from decoder: any Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self),
           c.contains(.holds) {
            holds = try c.decode([Hold].self, forKey: .holds)
            lidFlagOwned = try c.decodeIfPresent(Bool.self, forKey: .lidFlagOwned) ?? false
            lastEnded = try c.decodeIfPresent(EndedHold.self, forKey: .lastEnded)
        } else {
            holds = try decoder.singleValueContainer().decode([Hold].self)
            lidFlagOwned = false
            lastEnded = nil
        }
    }
}
```

- [ ] **Step 4: Extend `HoldStore.swift`**

Replace `read()`, `mutate`, `loadRaw`, `persist` with:

```swift
    public func read() throws -> [Hold] {
        try readState().holds
    }

    public func readState() throws -> StoreState {
        try mutateState { $0 }
    }

    /// Holds-only view for callers that do not care about the lid-closed marker.
    public func mutate<T>(_ body: (inout [Hold]) throws -> T) throws -> T {
        try mutateState { try body(&$0.holds) }
    }

    /// Reconciles, applies `body`, and persists — all under an exclusive lock so the
    /// app, the CLI and every watcher cannot interleave a read-modify-write.
    public func mutateState<T>(_ body: (inout StoreState) throws -> T) throws -> T {
        try ensureDirectoryExists()
        let descriptor = try acquireLock()
        defer { flock(descriptor, LOCK_UN); close(descriptor) }

        var state = loadRaw()
        state.holds = reconcile(state.holds, against: try snapshotter.snapshot())
        let result = try body(&state)
        try persist(state)
        return result
    }
```

and

```swift
    private func loadRaw() -> StoreState {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return StoreState() }
        do {
            return try Hold.decoder.decode(StoreState.self, from: data)
        } catch {
            // Never crash over a bad file: preserve it for diagnosis and start clean.
            let backup = fileURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return StoreState()
        }
    }

    private func persist(_ state: StoreState) throws {
        let data = try Hold.encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter TeainateCoreTests`
Expected: all pass except `lidClosedHoldRoundTripsItsFields` (reconciliation still demands `caffeinate`). Existing `readPersistsReconciliation` still passes: the stale id must not appear in the object either.

- [ ] **Step 6: Commit**

```bash
git add Sources/TeainateCore/Hold.swift Sources/TeainateCore/HoldStore.swift Tests/TeainateCoreTests/HoldStoreTests.swift Tests/TeainateCoreTests/HoldFlagTests.swift
git commit -m "feat(core): lid-closed hold fields and object-shaped state file"
```

---

### Task 2: Reconcile by hold kind and account for watcher children

**Files:**
- Modify: `Sources/TeainateCore/HoldStore.swift` (top of file)
- Test: `Tests/TeainateCoreTests/HoldStoreTests.swift`

**Interfaces:**
- Produces: `caffeinateProcessName`, `watcherProcessName`, `expectedProcessName(for:)`, `ownedPIDs(of:in:) -> Set<pid_t>`.

- [ ] **Step 1: Write the failing tests**

```swift
private func lidHold(_ id: String, pid: pid_t) -> Hold {
    var h = hold(id, pid: pid)
    h.lidClosed = true
    return h
}

@Test func reconcileKeepsLidClosedHoldWhosePIDIsTheWatcher() {
    let kept = reconcile([lidHold("l", pid: 100)], against: table((100, "teainate")))
    #expect(kept.map(\.id) == ["l"])
}

@Test func reconcileDropsLidClosedHoldWhosePIDIsNowCaffeinate() {
    // A watcher's pid recycled by a bare caffeinate is not our watcher.
    let kept = reconcile([lidHold("l", pid: 100)], against: table((100, "caffeinate")))
    #expect(kept.isEmpty)
}

@Test func reconcileDropsOrdinaryHoldWhosePIDIsNowTeainate() {
    let kept = reconcile([hold("a", pid: 100)], against: table((100, "teainate")))
    #expect(kept.isEmpty)
}

@Test func ownedPIDsIncludeWatcherAndItsCaffeinateChild() {
    var t = table((100, "teainate"), (200, "caffeinate"), (300, "caffeinate"))
    t[200] = ProcessSnapshot(pid: 200, parentPID: 100, command: "caffeinate", arguments: "caffeinate -i -w 100")
    let owned = ownedPIDs(of: [lidHold("l", pid: 100)], in: t)
    #expect(owned == [100, 200])   // 300 is somebody else's
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TeainateCoreTests`
Expected: `ownedPIDs` undefined; the first reconcile test fails.

- [ ] **Step 3: Implement**

Replace the `reconcile` function and its doc comment with:

```swift
public let caffeinateProcessName = "caffeinate"
/// The watcher is the CLI binary itself, so `ucomm` reports the executable's name.
public let watcherProcessName = "teainate"

/// The `ucomm` a live hold's recorded pid must carry to still be ours.
public func expectedProcessName(for hold: Hold) -> String {
    hold.lidClosed ? watcherProcessName : caffeinateProcessName
}

/// Drops holds whose PID is gone, or now belongs to a process of the wrong kind.
/// This is what lets a plain file be a safe source of truth: a stale record can exist
/// after a crash, but never survives the next read.
///
/// This does NOT protect against a PID being recycled by another process of the same
/// name — see docs/followups.md ("Close the PID-recycling gap properly").
public func reconcile(_ holds: [Hold], against table: [pid_t: ProcessSnapshot]) -> [Hold] {
    holds.filter { table[$0.caffeinatePID]?.command == expectedProcessName(for: $0) }
}

/// Every pid teainate is responsible for: the hold processes themselves plus the
/// caffeinate child of each lid-closed watcher. Without the children, a watcher's own
/// caffeinate would be listed — and reclaimable — as "not managed by teainate".
public func ownedPIDs(of holds: [Hold], in table: [pid_t: ProcessSnapshot]) -> Set<pid_t> {
    var owned = Set(holds.map(\.caffeinatePID))
    let watchers = Set(holds.filter(\.lidClosed).map(\.caffeinatePID))
    for entry in table.values
    where entry.command == caffeinateProcessName && watchers.contains(entry.parentPID) {
        owned.insert(entry.pid)
    }
    return owned
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter TeainateCoreTests`
Expected: PASS, including `lidClosedHoldRoundTripsItsFields` from Task 1.

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateCore/HoldStore.swift Tests/TeainateCoreTests/HoldStoreTests.swift
git commit -m "feat(core): reconcile lid-closed holds against the watcher process name"
```

---

### Task 3: Battery reading

**Files:**
- Create: `Sources/TeainateCore/Battery.swift`
- Test: `Tests/TeainateCoreTests/BatteryTests.swift`

**Interfaces:**
- Produces: `PowerSource { ac, battery }`, `BatteryState { source, percent: Int? }`, `parseBatteryOutput(_:) -> BatteryState?`, `protocol BatteryReading { func read() throws -> BatteryState? }`, `PMSetBatteryReader`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import TeainateCore

// Captured from a MacBook (M4, macOS 26.6) — real output, not a guess.
private let onAC = """
Now drawing from 'AC Power'
 -InternalBattery-0 (id=22872163)\t97%; AC attached; not charging present: true
"""
private let onBattery = """
Now drawing from 'Battery Power'
 -InternalBattery-0 (id=22872163)\t83%; discharging; 4:31 remaining present: true
"""
private let charging = """
Now drawing from 'AC Power'
 -InternalBattery-0 (id=22872163)\t45%; charging; 1:20 remaining present: true
"""
private let desktop = "Now drawing from 'AC Power'\n"

@Test func parsesACPower() {
    #expect(parseBatteryOutput(onAC) == BatteryState(source: .ac, percent: 97))
}

@Test func parsesBatteryPower() {
    #expect(parseBatteryOutput(onBattery) == BatteryState(source: .battery, percent: 83))
}

@Test func chargingCountsAsAC() {
    #expect(parseBatteryOutput(charging) == BatteryState(source: .ac, percent: 45))
}

@Test func desktopHasNoPercent() {
    #expect(parseBatteryOutput(desktop) == BatteryState(source: .ac, percent: nil))
}

@Test func garbageIsNil() {
    #expect(parseBatteryOutput("") == nil)
    #expect(parseBatteryOutput("pmset: unrecognized") == nil)
}

@Test func realPmsetBatteryOutputParses() throws {
    // The one test that touches real pmset. Any Mac reports a power source.
    let state = try PMSetBatteryReader().read()
    #expect(state != nil)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter BatteryTests`
Expected: compile error, `parseBatteryOutput` undefined.

- [ ] **Step 3: Implement `Battery.swift`**

```swift
import Foundation

public enum PowerSource: String, Sendable, Codable, Equatable {
    case ac, battery
}

public struct BatteryState: Sendable, Equatable {
    public let source: PowerSource
    /// nil on a Mac with no battery.
    public let percent: Int?

    public init(source: PowerSource, percent: Int?) {
        self.source = source
        self.percent = percent
    }
}

public protocol BatteryReading: Sendable {
    /// nil means the output could not be parsed. Callers treat that as "unknown",
    /// never as "on battery" or "at the floor".
    func read() throws -> BatteryState?
}

/// Parses `pmset -g batt`. First line: `Now drawing from 'Battery Power'` or `'AC Power'`.
/// Optional second line: ` -InternalBattery-0 (id=…)<tab>83%; discharging; …`.
public func parseBatteryOutput(_ text: String) -> BatteryState? {
    let lines = text.split(separator: "\n").map(String.init)
    guard let sourceLine = lines.first(where: { $0.contains("Now drawing from") }) else { return nil }
    let source: PowerSource = sourceLine.contains("Battery Power") ? .battery : .ac

    var percent: Int?
    if let batteryLine = lines.first(where: { $0.contains("InternalBattery") }),
       let range = batteryLine.range(of: #"\d+%"#, options: .regularExpression) {
        percent = Int(batteryLine[range].dropLast())
    }
    return BatteryState(source: source, percent: percent)
}

public struct PMSetBatteryReader: BatteryReading {
    public init() {}

    public func read() throws -> BatteryState? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseBatteryOutput(String(decoding: data, as: UTF8.self))
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter BatteryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateCore/Battery.swift Tests/TeainateCoreTests/BatteryTests.swift
git commit -m "feat(core): read battery state from pmset -g batt"
```

---

### Task 4: Sleep flag controller

**Files:**
- Create: `Sources/TeainateCore/SleepFlag.swift`
- Test: `Tests/TeainateCoreTests/SleepFlagTests.swift`

**Interfaces:**
- Produces: `SleepFlagError.commandFailed(status:message:)`, `protocol SleepFlagControlling { set(); clear(); isSet() throws -> Bool }`, `parseSleepDisabled(_:) -> Bool`, `SudoSleepFlagController`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import TeainateCore

@Test func sleepDisabledOneIsSet() {
    let out = " System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n standby 1\n"
    #expect(parseSleepDisabled(out) == true)
}

@Test func sleepDisabledZeroIsNotSet() {
    #expect(parseSleepDisabled(" SleepDisabled        0\n") == false)
}

@Test func missingSleepDisabledIsNotSet() {
    #expect(parseSleepDisabled(" sleep 1\n hibernatemode 3\n") == false)
}

@Test func realPmsetGlobalOutputParsesWithoutPrivilege() throws {
    // Reading is unprivileged; this must never prompt. Its value is unknown here.
    _ = try SudoSleepFlagController().isSet()
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter SleepFlagTests`
Expected: compile error.

- [ ] **Step 3: Implement `SleepFlag.swift`**

```swift
import Foundation

public enum SleepFlagError: Error, Equatable {
    case commandFailed(status: Int32, message: String)
}

/// The kernel's SleepDisabled flag (`pmset -a disablesleep`). Setting and clearing
/// need root and go through the literal sudoers grant; reading does not.
public protocol SleepFlagControlling: Sendable {
    func set() throws
    func clear() throws
    func isSet() throws -> Bool
}

/// Parses `pmset -g`. The line is ` SleepDisabled<whitespace>1` when set; absent or 0 otherwise.
public func parseSleepDisabled(_ text: String) -> Bool {
    for line in text.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if fields.count >= 2, fields[0] == "SleepDisabled" {
            return fields[1] == "1"
        }
    }
    return false
}

public struct SudoSleepFlagController: SleepFlagControlling {
    public init() {}

    public func set() throws { try sudo(["/usr/bin/pmset", "-a", "disablesleep", "1"]) }
    public func clear() throws { try sudo(["/usr/bin/pmset", "-a", "disablesleep", "0"]) }

    public func isSet() throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseSleepDisabled(String(decoding: data, as: UTF8.self))
    }

    /// `-n` never prompts: without the grant this fails immediately with a message,
    /// which is what an unattended CLI or skill needs.
    private func sudo(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n"] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SleepFlagError.commandFailed(
                status: process.terminationStatus,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter SleepFlagTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateCore/SleepFlag.swift Tests/TeainateCoreTests/SleepFlagTests.swift
git commit -m "feat(core): sleep-disabled flag controller over sudo -n pmset"
```

---

### Task 5: Sudoers grant

**Files:**
- Create: `Sources/TeainateCore/SudoersGrant.swift`
- Test: `Tests/TeainateCoreTests/SudoersGrantTests.swift`

**Interfaces:**
- Produces: `protocol PrivilegeGranting { func isGranted() -> Bool }`, `SudoersGrant(username:directory:)` with `rule`, `fileURL`, `isGranted()`, `installScript() throws -> String`, `removeScript() throws -> String`, `GrantError.invalidUsername`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import TeainateCore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("teainate-sudoers-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func ruleIsExactlyTheTwoLiteralCommands() {
    let grant = SudoersGrant(username: "denver", directory: URL(fileURLWithPath: "/etc/sudoers.d"))
    #expect(grant.rule ==
        "denver ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0")
    #expect(grant.fileURL.path == "/etc/sudoers.d/teainate-denver")
}

@Test func fileNameNeverContainsADot() {
    // sudo silently ignores sudoers.d files whose names contain '.'.
    let grant = SudoersGrant(username: "first.last", directory: URL(fileURLWithPath: "/etc/sudoers.d"))
    #expect(grant.fileURL.lastPathComponent == "teainate-first_last")
}

@Test func notGrantedWhenFileMissing() throws {
    #expect(SudoersGrant(username: "u", directory: try tempDir()).isGranted() == false)
}

@Test func grantedWhenFileHoldsExactlyTheRule() throws {
    let grant = SudoersGrant(username: "u", directory: try tempDir())
    try (grant.rule + "\n").write(to: grant.fileURL, atomically: true, encoding: .utf8)
    #expect(grant.isGranted() == true)
}

@Test func notGrantedWhenFileHoldsSomethingElse() throws {
    let grant = SudoersGrant(username: "u", directory: try tempDir())
    try "u ALL=(ALL) NOPASSWD: ALL\n".write(to: grant.fileURL, atomically: true, encoding: .utf8)
    #expect(grant.isGranted() == false)
}

@Test func installScriptValidatesWithVisudoBeforeMoving() throws {
    let script = try SudoersGrant(username: "u", directory: try tempDir()).installScript()
    #expect(script.contains("/usr/sbin/visudo -c -f"))
    #expect(script.contains("chmod 0440"))
    #expect(script.contains("NOPASSWD: /usr/bin/pmset -a disablesleep 1"))
}

@Test func unsafeUsernameIsRefused() throws {
    let grant = SudoersGrant(username: "bad user; rm -rf /", directory: try tempDir())
    #expect(throws: GrantError.invalidUsername) { try grant.installScript() }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter SudoersGrantTests`
Expected: compile error.

- [ ] **Step 3: Implement `SudoersGrant.swift`**

```swift
import Foundation

public enum GrantError: Error, Equatable {
    case invalidUsername
}

public protocol PrivilegeGranting: Sendable {
    /// A file read, never a `sudo -n` probe: `status` must stay cheap and must never prompt.
    func isGranted() -> Bool
}

/// The one-time grant that lets `sudo -n pmset -a disablesleep 0|1` run without a
/// password. sudoers matches arguments literally, so nothing else can be run through it.
public struct SudoersGrant: PrivilegeGranting {
    public let username: String
    public let directory: URL

    public init(
        username: String = NSUserName(),
        directory: URL = URL(fileURLWithPath: "/etc/sudoers.d")
    ) {
        self.username = username
        self.directory = directory
    }

    public var rule: String {
        "\(username) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
    }

    /// Per-user so two users on one Mac cannot overwrite each other's grant. sudo
    /// ignores files whose names contain '.', so a dotted username is mangled.
    public var fileURL: URL {
        directory.appendingPathComponent("teainate-" + username.replacingOccurrences(of: ".", with: "_"))
    }

    public func isGranted() -> Bool {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        return content.trimmingCharacters(in: .whitespacesAndNewlines) == rule
    }

    /// Bourne shell, run as root by the app's admin dialog. Writes to a `.tmp` sibling
    /// (ignored by sudo while it exists), validates, then moves into place.
    public func installScript() throws -> String {
        try validateUsername()
        let file = fileURL.path
        return """
        set -e
        umask 077
        printf '%s\\n' '\(rule)' > '\(file).tmp'
        chmod 0440 '\(file).tmp'
        if /usr/sbin/visudo -c -f '\(file).tmp' >/dev/null 2>&1; then
          mv '\(file).tmp' '\(file)'
        else
          rm -f '\(file).tmp'
          exit 1
        fi
        """
    }

    public func removeScript() throws -> String {
        try validateUsername()
        return "rm -f '\(fileURL.path)'"
    }

    private func validateUsername() throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !username.isEmpty,
              username.unicodeScalars.allSatisfy(allowed.contains)
        else { throw GrantError.invalidUsername }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter SudoersGrantTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateCore/SudoersGrant.swift Tests/TeainateCoreTests/SudoersGrantTests.swift
git commit -m "feat(core): literal two-command sudoers grant"
```

---

### Task 6: Settings file and new paths

**Files:**
- Create: `Sources/TeainateCore/Settings.swift`
- Modify: `Sources/TeainateCore/Paths.swift`
- Test: `Tests/TeainateCoreTests/SettingsTests.swift`

**Interfaces:**
- Produces: `defaultBatteryFloor = 15`, `batteryFloorRange = 5...50`, `batteryFloorChoices`, `Settings { batteryFloor }`, `SettingsStore(fileURL:)` with `read() -> (settings: Settings, warning: String?)` and `write(_:) throws`, `SettingsError.floorOutOfRange(Int)`; `TeainatePaths.settingsFile`, `TeainatePaths.lidWatchLog`, `lidWatchLogURL(besideStateFile:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import TeainateCore

private func tempSettings() -> SettingsStore {
    SettingsStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("teainate-settings-\(UUID().uuidString)/settings.json"))
}

@Test func missingFileYieldsDefaultWithoutWarning() {
    let (settings, warning) = tempSettings().read()
    #expect(settings.batteryFloor == 15)
    #expect(warning == nil)
}

@Test func writeThenReadRoundTrips() throws {
    let store = tempSettings()
    try store.write(Settings(batteryFloor: 30))
    #expect(store.read().settings.batteryFloor == 30)
}

@Test func invalidJSONFallsBackToDefaultWithWarning() throws {
    let store = tempSettings()
    try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "{ nope".write(to: store.fileURL, atomically: true, encoding: .utf8)
    let (settings, warning) = store.read()
    #expect(settings.batteryFloor == 15)
    #expect(warning?.contains("settings.json") == true)
}

@Test func outOfRangeFloorOnDiskFallsBackToDefault() throws {
    let store = tempSettings()
    try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"battery_floor": 2}"#.write(to: store.fileURL, atomically: true, encoding: .utf8)
    let (settings, warning) = store.read()
    #expect(settings.batteryFloor == 15)
    #expect(warning != nil)
}

@Test func writeRefusesOutOfRangeFloor() {
    #expect(throws: SettingsError.floorOutOfRange(51)) { try tempSettings().write(Settings(batteryFloor: 51)) }
    #expect(throws: SettingsError.floorOutOfRange(4)) { try tempSettings().write(Settings(batteryFloor: 4)) }
}

@Test func standardPathsSitBesideTheStateFile() {
    let paths = TeainatePaths.standard(home: URL(fileURLWithPath: "/Users/x"))
    #expect(paths.settingsFile.path == "/Users/x/Library/Application Support/teainate/settings.json")
    #expect(paths.lidWatchLog.path == "/Users/x/Library/Application Support/teainate/lid-watch.log")
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter SettingsTests`
Expected: compile error.

- [ ] **Step 3: Implement `Settings.swift`**

```swift
import Foundation

public let defaultBatteryFloor = 15
public let batteryFloorRange = 5...50
public let batteryFloorChoices = [5, 10, 15, 20, 30, 40, 50]

public enum SettingsError: Error, Equatable {
    case floorOutOfRange(Int)
}

public struct Settings: Codable, Sendable, Equatable {
    public var batteryFloor: Int

    public init(batteryFloor: Int = defaultBatteryFloor) {
        self.batteryFloor = batteryFloor
    }

    enum CodingKeys: String, CodingKey {
        case batteryFloor = "battery_floor"
    }

    public static let `default` = Settings()
}

/// `settings.json` beside `holds.json`. The menu writes it; everything reads it.
/// Bad content never crashes and never yields a riskier floor than the default.
public struct SettingsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func read() -> (settings: Settings, warning: String?) {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return (.default, nil)
        }
        guard let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return (.default, "settings.json could not be read; using the default battery floor (\(defaultBatteryFloor)%)")
        }
        guard batteryFloorRange.contains(settings.batteryFloor) else {
            return (.default, "settings.json has battery_floor \(settings.batteryFloor), outside \(batteryFloorRange.lowerBound)–\(batteryFloorRange.upperBound); using \(defaultBatteryFloor)%")
        }
        return (settings, nil)
    }

    public func write(_ settings: Settings) throws {
        guard batteryFloorRange.contains(settings.batteryFloor) else {
            throw SettingsError.floorOutOfRange(settings.batteryFloor)
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Extend `Paths.swift`**

```swift
/// The watcher's log lives beside whichever state file it was given, so a test
/// pointed at a temp directory never writes into the real one.
public func lidWatchLogURL(besideStateFile stateFile: URL) -> URL {
    stateFile.deletingLastPathComponent().appendingPathComponent("lid-watch.log")
}

public struct TeainatePaths: Sendable {
    public let stateFile: URL
    public let skillDirectory: URL
    public let localBinDirectory: URL
    public let settingsFile: URL
    public var lidWatchLog: URL { lidWatchLogURL(besideStateFile: stateFile) }

    public init(stateFile: URL, skillDirectory: URL, localBinDirectory: URL, settingsFile: URL? = nil) {
        self.stateFile = stateFile
        self.skillDirectory = skillDirectory
        self.localBinDirectory = localBinDirectory
        self.settingsFile = settingsFile
            ?? stateFile.deletingLastPathComponent().appendingPathComponent("settings.json")
    }
    // `standard(home:)` unchanged.
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter TeainateCoreTests`
Expected: PASS (existing `SkillInstallerTests` still construct `TeainatePaths` with three arguments).

- [ ] **Step 6: Commit**

```bash
git add Sources/TeainateCore/Settings.swift Sources/TeainateCore/Paths.swift Tests/TeainateCoreTests/SettingsTests.swift
git commit -m "feat(core): persisted battery-floor setting"
```

---

### Task 7: Watcher decisions and argument building (pure)

**Files:**
- Create: `Sources/TeainateCore/LidWatch.swift`
- Modify: `Sources/TeainateCore/Duration.swift`
- Test: `Tests/TeainateCoreTests/LidWatchDecisionTests.swift`

**Interfaces:**
- Produces: `WatcherEndReason` (`timerExpired`, `watchedProcessExited`, `unpluggedFromAC`, `batteryAtFloor(percent:floor:)`, `released`, `caffeinateFailed(String)`) with `description` and `cutsWorkShort`; `watcherDecision(childAlive:watchedAlive:battery:floor:acOnly:) -> WatcherEndReason?`; `LidWatchConfig`; `lidWatchCommandName = "lid-watch"`; `lidWatchArguments(_:stateFile:) -> [String]`; `watcherChildFlags(caffeinateFlags:watcherPID:)`; `maxLidClosedDurationSeconds`; `lidClosedCommandLineProblem(duration:hasLifetime:) -> String?`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import TeainateCore

private func decide(
    child: Bool = true, watched: Bool? = nil,
    battery: BatteryState? = BatteryState(source: .ac, percent: 80),
    floor: Int = 15, acOnly: Bool = false
) -> WatcherEndReason? {
    watcherDecision(childAlive: child, watchedAlive: watched, battery: battery, floor: floor, acOnly: acOnly)
}

@Test func continuesWhenEverythingIsFine() {
    #expect(decide() == nil)
}

@Test func endsWhenCaffeinateChildIsGone() {
    #expect(decide(child: false) == .timerExpired)
}

@Test func endsWhenWatchedProcessIsGone() {
    #expect(decide(watched: false) == .watchedProcessExited)
}

// 14 and 16, never 15: floor-minus-one must end, floor-plus-one must continue.
@Test func endsAtOrBelowFloorOnBattery() {
    #expect(decide(battery: BatteryState(source: .battery, percent: 14)) == .batteryAtFloor(percent: 14, floor: 15))
    #expect(decide(battery: BatteryState(source: .battery, percent: 15)) == .batteryAtFloor(percent: 15, floor: 15))
    #expect(decide(battery: BatteryState(source: .battery, percent: 16)) == nil)
}

@Test func floorDoesNotApplyOnAC() {
    #expect(decide(battery: BatteryState(source: .ac, percent: 3)) == nil)
}

@Test func acOnlyEndsOnBatteryRegardlessOfPercent() {
    #expect(decide(battery: BatteryState(source: .battery, percent: 99), acOnly: true) == .unpluggedFromAC)
}

@Test func unknownBatteryContinues() {
    #expect(decide(battery: nil) == nil)
    #expect(decide(battery: BatteryState(source: .battery, percent: nil)) == nil)
}

@Test func childDeathWinsOverEverythingElse() {
    #expect(decide(child: false, watched: false, battery: BatteryState(source: .battery, percent: 1)) == .timerExpired)
}

@Test func onlyPowerReasonsCutWorkShort() {
    #expect(WatcherEndReason.batteryAtFloor(percent: 14, floor: 15).cutsWorkShort)
    #expect(WatcherEndReason.unpluggedFromAC.cutsWorkShort)
    #expect(!WatcherEndReason.timerExpired.cutsWorkShort)
    #expect(!WatcherEndReason.watchedProcessExited.cutsWorkShort)
    #expect(!WatcherEndReason.released.cutsWorkShort)
}

@Test func argumentsAreDeterministic() {
    let config = LidWatchConfig(holdID: "h_1", floor: 20, watchedPID: 6707, acOnly: true,
                                caffeinateFlags: ["-i", "-t", "600"], label: "build")
    let args = lidWatchArguments(config, stateFile: URL(fileURLWithPath: "/tmp/s/holds.json"))
    #expect(args == ["lid-watch", "--id", "h_1", "--floor", "20", "--state-file", "/tmp/s/holds.json",
                     "--caffeinate", "-i -t 600", "--watch-pid", "6707", "--ac-only", "--label", "build"])
}

@Test func childFlagsAppendTheWatcherPID() {
    #expect(watcherChildFlags(caffeinateFlags: ["-i", "-t", "600"], watcherPID: 4242) == ["-i", "-t", "600", "-w", "4242"])
}

@Test func commandLineLidClosedNeedsALifetime() {
    #expect(lidClosedCommandLineProblem(duration: nil, hasLifetime: false) != nil)
    #expect(lidClosedCommandLineProblem(duration: nil, hasLifetime: true) == nil)
}

@Test func commandLineLidClosedCapsAtEightHours() {
    #expect(lidClosedCommandLineProblem(duration: 8 * 3600, hasLifetime: true) == nil)
    #expect(lidClosedCommandLineProblem(duration: 8 * 3600 + 1, hasLifetime: true) != nil)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter LidWatchDecisionTests`
Expected: compile error.

- [ ] **Step 3: Implement the pure parts of `LidWatch.swift`**

```swift
import Foundation

public let lidWatchCommandName = "lid-watch"

public enum WatcherEndReason: Equatable, Sendable {
    case timerExpired
    case watchedProcessExited
    case unpluggedFromAC
    case batteryAtFloor(percent: Int, floor: Int)
    case released
    case caffeinateFailed(String)

    public var description: String {
        switch self {
        case .timerExpired: return "timer expired"
        case .watchedProcessExited: return "watched process exited"
        case .unpluggedFromAC: return "unplugged from AC power"
        case .batteryAtFloor(let percent, let floor): return "battery \(percent)% at floor \(floor)%"
        case .released: return "released"
        case .caffeinateFailed(let message): return "could not start caffeinate: \(message)"
        }
    }

    /// Reasons that cut work short. Only these are recorded in `last_ended`: a timer
    /// or session ending is the outcome the user asked for, not something to explain.
    public var cutsWorkShort: Bool {
        switch self {
        case .unpluggedFromAC, .batteryAtFloor: return true
        default: return false
        }
    }
}

/// One rail check. nil means keep going. Order matters: a dead child is decisive
/// regardless of power, and an unknown battery is never a reason to stop.
public func watcherDecision(
    childAlive: Bool,
    watchedAlive: Bool?,
    battery: BatteryState?,
    floor: Int,
    acOnly: Bool
) -> WatcherEndReason? {
    if !childAlive { return .timerExpired }
    if watchedAlive == false { return .watchedProcessExited }
    guard let battery, battery.source == .battery else { return nil }
    if acOnly { return .unpluggedFromAC }
    if let percent = battery.percent, percent <= floor {
        return .batteryAtFloor(percent: percent, floor: floor)
    }
    return nil
}

public struct LidWatchConfig: Sendable, Equatable {
    public var holdID: String
    public var floor: Int
    public var watchedPID: pid_t?
    public var acOnly: Bool
    /// The flags the watcher's caffeinate child gets, before `-w <watcher pid>` is added.
    public var caffeinateFlags: [String]
    public var label: String?

    public init(holdID: String, floor: Int, watchedPID: pid_t?, acOnly: Bool,
                caffeinateFlags: [String], label: String?) {
        self.holdID = holdID
        self.floor = floor
        self.watchedPID = watchedPID
        self.acOnly = acOnly
        self.caffeinateFlags = caffeinateFlags
        self.label = label
    }
}

/// Command line for `teainate lid-watch`. Caffeinate flags travel as one space-joined
/// option value so ArgumentParser never has to see `-i` as a flag of its own.
public func lidWatchArguments(_ config: LidWatchConfig, stateFile: URL) -> [String] {
    var args = [
        lidWatchCommandName,
        "--id", config.holdID,
        "--floor", String(config.floor),
        "--state-file", stateFile.path,
        "--caffeinate", config.caffeinateFlags.joined(separator: " "),
    ]
    if let pid = config.watchedPID { args += ["--watch-pid", String(pid)] }
    if config.acOnly { args.append("--ac-only") }
    if let label = config.label { args += ["--label", label] }
    return args
}

/// Ties the child to the watcher: if the watcher dies for any reason, SIGKILL
/// included, caffeinate releases on its own. This path can never orphan a caffeinate.
public func watcherChildFlags(caffeinateFlags: [String], watcherPID: pid_t) -> [String] {
    caffeinateFlags + ["-w", String(watcherPID)]
}
```

Append to `Duration.swift`:

```swift
/// CLI lid-closed holds are bounded. A human at the menu can go indefinite, because
/// the battery floor is their limit; an unattended command line gets a hard cap.
public let maxLidClosedHours: Int = 8
public let maxLidClosedDurationSeconds: TimeInterval = TimeInterval(maxLidClosedHours) * 3600

/// nil when a CLI `--lid-closed` request is acceptable; otherwise the message to refuse it with.
public func lidClosedCommandLineProblem(duration: TimeInterval?, hasLifetime: Bool) -> String? {
    if !hasLifetime {
        return "--lid-closed needs --for, --session, or --until-pid. Indefinite lid-closed holds are menu-only."
    }
    if let duration, duration > maxLidClosedDurationSeconds {
        return "Lid-closed holds are limited to \(maxLidClosedHours) hours from the command line."
    }
    return nil
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter LidWatchDecisionTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateCore/LidWatch.swift Sources/TeainateCore/Duration.swift Tests/TeainateCoreTests/LidWatchDecisionTests.swift
git commit -m "feat(core): watcher rail decisions and lid-watch argument building"
```

---

### Task 8: The watcher loop (`LidWatchRunner`)

**Files:**
- Modify: `Sources/TeainateCore/LidWatch.swift`
- Test: `Tests/TeainateCoreTests/LidWatchRunnerTests.swift`

**Interfaces:**
- Consumes: `HoldStore.mutateState`, `CaffeinateSpawning`, `BatteryReading`, `SleepFlagControlling`, `watcherDecision`, `EndedHold`.
- Produces: `protocol ProcessLiveness { func isAlive(_ pid: pid_t) -> Bool }`, `KillZeroLiveness`, `final class StopFlag` (`set()`, `isSet`), `LidWatchRunner(dependencies:)` with `run(_ config: LidWatchConfig, ownPID: pid_t, stop: StopFlag) -> WatcherEndReason`, `LidWatchRunner.Dependencies`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import TeainateCore

private final class FakeFlag: SleepFlagControlling, @unchecked Sendable {
    var setCount = 0
    var clearCount = 0
    var failClear = false
    var value = true
    func set() throws { setCount += 1; value = true }
    func clear() throws {
        if failClear { throw SleepFlagError.commandFailed(status: 1, message: "no grant") }
        clearCount += 1; value = false
    }
    func isSet() throws -> Bool { value }
}

private final class ScriptedLiveness: ProcessLiveness, @unchecked Sendable {
    /// Per pid, the answers to give in order; the last one repeats.
    var script: [pid_t: [Bool]]
    init(_ script: [pid_t: [Bool]]) { self.script = script }
    func isAlive(_ pid: pid_t) -> Bool {
        guard var answers = script[pid], !answers.isEmpty else { return false }
        let answer = answers.removeFirst()
        if !answers.isEmpty { script[pid] = answers }
        return answer
    }
}

private final class RecordingSpawner: CaffeinateSpawning, @unchecked Sendable {
    var spawned: [[String]] = []
    var terminated: [pid_t] = []
    func spawn(flags: [String]) throws -> pid_t { spawned.append(flags); return 900 }
    func terminate(pid: pid_t) { terminated.append(pid) }
}

private struct StubBattery: BatteryReading {
    var state: BatteryState?
    func read() throws -> BatteryState? { state }
}

private struct FakeSnapshotter: ProcessSnapshotting {
    let table: [pid_t: ProcessSnapshot]
    func snapshot() throws -> [pid_t: ProcessSnapshot] { table }
}

private let watcherPID: pid_t = 4242

private func lidHold(_ id: String, pid: pid_t) -> Hold {
    Hold(id: id, kind: .timer, label: "build", source: .cli, caffeinatePID: pid, flags: ["-i", "-t", "60"],
         startedAt: Date(timeIntervalSince1970: 0), expiresAt: nil, watchedPID: nil,
         display: false, acOnly: false, lidClosed: true, batteryFloor: 15)
}

private struct Harness {
    let store: HoldStore
    let flag = FakeFlag()
    let spawner = RecordingSpawner()
    let logged = LogSink()
    final class LogSink: @unchecked Sendable { var lines: [String] = [] }

    init(table: [pid_t: ProcessSnapshot]) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("teainate-runner-\(UUID().uuidString)/holds.json")
        store = HoldStore(fileURL: url, snapshotter: FakeSnapshotter(table: table))
    }

    func runner(liveness: ScriptedLiveness, battery: BatteryState? = BatteryState(source: .ac, percent: 90),
                manageFlag: Bool = true) -> LidWatchRunner {
        let sink = logged
        return LidWatchRunner(dependencies: .init(
            store: store, spawner: spawner, battery: StubBattery(state: battery),
            flag: manageFlag ? flag : nil, liveness: liveness,
            log: { sink.lines.append($0) }, sleep: { _ in }, now: { Date(timeIntervalSince1970: 5_000) },
            checkInterval: 1
        ))
    }

    static func table(_ entries: (pid_t, String)...) -> [pid_t: ProcessSnapshot] {
        var t: [pid_t: ProcessSnapshot] = [:]
        for (pid, name) in entries { t[pid] = ProcessSnapshot(pid: pid, parentPID: 1, command: name) }
        return t
    }

    var config: LidWatchConfig {
        LidWatchConfig(holdID: "h_1", floor: 15, watchedPID: nil, acOnly: false,
                       caffeinateFlags: ["-i", "-t", "60"], label: "build")
    }
}

@Test func setsFlagAndSpawnsChildTiedToOwnPID() {
    let h = Harness(table: Harness.table((watcherPID, "teainate")))
    _ = h.runner(liveness: ScriptedLiveness([900: [false]])).run(h.config, ownPID: watcherPID, stop: StopFlag())
    #expect(h.flag.setCount == 1)
    #expect(h.spawner.spawned == [["-i", "-t", "60", "-w", "4242"]])
}

@Test func childExitEndsWithTimerExpiredAndClearsFlag() throws {
    let h = Harness(table: Harness.table((watcherPID, "teainate")))
    try h.store.mutateState { $0.holds.append(lidHold("h_1", pid: watcherPID)); $0.lidFlagOwned = true }

    let reason = h.runner(liveness: ScriptedLiveness([900: [true, false]])).run(h.config, ownPID: watcherPID, stop: StopFlag())

    #expect(reason == .timerExpired)
    #expect(h.spawner.terminated == [900])
    #expect(h.flag.clearCount == 1)
    let state = try h.store.readState()
    #expect(state.holds.isEmpty)
    #expect(state.lidFlagOwned == false)
    #expect(state.lastEnded == nil)          // not a reason worth explaining
    #expect(h.logged.lines.contains { $0.contains("h_1 ended: timer expired") })
}

@Test func floorEndsAndRecordsLastEnded() throws {
    let h = Harness(table: Harness.table((watcherPID, "teainate")))
    try h.store.mutateState { $0.holds.append(lidHold("h_1", pid: watcherPID)); $0.lidFlagOwned = true }

    let reason = h.runner(liveness: ScriptedLiveness([900: [true]]),
                          battery: BatteryState(source: .battery, percent: 14))
        .run(h.config, ownPID: watcherPID, stop: StopFlag())

    #expect(reason == .batteryAtFloor(percent: 14, floor: 15))
    let ended = try h.store.readState().lastEnded
    #expect(ended?.id == "h_1")
    #expect(ended?.label == "build")
    #expect(ended?.reason == "battery 14% at floor 15%")
    #expect(ended?.at == Date(timeIntervalSince1970: 5_000))
}

@Test func stopFlagEndsWithReleasedAndRecordsNothing() throws {
    let h = Harness(table: Harness.table((watcherPID, "teainate")))
    let stop = StopFlag()
    stop.set()
    let reason = h.runner(liveness: ScriptedLiveness([900: [true]])).run(h.config, ownPID: watcherPID, stop: stop)
    #expect(reason == .released)
    #expect(h.spawner.terminated == [900])
    #expect(try h.store.readState().lastEnded == nil)
}

@Test func lastWatcherOutClearsTheFlagButNotBefore() throws {
    let h = Harness(table: Harness.table((watcherPID, "teainate"), (4343, "teainate")))
    try h.store.mutateState {
        $0.holds.append(lidHold("h_1", pid: watcherPID))
        $0.holds.append(lidHold("h_2", pid: 4343))
        $0.lidFlagOwned = true
    }
    _ = h.runner(liveness: ScriptedLiveness([900: [false]])).run(h.config, ownPID: watcherPID, stop: StopFlag())
    #expect(h.flag.clearCount == 0)
    #expect(try h.store.readState().lidFlagOwned == true)
}

@Test func failedClearLeavesMarkerForOrphanCleanup() throws {
    let h = Harness(table: Harness.table((watcherPID, "teainate")))
    h.flag.failClear = true
    try h.store.mutateState { $0.holds.append(lidHold("h_1", pid: watcherPID)); $0.lidFlagOwned = true }
    _ = h.runner(liveness: ScriptedLiveness([900: [false]])).run(h.config, ownPID: watcherPID, stop: StopFlag())
    let state = try h.store.readState()
    #expect(state.holds.isEmpty)
    #expect(state.lidFlagOwned == true)
    #expect(h.logged.lines.contains { $0.contains("could not clear") })
}

@Test func noFlagModeNeverTouchesTheFlag() {
    let h = Harness(table: Harness.table((watcherPID, "teainate")))
    _ = h.runner(liveness: ScriptedLiveness([900: [false]]), manageFlag: false)
        .run(h.config, ownPID: watcherPID, stop: StopFlag())
    #expect(h.flag.setCount == 0)
    #expect(h.flag.clearCount == 0)
}

@Test func watchedProcessExitEnds() {
    let h = Harness(table: Harness.table((watcherPID, "teainate")))
    var config = h.config
    config.watchedPID = 777
    let reason = h.runner(liveness: ScriptedLiveness([900: [true], 777: [false]]))
        .run(config, ownPID: watcherPID, stop: StopFlag())
    #expect(reason == .watchedProcessExited)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter LidWatchRunnerTests`
Expected: compile error.

- [ ] **Step 3: Append the runner to `LidWatch.swift`**

```swift
public protocol ProcessLiveness: Sendable {
    func isAlive(_ pid: pid_t) -> Bool
}

/// `kill(pid, 0)` liveness. Reaps first so an exited child of ours is not mistaken
/// for a live zombie; after Foundation has already reaped it, waitpid fails and
/// kill reports ESRCH, both of which read as "gone".
public struct KillZeroLiveness: ProcessLiveness {
    public init() {}
    public func isAlive(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

/// Set from a signal handler's dispatch source; read by the loop.
public final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func set() { lock.lock(); flag = true; lock.unlock() }
    public var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Supervises one lid-closed hold. Runs inside `teainate lid-watch`.
public struct LidWatchRunner: Sendable {
    public struct Dependencies: Sendable {
        public var store: HoldStore
        public var spawner: any CaffeinateSpawning
        public var battery: any BatteryReading
        /// nil = never touch the kernel flag (the `--no-flag` test hook).
        public var flag: (any SleepFlagControlling)?
        public var liveness: any ProcessLiveness
        public var log: @Sendable (String) -> Void
        public var sleep: @Sendable (UInt32) -> Void
        public var now: @Sendable () -> Date
        /// Seconds between rail checks. Stop requests are noticed every second.
        public var checkInterval: UInt32

        public init(
            store: HoldStore, spawner: any CaffeinateSpawning, battery: any BatteryReading,
            flag: (any SleepFlagControlling)?, liveness: any ProcessLiveness,
            log: @escaping @Sendable (String) -> Void,
            sleep: @escaping @Sendable (UInt32) -> Void = { _ = Darwin.sleep($0) },
            now: @escaping @Sendable () -> Date = { Date() },
            checkInterval: UInt32 = 30
        ) {
            self.store = store; self.spawner = spawner; self.battery = battery
            self.flag = flag; self.liveness = liveness; self.log = log
            self.sleep = sleep; self.now = now; self.checkInterval = checkInterval
        }
    }

    private let deps: Dependencies

    public init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    public func run(_ config: LidWatchConfig, ownPID: pid_t, stop: StopFlag) -> WatcherEndReason {
        // The service already set the flag before spawning us. Setting it again is
        // idempotent and closes the window where a previous watcher's exit cleared it
        // between the service's set and its record.
        if let flag = deps.flag {
            do { try flag.set() } catch { deps.log("\(config.holdID) could not re-set sleep flag: \(error)") }
        }

        let child: pid_t
        do {
            child = try deps.spawner.spawn(flags: watcherChildFlags(
                caffeinateFlags: config.caffeinateFlags, watcherPID: ownPID))
        } catch {
            let reason = WatcherEndReason.caffeinateFailed("\(error)")
            finish(config, reason: reason)
            return reason
        }

        var reason: WatcherEndReason?
        while reason == nil {
            var waited: UInt32 = 0
            while waited < deps.checkInterval && !stop.isSet {
                deps.sleep(1)
                waited += 1
            }
            if stop.isSet { reason = .released; break }

            let battery = (try? deps.battery.read()) ?? nil
            reason = watcherDecision(
                childAlive: deps.liveness.isAlive(child),
                watchedAlive: config.watchedPID.map(deps.liveness.isAlive),
                battery: battery, floor: config.floor, acOnly: config.acOnly
            )
        }

        deps.spawner.terminate(pid: child)
        finish(config, reason: reason ?? .released)
        return reason ?? .released
    }

    /// Two separate mutations on purpose: removing the record and noting the reason
    /// must land even when clearing the flag fails.
    private func finish(_ config: LidWatchConfig, reason: WatcherEndReason) {
        do {
            try deps.store.mutateState { state in
                state.holds.removeAll { $0.id == config.holdID }
                if reason.cutsWorkShort {
                    state.lastEnded = EndedHold(
                        id: config.holdID, label: config.label,
                        reason: reason.description, at: deps.now())
                }
            }
        } catch {
            deps.log("\(config.holdID) could not update state: \(error)")
        }

        if let flag = deps.flag {
            do {
                try deps.store.mutateState { state in
                    guard !state.holds.contains(where: \.lidClosed) else { return }
                    try flag.clear()
                    state.lidFlagOwned = false
                }
            } catch {
                deps.log("\(config.holdID) could not clear sleep flag: \(error)")
            }
        }
        deps.log("\(config.holdID) ended: \(reason.description)")
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter LidWatchRunnerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateCore/LidWatch.swift Tests/TeainateCoreTests/LidWatchRunnerTests.swift
git commit -m "feat(core): lid-watch runner loop with last-watcher-out flag clearing"
```

---

### Task 9: `lid-watch` subcommand and real-process tests

**Files:**
- Modify: `Sources/teainate/Teainate.swift`
- Modify: `Sources/TeainateCore/TeainateService.swift` (add `WatcherSpawning` + `SystemWatcherSpawner` only)
- Test: `Tests/TeainateIntegrationTests/RealLidWatchTests.swift`

**Interfaces:**
- Produces: `protocol WatcherSpawning { func spawnWatcher(executable: URL, arguments: [String]) throws -> pid_t }`, `SystemWatcherSpawner`; hidden CLI subcommand `teainate lid-watch --id --floor --state-file --caffeinate [--watch-pid] [--ac-only] [--label] [--no-flag]`.

- [ ] **Step 1: Write the failing integration tests**

```swift
import Testing
import Foundation
@testable import TeainateCore

private final class BundleMarker {}

/// The CLI product built alongside the test bundle (`.build/<config>/teainate`).
private func cliBinary() throws -> URL {
    let url = Bundle(for: BundleMarker.self).bundleURL
        .deletingLastPathComponent().appendingPathComponent("teainate")
    try #require(FileManager.default.isExecutableFile(atPath: url.path),
                 "teainate CLI not built at \(url.path); run `swift build` first")
    return url
}

private func waitUntilGone(_ pid: pid_t) throws {
    var attempts = 0
    while attempts < 100, try PSProcessSnapshotter().snapshot()[pid] != nil {
        usleep(100_000); attempts += 1
    }
}

private func tempState() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("teainate-lidwatch-\(UUID().uuidString)/holds.json")
}

// Real watcher, real ps, faked flag (--no-flag). This is the one shape of test that
// catches a `ucomm` mismatch on the watcher's name — see CLAUDE.md.
@Test func realWatcherSurvivesReconciliationAndOwnsItsChild() throws {
    let state = tempState()
    let config = LidWatchConfig(holdID: "h_it", floor: 15, watchedPID: nil, acOnly: false,
                                caffeinateFlags: ["-i", "-t", "20"], label: nil)
    let args = lidWatchArguments(config, stateFile: state) + ["--no-flag"]
    let pid = try SystemWatcherSpawner().spawnWatcher(executable: try cliBinary(), arguments: args)
    defer { kill(pid, SIGTERM) }

    // Give it a moment to spawn its caffeinate child.
    var child: ProcessSnapshot?
    for _ in 0..<50 {
        let table = try PSProcessSnapshotter().snapshot()
        child = table.values.first { $0.parentPID == pid && $0.command == "caffeinate" }
        if child != nil { break }
        usleep(100_000)
    }
    let table = try PSProcessSnapshotter().snapshot()
    #expect(table[pid]?.command == watcherProcessName)
    #expect(child?.arguments.hasSuffix("-w \(pid)") == true)

    let record = Hold(id: "h_it", kind: .timer, label: nil, source: .cli, caffeinatePID: pid,
                      flags: ["-i", "-t", "20"], startedAt: Date(), expiresAt: nil, watchedPID: nil,
                      display: false, acOnly: false, lidClosed: true, batteryFloor: 15)
    #expect(reconcile([record], against: table).map(\.id) == ["h_it"])
    #expect(ownedPIDs(of: [record], in: table).contains(child!.pid))

    kill(pid, SIGTERM)
    try waitUntilGone(pid)
    try waitUntilGone(child!.pid)
    #expect(try PSProcessSnapshotter().snapshot()[child!.pid] == nil)

    let log = try String(contentsOf: lidWatchLogURL(besideStateFile: state), encoding: .utf8)
    #expect(log.contains("h_it ended: released"))
}

// The no-orphan design rests on `-t` and `-w` combining. Verify both directions.
@Test func caffeinateTimerFiresWhileWatchedProcessLives() throws {
    let pid = try SystemCaffeinateSpawner().spawn(flags: ["-i", "-t", "2", "-w", String(getpid())])
    defer { kill(pid, SIGTERM) }
    sleep(3)
    try waitUntilGone(pid)
    #expect(try PSProcessSnapshotter().snapshot()[pid] == nil)
}

@Test func caffeinateReleasesWhenWatchedProcessExitsBeforeTimer() throws {
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    try sleeper.run()
    defer { sleeper.terminate() }

    let pid = try SystemCaffeinateSpawner().spawn(
        flags: ["-i", "-t", "20", "-w", String(sleeper.processIdentifier)])
    defer { kill(pid, SIGTERM) }

    sleeper.terminate()
    try waitUntilGone(pid)
    #expect(try PSProcessSnapshotter().snapshot()[pid] == nil)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift build && swift test --filter RealLidWatchTests`
Expected: compile error (`SystemWatcherSpawner` undefined).

- [ ] **Step 3: Add the watcher spawner to `TeainateService.swift`**

Below `ServiceError`:

```swift
public protocol WatcherSpawning: Sendable {
    func spawnWatcher(executable: URL, arguments: [String]) throws -> pid_t
}

/// Runs the CLI binary as `lid-watch`. Like caffeinate, the child is left to outlive
/// us; it reparents to launchd and keeps supervising after the CLI exits.
public struct SystemWatcherSpawner: WatcherSpawning {
    public init() {}

    public func spawnWatcher(executable: URL, arguments: [String]) throws -> pid_t {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ServiceError.spawnFailed(error.localizedDescription)
        }
        return process.processIdentifier
    }
}
```

- [ ] **Step 4: Add the hidden subcommand to `Teainate.swift`**

Register it: `subcommands: [StatusCommand.self, On.self, Off.self, LidWatch.self]`. Then:

```swift
/// Internal. Supervises one lid-closed hold; spawned by TeainateService, never by hand.
struct LidWatch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: lidWatchCommandName,
        abstract: "Internal: supervises one lid-closed hold.",
        shouldDisplay: false
    )

    @Option(name: .long) var id: String
    @Option(name: .long) var floor: Int
    @Option(name: .long) var stateFile: String
    @Option(name: .long, help: "Space-separated caffeinate flags for the child.") var caffeinate: String
    @Option(name: .long) var watchPid: Int32?
    @Flag(name: .long) var acOnly = false
    @Option(name: .long) var label: String?
    @Flag(name: .long, help: "Test hook: never touch the kernel sleep flag. The service never passes this.")
    var noFlag = false

    func run() throws {
        let stateURL = URL(fileURLWithPath: stateFile)
        let logURL = lidWatchLogURL(besideStateFile: stateURL)
        let stop = StopFlag()

        // Ignore at the libc level so the dispatch sources receive the signals.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let sources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { stop.set() }
            source.resume()
            return source
        }

        let snapshotter = PSProcessSnapshotter()
        let runner = LidWatchRunner(dependencies: .init(
            store: HoldStore(fileURL: stateURL, snapshotter: snapshotter),
            spawner: SystemCaffeinateSpawner(),
            battery: PMSetBatteryReader(),
            flag: noFlag ? nil : SudoSleepFlagController(),
            liveness: KillZeroLiveness(),
            log: { line in appendLogLine(line, to: logURL) }
        ))
        let config = LidWatchConfig(
            holdID: id, floor: floor, watchedPID: watchPid, acOnly: acOnly,
            caffeinateFlags: caffeinate.split(separator: " ").map(String.init), label: label
        )
        _ = runner.run(config, ownPID: getpid(), stop: stop)
        withExtendedLifetime(sources) {}
    }
}

private func appendLogLine(_ line: String, to url: URL) {
    let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
    guard let data = stamped.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}
```

- [ ] **Step 5: Run the integration tests**

Run: `swift build && swift test --filter RealLidWatchTests`
Expected: PASS. If `table[pid]?.command` is not `teainate`, the watcher's `ucomm` differs from the constant; fix `watcherProcessName`, never the test.

- [ ] **Step 6: Run everything**

Run: `swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/teainate/Teainate.swift Sources/TeainateCore/TeainateService.swift Tests/TeainateIntegrationTests/RealLidWatchTests.swift
git commit -m "feat(cli): hidden lid-watch subcommand with real-process tests"
```

---

### Task 10: Service — lid-closed `on`, pre-flight, orphan cleanup, status block

**Files:**
- Modify: `Sources/TeainateCore/TeainateService.swift`
- Test: `Tests/TeainateCoreTests/LidClosedServiceTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–8, `WatcherSpawning`.
- Produces: `LidClosedDependencies`; `ServiceError` cases `lidClosedUnavailable`, `lidClosedNotEnabled`, `lidClosedGrantBroken(String)`, `batteryBelowFloor(percent:floor:)`, `notOnACPower`, `sleepDisabledElsewhere`, `sleepFlagStuck(String)`; `LidClosedStatus` (`enabled`, `flagSet`, `flagSetBy: String?`, `batteryFloor`, `lastEnded`, `warning`, `static let unavailable`); `Status.lidClosed` (init param defaulted to `.unavailable`, key `lid_closed`); `HoldStatus.lidClosed`, `HoldStatus.batteryFloor` (defaulted); `TeainateService.init(..., lidClosed: LidClosedDependencies? = nil)`; `TeainateService.standard(paths:watcherExecutable:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import TeainateCore

private final class FakeFlag: SleepFlagControlling, @unchecked Sendable {
    var value = false
    var setCount = 0
    var clearCount = 0
    var failSet = false
    var failClear = false
    func set() throws {
        if failSet { throw SleepFlagError.commandFailed(status: 1, message: "sudo: a password is required") }
        setCount += 1; value = true
    }
    func clear() throws {
        if failClear { throw SleepFlagError.commandFailed(status: 1, message: "sudo: a password is required") }
        clearCount += 1; value = false
    }
    func isSet() throws -> Bool { value }
}

private struct FakeGrant: PrivilegeGranting {
    var granted = true
    func isGranted() -> Bool { granted }
}

private struct StubBattery: BatteryReading {
    var state: BatteryState? = BatteryState(source: .ac, percent: 90)
    func read() throws -> BatteryState? { state }
}

private final class RecordingWatcherSpawner: WatcherSpawning, @unchecked Sendable {
    var launches: [(URL, [String])] = []
    var nextPID: pid_t = 100
    var shouldFail = false
    func spawnWatcher(executable: URL, arguments: [String]) throws -> pid_t {
        if shouldFail { throw ServiceError.spawnFailed("boom") }
        launches.append((executable, arguments))
        defer { nextPID += 1 }
        return nextPID
    }
}

private final class RecordingSpawner: CaffeinateSpawning, @unchecked Sendable {
    var terminated: [pid_t] = []
    func spawn(flags: [String]) throws -> pid_t { 500 }
    func terminate(pid: pid_t) { terminated.append(pid) }
}

private struct StubSnapshotter: ProcessSnapshotting {
    var table: [pid_t: ProcessSnapshot]
    func snapshot() throws -> [pid_t: ProcessSnapshot] { table }
}

private struct StubAssertions: AssertionReading {
    var value: [ForeignAssertion] = []
    func assertions() throws -> [ForeignAssertion] { value }
}

private struct Rig {
    let flag = FakeFlag()
    let watcher = RecordingWatcherSpawner()
    let spawner = RecordingSpawner()
    let stateFile: URL
    let settings: SettingsStore
    let service: TeainateService

    init(grant: Bool = true, battery: BatteryState? = BatteryState(source: .ac, percent: 90),
         table: [pid_t: ProcessSnapshot] = Rig.table((100, "teainate")),
         storeSnapshotter: (any ProcessSnapshotting)? = nil,
         foreign: [ForeignAssertion] = []) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("teainate-lid-\(UUID().uuidString)")
        stateFile = dir.appendingPathComponent("holds.json")
        settings = SettingsStore(fileURL: dir.appendingPathComponent("settings.json"))
        let snap = StubSnapshotter(table: table)
        service = TeainateService(
            store: HoldStore(fileURL: stateFile, snapshotter: storeSnapshotter ?? snap),
            spawner: spawner, assertionReader: StubAssertions(value: foreign), snapshotter: snap,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            lidClosed: LidClosedDependencies(
                flag: flag, grant: FakeGrant(granted: grant), battery: StubBattery(state: battery),
                settings: settings, watcherSpawner: watcher,
                watcherExecutable: URL(fileURLWithPath: "/usr/local/bin/teainate"), stateFile: stateFile)
        )
    }

    static func table(_ entries: (pid_t, String)...) -> [pid_t: ProcessSnapshot] {
        var t: [pid_t: ProcessSnapshot] = [:]
        for (pid, name) in entries { t[pid] = ProcessSnapshot(pid: pid, parentPID: 1, command: name) }
        return t
    }

    func lid(duration: TimeInterval? = 7200, watched: pid_t? = nil, acOnly: Bool = false) -> HoldOptions {
        HoldOptions(duration: duration, watchedPID: watched, acOnly: acOnly, lidClosed: true, source: .cli)
    }
}

@Test func refusedWithoutGrantAndTouchesNothing() {
    let rig = Rig(grant: false)
    #expect(throws: ServiceError.lidClosedNotEnabled) { try rig.service.on(rig.lid()) }
    #expect(rig.flag.setCount == 0)
    #expect(rig.watcher.launches.isEmpty)
}

@Test func refusedAtOrBelowFloorOnBattery() {
    let rig = Rig(battery: BatteryState(source: .battery, percent: 14))
    #expect(throws: ServiceError.batteryBelowFloor(percent: 14, floor: 15)) { try rig.service.on(rig.lid()) }
    #expect(rig.flag.setCount == 0)
}

@Test func allowedAboveFloorOnBatteryAndAtAnyLevelOnAC() throws {
    let above = Rig(battery: BatteryState(source: .battery, percent: 16))
    _ = try above.service.on(above.lid())
    let ac = Rig(battery: BatteryState(source: .ac, percent: 3))
    _ = try ac.service.on(ac.lid())
}

@Test func acOnlyRefusedWhileOnBattery() {
    let rig = Rig(battery: BatteryState(source: .battery, percent: 90))
    #expect(throws: ServiceError.notOnACPower) { try rig.service.on(rig.lid(acOnly: true)) }
}

@Test func refusedWhenFlagIsSetBySomethingElse() {
    let rig = Rig()
    rig.flag.value = true
    #expect(throws: ServiceError.sleepDisabledElsewhere) { try rig.service.on(rig.lid()) }
    #expect(rig.flag.setCount == 0)
}

@Test func brokenGrantIsReportedAsSuch() {
    let rig = Rig()
    rig.flag.failSet = true
    #expect(throws: ServiceError.self) { try rig.service.on(rig.lid()) }
    do { _ = try rig.service.on(rig.lid()) } catch let ServiceError.lidClosedGrantBroken(message) {
        #expect(message.contains("password"))
    } catch { Issue.record("wrong error \(error)") }
    #expect(rig.watcher.launches.isEmpty)
}

@Test func successSetsFlagSpawnsWatcherRecordsHoldAndMarker() throws {
    let rig = Rig()
    try rig.settings.write(Settings(batteryFloor: 20))

    let hold = try rig.service.on(rig.lid(duration: nil, watched: 6707))

    #expect(rig.flag.setCount == 1)
    #expect(rig.watcher.launches.count == 1)
    #expect(rig.watcher.launches[0].0.path == "/usr/local/bin/teainate")
    #expect(rig.watcher.launches[0].1 == [
        "lid-watch", "--id", hold.id, "--floor", "20", "--state-file", rig.stateFile.path,
        "--caffeinate", "-i", "--watch-pid", "6707"])
    #expect(hold.lidClosed == true)
    #expect(hold.batteryFloor == 20)
    #expect(hold.caffeinatePID == 100)
    #expect(hold.flags == ["-i"])            // no -w: the watcher owns that slot

    let state = try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: Rig.table((100, "teainate")))).readState()
    #expect(state.lidFlagOwned == true)
    #expect(state.holds.map(\.id) == [hold.id])
}

@Test func failedWatcherSpawnClearsFlagAndRecordsNothing() throws {
    let rig = Rig()
    rig.watcher.shouldFail = true
    #expect(throws: ServiceError.self) { try rig.service.on(rig.lid()) }
    #expect(rig.flag.setCount == 1)
    #expect(rig.flag.clearCount == 1)
    #expect(try rig.service.status().holds.isEmpty)
}

@Test func failedRecordTerminatesWatcherAndClearsFlag() throws {
    final class Flaky: ProcessSnapshotting, @unchecked Sendable {
        var calls = 0
        func snapshot() throws -> [pid_t: ProcessSnapshot] {
            calls += 1
            // First two calls: orphan check + ownership read in on(); third is the record.
            if calls == 3 { throw ServiceError.spawnFailed("store boom") }
            return Rig.table((100, "teainate"))
        }
    }
    let rig = Rig(storeSnapshotter: Flaky())
    #expect(throws: (any Error).self) { try rig.service.on(rig.lid()) }
    #expect(rig.spawner.terminated == [100])
    #expect(rig.flag.clearCount == 1)
}

@Test func clearFailureAfterSpawnFailureIsReportedAsStuck() {
    let rig = Rig()
    rig.watcher.shouldFail = true
    rig.flag.failClear = true
    #expect(throws: ServiceError.self) { try rig.service.on(rig.lid()) }
    do { _ = try rig.service.on(rig.lid()) } catch ServiceError.sleepFlagStuck { } catch {
        Issue.record("expected sleepFlagStuck, got \(error)")
    }
}

@Test func secondLidHoldJoinsAndFlagClearsOnlyAfterTheLast() throws {
    let rig = Rig(table: Rig.table((100, "teainate"), (101, "teainate")))
    let first = try rig.service.on(rig.lid())
    let second = try rig.service.on(rig.lid())

    _ = try rig.service.off(id: first.id)
    #expect(rig.flag.clearCount == 0)
    #expect(try rig.service.status().lidClosed.flagSetBy == "teainate")

    _ = try rig.service.off(id: second.id)
    #expect(rig.flag.clearCount == 1)
    #expect(try rig.service.status().lidClosed.flagSet == false)
}

@Test func orphanedFlagIsClearedOnRead() throws {
    let rig = Rig(table: [:])            // no live processes at all
    rig.flag.value = true
    try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: [:]))
        .mutateState { $0.lidFlagOwned = true }

    let status = try rig.service.status()

    #expect(rig.flag.clearCount == 1)
    #expect(status.lidClosed.flagSet == false)
    #expect(status.lidClosed.warning == nil)
}

@Test func orphanedFlagThatCannotBeClearedWarns() throws {
    let rig = Rig(table: [:])
    rig.flag.value = true
    rig.flag.failClear = true
    try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: [:]))
        .mutateState { $0.lidFlagOwned = true }

    let status = try rig.service.status()
    #expect(status.lidClosed.warning?.contains("sudo pmset -a disablesleep 0") == true)
    #expect(status.lidClosed.flagSetBy == "teainate")
}

@Test func staleMarkerWithFlagAlreadyClearIsDroppedWithoutSudo() throws {
    // After a reboot the flag is gone but the marker survived; no clear call is needed.
    let rig = Rig(table: [:])
    rig.flag.failClear = true
    try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: [:]))
        .mutateState { $0.lidFlagOwned = true }
    let status = try rig.service.status()
    #expect(status.lidClosed.flagSetBy == nil)
    #expect(status.lidClosed.warning == nil)
}

@Test func flagSetElsewhereIsReportedNotTouched() throws {
    let rig = Rig(table: [:])
    rig.flag.value = true
    let status = try rig.service.status()
    #expect(rig.flag.clearCount == 0)
    #expect(status.lidClosed.flagSetBy == "other")
    #expect(status.lidClosed.warning?.contains("outside teainate") == true)
}

@Test func watcherChildIsNeitherUntrackedNorForeign() throws {
    var table = Rig.table((100, "teainate"))
    table[200] = ProcessSnapshot(pid: 200, parentPID: 100, command: "caffeinate", arguments: "caffeinate -i -w 100")
    table[300] = ProcessSnapshot(pid: 300, parentPID: 1, command: "caffeinate", arguments: "caffeinate -i")
    let rig = Rig(table: table, foreign: [
        ForeignAssertion(pid: 200, process: "caffeinate", type: "PreventUserIdleSystemSleep"),
        ForeignAssertion(pid: 300, process: "caffeinate", type: "PreventUserIdleSystemSleep"),
    ])
    _ = try rig.service.on(rig.lid())

    let status = try rig.service.status()
    #expect(status.untrackedCaffeinate.map(\.pid) == [300])
    #expect(status.foreignAssertions.map(\.pid) == [300])
    #expect(status.holds.first?.lidClosed == true)
    #expect(status.holds.first?.batteryFloor == 15)
}

@Test func statusReportsGrantAndFloor() throws {
    let rig = Rig()
    try rig.settings.write(Settings(batteryFloor: 30))
    let status = try rig.service.status()
    #expect(status.lidClosed.enabled == true)
    #expect(status.lidClosed.batteryFloor == 30)
}

@Test func lidClosedUnavailableWithoutDependencies() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("teainate-\(UUID().uuidString)/holds.json")
    let service = TeainateService(
        store: HoldStore(fileURL: url, snapshotter: StubSnapshotter(table: [:])),
        spawner: RecordingSpawner(), assertionReader: StubAssertions(), snapshotter: StubSnapshotter(table: [:]))
    #expect(throws: ServiceError.lidClosedUnavailable) {
        try service.on(HoldOptions(duration: 60, lidClosed: true, source: .cli))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter LidClosedServiceTests`
Expected: compile error.

- [ ] **Step 3: Extend `ServiceError`, `HoldStatus`, `Status`**

```swift
public enum ServiceError: Error, Equatable {
    case noClaudeAncestor
    case spawnFailed(String)
    case lidClosedUnavailable
    case lidClosedNotEnabled
    case lidClosedGrantBroken(String)
    case batteryBelowFloor(percent: Int, floor: Int)
    case notOnACPower
    case sleepDisabledElsewhere
    /// The one outcome that leaves the Mac unable to sleep: we set the flag, something
    /// failed, and clearing it failed too. The message carries both errors.
    case sleepFlagStuck(String)
}
```

`HoldStatus`: add `public let lidClosed: Bool` and `public let batteryFloor: Int?`, init params `lidClosed: Bool = false, batteryFloor: Int? = nil` appended, coding keys `lidClosed = "lid_closed"`, `batteryFloor = "battery_floor"`.

Add:

```swift
public struct LidClosedStatus: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let flagSet: Bool
    /// "teainate", "other", or nil when the flag is not set.
    public let flagSetBy: String?
    public let batteryFloor: Int
    public let lastEnded: EndedHold?
    public let warning: String?

    public init(enabled: Bool, flagSet: Bool, flagSetBy: String?, batteryFloor: Int,
                lastEnded: EndedHold?, warning: String?) {
        self.enabled = enabled; self.flagSet = flagSet; self.flagSetBy = flagSetBy
        self.batteryFloor = batteryFloor; self.lastEnded = lastEnded; self.warning = warning
    }

    enum CodingKeys: String, CodingKey {
        case enabled, warning
        case flagSet = "flag_set"
        case flagSetBy = "flag_set_by"
        case batteryFloor = "battery_floor"
        case lastEnded = "last_ended"
    }

    public static let unavailable = LidClosedStatus(
        enabled: false, flagSet: false, flagSetBy: nil,
        batteryFloor: defaultBatteryFloor, lastEnded: nil, warning: nil)
}
```

`Status`: add `public let lidClosed: LidClosedStatus`, init param `lidClosed: LidClosedStatus = .unavailable` appended, coding key `lidClosed = "lid_closed"`.

- [ ] **Step 4: Add dependencies and the lid-closed paths to `TeainateService`**

```swift
public struct LidClosedDependencies: Sendable {
    public let flag: any SleepFlagControlling
    public let grant: any PrivilegeGranting
    public let battery: any BatteryReading
    public let settings: SettingsStore
    public let watcherSpawner: any WatcherSpawning
    public let watcherExecutable: URL
    public let stateFile: URL

    public init(flag: any SleepFlagControlling, grant: any PrivilegeGranting, battery: any BatteryReading,
                settings: SettingsStore, watcherSpawner: any WatcherSpawning,
                watcherExecutable: URL, stateFile: URL) {
        self.flag = flag; self.grant = grant; self.battery = battery; self.settings = settings
        self.watcherSpawner = watcherSpawner; self.watcherExecutable = watcherExecutable
        self.stateFile = stateFile
    }
}
```

Service stored property `private let lidClosed: LidClosedDependencies?`, init param `lidClosed: LidClosedDependencies? = nil` appended. Replace `standard`:

```swift
    /// `watcherExecutable` is the CLI binary: the app passes its bundled copy, the CLI
    /// passes itself. nil leaves lid-closed holds unavailable.
    public static func standard(
        paths: TeainatePaths = .standard(),
        watcherExecutable: URL? = nil
    ) -> TeainateService {
        let snapshotter = PSProcessSnapshotter()
        return TeainateService(
            store: HoldStore(fileURL: paths.stateFile, snapshotter: snapshotter),
            spawner: SystemCaffeinateSpawner(),
            assertionReader: PMSetAssertionReader(),
            snapshotter: snapshotter,
            lidClosed: watcherExecutable.map { executable in
                LidClosedDependencies(
                    flag: SudoSleepFlagController(), grant: SudoersGrant(),
                    battery: PMSetBatteryReader(),
                    settings: SettingsStore(fileURL: paths.settingsFile),
                    watcherSpawner: SystemWatcherSpawner(),
                    watcherExecutable: executable, stateFile: paths.stateFile)
            }
        )
    }
```

At the top of `on(_:)`: `if options.lidClosed { return try onLidClosed(options) }`. Then:

```swift
    private func onLidClosed(_ options: HoldOptions) throws -> Hold {
        guard let lid = lidClosed else { throw ServiceError.lidClosedUnavailable }

        // Pre-flight: nothing is touched until every check passes.
        guard lid.grant.isGranted() else { throw ServiceError.lidClosedNotEnabled }
        let floor = lid.settings.read().settings.batteryFloor
        let battery = (try? lid.battery.read()) ?? nil
        if let battery, battery.source == .battery {
            if options.acOnly { throw ServiceError.notOnACPower }
            if let percent = battery.percent, percent <= floor {
                throw ServiceError.batteryBelowFloor(percent: percent, floor: floor)
            }
        }
        try clearOrphanedFlag()
        let alreadyOwned = try store.readState().lidFlagOwned
        if !alreadyOwned, (try? lid.flag.isSet()) == true {
            throw ServiceError.sleepDisabledElsewhere
        }

        do { try lid.flag.set() } catch {
            throw ServiceError.lidClosedGrantBroken("\(error)")
        }

        // From here every failure must put the flag back — unless another live
        // lid-closed hold owned it before we started.
        func undo(_ failure: any Error) -> any Error {
            guard !alreadyOwned else { return failure }
            do { try lid.flag.clear() } catch {
                return ServiceError.sleepFlagStuck("\(failure); and clearing the sleep flag failed: \(error)")
            }
            return failure
        }

        let flags = caffeinateFlags(for: options)
        let id = makeHoldID()
        let config = LidWatchConfig(
            holdID: id, floor: floor, watchedPID: options.watchedPID, acOnly: options.acOnly,
            caffeinateFlags: flags, label: options.label)
        let pid: pid_t
        do {
            pid = try lid.watcherSpawner.spawnWatcher(
                executable: lid.watcherExecutable,
                arguments: lidWatchArguments(config, stateFile: lid.stateFile))
        } catch {
            throw undo(error)
        }

        let started = now()
        let hold = Hold(
            id: id, kind: options.kind, label: options.label, source: options.source,
            caffeinatePID: pid, flags: flags, startedAt: started,
            expiresAt: options.duration.map { started.addingTimeInterval($0) },
            watchedPID: options.watchedPID, display: options.display, acOnly: options.acOnly,
            lidClosed: true, batteryFloor: floor)
        do {
            try store.mutateState { state in
                state.holds.append(hold)
                state.lidFlagOwned = true
            }
        } catch {
            spawner.terminate(pid: pid)
            throw undo(error)
        }
        return hold
    }

    /// Marker true with no live lid-closed hold means a watcher died without cleaning
    /// up. If the flag is still set, clear it; if clearing fails the marker stays so
    /// `status` keeps warning. If the flag is already clear (a reboot), just drop the marker.
    private func clearOrphanedFlag() throws {
        guard let lid = lidClosed else { return }
        try store.mutateState { state in
            guard state.lidFlagOwned, !state.holds.contains(where: \.lidClosed) else { return }
            let flagSet = (try? lid.flag.isSet()) ?? true
            if !flagSet || (try? lid.flag.clear()) != nil {
                state.lidFlagOwned = false
            }
        }
    }
```

In `off(id:)`, after the terminate loop, add `try clearOrphanedFlag()`.

Rewrite `status()`:

```swift
    public func status() throws -> Status {
        try clearOrphanedFlag()
        let state = try store.readState()
        let holds = state.holds
        let current = now()
        let foreign = (try? assertionReader.assertions()) ?? []
        let table = (try? snapshotter.snapshot()) ?? [:]
        let ours = ownedPIDs(of: holds, in: table)
        let untracked = table.values
            .filter { $0.command == caffeinateProcessName && !ours.contains($0.pid) }
            .map { UntrackedCaffeinate(pid: $0.pid, arguments: $0.arguments) }
            .sorted { $0.pid < $1.pid }
        return Status(
            awake: !holds.isEmpty,
            holds: holds.map { hold in
                HoldStatus(
                    id: hold.id, kind: hold.kind, label: hold.label, source: hold.source,
                    expiresAt: hold.expiresAt,
                    remainingSeconds: hold.remainingSeconds(now: current),
                    display: hold.display, acOnly: hold.acOnly,
                    lidClosed: hold.lidClosed, batteryFloor: hold.batteryFloor)
            },
            foreignAssertions: foreign.filter { !ours.contains($0.pid) },
            untrackedCaffeinate: untracked,
            lidClosed: lidClosedStatus(state)
        )
    }

    private func lidClosedStatus(_ state: StoreState) -> LidClosedStatus {
        guard let lid = lidClosed else { return .unavailable }
        let flagSet = (try? lid.flag.isSet()) ?? false
        let (settings, settingsWarning) = lid.settings.read()
        let liveLid = state.holds.contains(where: \.lidClosed)
        let flagSetBy: String? = flagSet ? (state.lidFlagOwned ? "teainate" : "other") : nil

        var warning = settingsWarning
        if state.lidFlagOwned && !liveLid && flagSet {
            warning = "The sleep-disabled flag is set and teainate cannot clear it. Run: sudo pmset -a disablesleep 0"
        } else if flagSet && !state.lidFlagOwned {
            warning = "Sleep is disabled outside teainate (pmset disablesleep); this Mac will not sleep with the lid closed until that is cleared."
        }
        return LidClosedStatus(
            enabled: lid.grant.isGranted(), flagSet: flagSet, flagSetBy: flagSetBy,
            batteryFloor: settings.batteryFloor, lastEnded: state.lastEnded, warning: warning)
    }
```

Also replace the two remaining `"caffeinate"` literals in `reclaimUntracked` with `caffeinateProcessName`.

- [ ] **Step 5: Run all Core tests**

Run: `swift test --filter TeainateCoreTests`
Expected: PASS. Existing `ServiceTests` compile unchanged because every new init parameter has a default.

- [ ] **Step 6: Run everything**

Run: `swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/TeainateCore/TeainateService.swift Tests/TeainateCoreTests/LidClosedServiceTests.swift
git commit -m "feat(core): lid-closed holds in the service with pre-flight and orphan cleanup"
```

---

### Task 11: Status rendering

**Files:**
- Modify: `Sources/TeainateCore/StatusRendering.swift`
- Test: `Tests/TeainateCoreTests/OutputTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `OutputTests.swift` (extend the private `holdStatus` helper with `lidClosed: Bool = false, floor: Int? = nil` passed through to `HoldStatus`, and give `status(...)` a `lid: LidClosedStatus = .unavailable` parameter passed as `lidClosed:`):

```swift
@Test func describesLidClosedModifiers() {
    let text = describe(holdStatus(kind: .timer, label: "build", remaining: 2520, lidClosed: true, floor: 15))
    #expect(text.contains("build — 42 min left"))
    #expect(text.contains("lid ok"))
    #expect(text.contains("off at 15%"))
}

@Test func rendersLidClosedWarning() {
    let lid = LidClosedStatus(enabled: true, flagSet: true, flagSetBy: "teainate", batteryFloor: 15,
                              lastEnded: nil, warning: "The sleep-disabled flag is set and teainate cannot clear it. Run: sudo pmset -a disablesleep 0")
    let text = renderStatus(status(awake: false, lid: lid))
    #expect(text.contains("⚠ The sleep-disabled flag is set"))
}

@Test func rendersLastEndedReason() {
    let ended = EndedHold(id: "h_x", label: "build", reason: "battery 14% at floor 15%", at: Date())
    let lid = LidClosedStatus(enabled: true, flagSet: false, flagSetBy: nil, batteryFloor: 15, lastEnded: ended, warning: nil)
    let text = renderStatus(status(awake: false, lid: lid))
    #expect(text.contains("Last lid-closed hold (build) ended: battery 14% at floor 15%"))
}

@Test func rendersEnablementLine() {
    let off = LidClosedStatus(enabled: false, flagSet: false, flagSetBy: nil, batteryFloor: 15, lastEnded: nil, warning: nil)
    #expect(renderStatus(status(awake: false, lid: off)).contains("Lid-closed holds: not enabled"))
    let on = LidClosedStatus(enabled: true, flagSet: false, flagSetBy: nil, batteryFloor: 30, lastEnded: nil, warning: nil)
    #expect(renderStatus(status(awake: false, lid: on)).contains("Lid-closed holds: enabled (battery floor 30%)"))
}

@Test func statusJSONCarriesLidClosedKeys() throws {
    let lid = LidClosedStatus(enabled: true, flagSet: true, flagSetBy: "other", batteryFloor: 15, lastEnded: nil, warning: nil)
    let data = try Status.encoder.encode(status(holds: [holdStatus(lidClosed: true, floor: 15)], lid: lid))
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"lid_closed\""))
    #expect(json.contains("\"battery_floor\""))
    #expect(json.contains("\"flag_set_by\" : \"other\""))
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter OutputTests`
Expected: the new tests fail (helpers compile once extended).

- [ ] **Step 3: Implement**

In `describe`, after the `acOnly` modifier:

```swift
    if hold.lidClosed {
        modifiers.append("lid ok")
        if let floor = hold.batteryFloor { modifiers.append("off at \(floor)%") }
    }
```

In `renderStatus`, before `return`:

```swift
    let lid = status.lidClosed
    lines.append("")
    if let warning = lid.warning {
        lines.append("⚠ \(warning)")
    }
    if let ended = lid.lastEnded {
        let name = ended.label.map { " (\($0))" } ?? ""
        lines.append("Last lid-closed hold\(name) ended: \(ended.reason)")
    }
    lines.append(lid.enabled
        ? "Lid-closed holds: enabled (battery floor \(lid.batteryFloor)%)"
        : "Lid-closed holds: not enabled — enable from the Teainate menu")
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter TeainateCoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateCore/StatusRendering.swift Tests/TeainateCoreTests/OutputTests.swift
git commit -m "feat(core): render lid-closed state in status"
```

---

### Task 12: CLI `on --lid-closed`

**Files:**
- Modify: `Sources/teainate/Teainate.swift`

**Interfaces:**
- Consumes: `lidClosedCommandLineProblem`, `ServiceError` cases, `HoldOptions.lidClosed`, `Bundle.main.executableURL`.

- [ ] **Step 1: Add the flag and validation to `On`**

```swift
    @Flag(name: .long, help: "Keep the Mac awake even with the lid closed. Needs --for, --session, or --until-pid, and lid-closed holds enabled from the Teainate menu.")
    var lidClosed = false
```

At the end of `validate()`:

```swift
        if lidClosed {
            let duration = try? `for`.map(parseDuration)
            let hasLifetime = `for` != nil || session || untilPid != nil
            if let problem = lidClosedCommandLineProblem(duration: duration ?? nil, hasLifetime: hasLifetime) {
                throw ValidationError(problem)
            }
        }
```

- [ ] **Step 2: Wire the service and error mapping**

Replace `TeainateService.standard()` in `On.run`, `Off.run` and `StatusCommand.run` with `standardService()`, and add at file scope:

```swift
/// The CLI is its own watcher binary.
func standardService() -> TeainateService {
    TeainateService.standard(
        watcherExecutable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
}

/// Every lid-closed refusal is a user-facing sentence, non-zero exit, stderr.
func friendlyDescription(_ error: ServiceError) -> String? {
    switch error {
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
    case .lidClosedUnavailable:
        return "Lid-closed holds are not available in this build."
    case .noClaudeAncestor, .spawnFailed:
        return nil
    }
}
```

In `On.run`, pass `lidClosed: lidClosed` into `HoldOptions`, and wrap the call:

```swift
        let hold: Hold
        do {
            hold = try service.on(options)
        } catch let error as ServiceError {
            if let message = friendlyDescription(error) { throw FriendlyError(description: message) }
            throw error
        }
```

and pass `lidClosed: hold.lidClosed, batteryFloor: hold.batteryFloor` into the `HoldStatus` it prints.

- [ ] **Step 3: Verify by hand**

```bash
swift build
.build/debug/teainate on --lid-closed            # → "--lid-closed needs --for, ..." exit 64
.build/debug/teainate on --lid-closed --for 9h    # → "limited to 8 hours" exit 64
.build/debug/teainate on --lid-closed --for 1h    # → "not enabled" (no grant on this machine), exit 1
.build/debug/teainate status                      # → last line "Lid-closed holds: not enabled — ..."
.build/debug/teainate --help                      # lid-watch must not appear
echo $?
```

- [ ] **Step 4: Commit**

```bash
git add Sources/teainate/Teainate.swift
git commit -m "feat(cli): on --lid-closed with loud refusals"
```

---

### Task 13: Menu model

**Files:**
- Modify: `Sources/TeainateCore/MenuModel.swift`
- Test: `Tests/TeainateCoreTests/MenuModelTests.swift`

**Interfaces:**
- Produces: `MenuAction.toggleLidClosed`, `.enableLidClosed`, `.disableLidClosed`, `.setBatteryFloor(Int)`; `MenuItem.submenu: [MenuItem]` (init param, default `[]`); `MenuPreferences.lidClosed: Bool`.

- [ ] **Step 1: Write the failing tests**

Extend the private `status(...)` helper with `lid: LidClosedStatus = .unavailable` passed as `lidClosed:`, and `holdStatus` with `lidClosed: Bool = false`. Add:

```swift
private let granted = LidClosedStatus(enabled: true, flagSet: false, flagSetBy: nil, batteryFloor: 15, lastEnded: nil, warning: nil)
private let notGranted = LidClosedStatus(enabled: false, flagSet: false, flagSetBy: nil, batteryFloor: 15, lastEnded: nil, warning: nil)

@Test func lidModifierIsGreyedUntilGranted() {
    let items = buildMenu(status: status(lid: notGranted), preferences: MenuPreferences(lidClosed: true), skillState: .current)
    let row = items.first { $0.action == .toggleLidClosed }
    #expect(row?.isEnabled == false)
    #expect(row?.isChecked == false)
    #expect(row?.title == "Allow closing the lid (enable below)")
}

@Test func lidModifierChecksWhenGrantedAndPreferred() {
    let items = buildMenu(status: status(lid: granted), preferences: MenuPreferences(lidClosed: true), skillState: .current)
    let row = items.first { $0.action == .toggleLidClosed }
    #expect(row?.isEnabled == true)
    #expect(row?.isChecked == true)
    #expect(row?.title == "Allow closing the lid")
}

@Test func offersEnableWhenNotGranted() {
    let items = buildMenu(status: status(lid: notGranted), preferences: MenuPreferences(), skillState: .current)
    #expect(items.contains { $0.action == .enableLidClosed && $0.title == "Enable lid-closed holds…" })
    #expect(!items.contains { $0.action == .disableLidClosed })
    #expect(!items.contains { $0.title.hasPrefix("Battery floor") })
}

@Test func offersFloorAndDisableWhenGranted() {
    let items = buildMenu(status: status(lid: granted), preferences: MenuPreferences(), skillState: .current)
    #expect(items.contains { $0.title == "Lid-closed holds enabled ✓" && !$0.isEnabled })
    let floor = items.first { $0.title == "Battery floor: 15%" }
    #expect(floor?.submenu.map(\.action) == batteryFloorChoices.map { .setBatteryFloor($0) })
    #expect(floor?.submenu.first { $0.action == .setBatteryFloor(15) }?.isChecked == true)
    #expect(floor?.submenu.first { $0.action == .setBatteryFloor(30) }?.isChecked == false)
    #expect(items.first { $0.action == .disableLidClosed }?.isEnabled == true)
}

@Test func disableIsGreyedWhileALidHoldIsLive() {
    let items = buildMenu(status: status(holds: [holdStatus(lidClosed: true)], lid: granted),
                          preferences: MenuPreferences(), skillState: .current)
    #expect(items.first { $0.action == .disableLidClosed }?.isEnabled == false)
}

@Test func headerShowsWarningLine() {
    let warned = LidClosedStatus(enabled: true, flagSet: true, flagSetBy: "teainate", batteryFloor: 15, lastEnded: nil,
                                 warning: "The sleep-disabled flag is set and teainate cannot clear it. Run: sudo pmset -a disablesleep 0")
    let items = buildMenu(status: status(lid: warned), preferences: MenuPreferences(), skillState: .current)
    #expect(titles(items)[1].hasPrefix("⚠ The sleep-disabled flag is set"))
}

@Test func showsLastEndedReason() {
    let ended = EndedHold(id: "h_x", label: "build", reason: "battery 14% at floor 15%", at: Date())
    let lid = LidClosedStatus(enabled: true, flagSet: false, flagSetBy: nil, batteryFloor: 15, lastEnded: ended, warning: nil)
    let items = buildMenu(status: status(lid: lid), preferences: MenuPreferences(), skillState: .current)
    #expect(titles(items).contains("Last lid-closed hold (build) ended: battery 14% at floor 15%"))
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter MenuModelTests`
Expected: compile error.

- [ ] **Step 3: Implement**

`MenuAction` gains `case toggleLidClosed, enableLidClosed, disableLidClosed` and `case setBatteryFloor(Int)`. `MenuItem` gains `public let submenu: [MenuItem]` with init param `submenu: [MenuItem] = []` (last). `MenuPreferences` gains `public var lidClosed: Bool` with init param `lidClosed: Bool = false`.

In `buildMenu`, after the header:

```swift
    items.append(MenuItem(title: headerTitle(status), isEnabled: false))
    if let warning = status.lidClosed.warning {
        items.append(MenuItem(title: "⚠ \(warning)", isEnabled: false))
    }
    if let ended = status.lidClosed.lastEnded {
        let name = ended.label.map { " (\($0))" } ?? ""
        items.append(MenuItem(title: "Last lid-closed hold\(name) ended: \(ended.reason)", isEnabled: false))
    }
    items.append(.separator)
```

After the "Keep display on" modifier:

```swift
    let lidEnabled = status.lidClosed.enabled
    items.append(MenuItem(
        title: lidEnabled ? "Allow closing the lid" : "Allow closing the lid (enable below)",
        action: .toggleLidClosed, isEnabled: lidEnabled,
        isChecked: lidEnabled && preferences.lidClosed
    ))
```

After `skillItem`, before the Quit separator:

```swift
    items.append(.separator)
    items.append(contentsOf: lidClosedItems(status))
```

and:

```swift
private func lidClosedItems(_ status: Status) -> [MenuItem] {
    let lid = status.lidClosed
    guard lid.enabled else {
        return [MenuItem(title: "Enable lid-closed holds…", action: .enableLidClosed)]
    }
    let choices = batteryFloorChoices.map { floor in
        MenuItem(title: "\(floor)%", action: .setBatteryFloor(floor), isChecked: floor == lid.batteryFloor)
    }
    let liveLidHold = status.holds.contains(where: \.lidClosed)
    return [
        MenuItem(title: "Lid-closed holds enabled ✓", isEnabled: false),
        MenuItem(title: "Battery floor: \(lid.batteryFloor)%", submenu: choices),
        // Revoking under a live watcher would leave it unable to clear the flag.
        MenuItem(title: "Disable lid-closed holds…", action: .disableLidClosed, isEnabled: !liveLidHold),
    ]
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter TeainateCoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateCore/MenuModel.swift Tests/TeainateCoreTests/MenuModelTests.swift
git commit -m "feat(core): lid-closed menu decisions"
```

---

### Task 14: App — submenu rendering, actions, admin dialog, ended-hold alert

**Files:**
- Modify: `Sources/TeainateApp/MenuRenderer.swift`
- Modify: `Sources/TeainateApp/AppDelegate.swift`

- [ ] **Step 1: Submenus in `MenuRenderer`**

```swift
    func render(_ items: [MenuItem]) -> NSMenu {
        actions.removeAll()
        var nextTag = 0
        return build(items, nextTag: &nextTag)
    }

    private func build(_ items: [MenuItem], nextTag: inout Int) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            guard !item.isSeparator else {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(title: item.title, action: #selector(fire(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = nextTag
            menuItem.isEnabled = item.isEnabled
            menuItem.state = item.isChecked ? .on : .off
            menuItem.indentationLevel = item.indent
            actions[nextTag] = item.action
            nextTag += 1
            if !item.submenu.isEmpty {
                menuItem.submenu = build(item.submenu, nextTag: &nextTag)
            }
            menu.addItem(menuItem)
        }
        return menu
    }
```

- [ ] **Step 2: `AppDelegate` changes**

Service construction: `private lazy var service = TeainateService.standard(paths: paths, watcherExecutable: cliPath)` (make `cliPath` a `let` computed from `Bundle.main.bundleURL` before it). Add `private var lastReportedEnded: Date?` and `private let grant = SudoersGrant()`.

In `applicationDidFinishLaunching`, before `refresh()`:

```swift
        // Do not alert about a hold that ended before this launch.
        lastReportedEnded = (try? service.status())?.lidClosed.lastEnded?.at
```

In `refresh()`, after computing `status`:

```swift
        if let ended = status.lidClosed.lastEnded, ended.at != lastReportedEnded {
            lastReportedEnded = ended.at
            let name = ended.label.map { " (\($0))" } ?? ""
            present(error: "Lid-closed hold\(name) ended early.", detail: ended.reason)
        }
```

New cases in `handle`:

```swift
        case .toggleLidClosed:
            preferences.lidClosed.toggle()
        case .enableLidClosed:
            runAsAdmin(script: { try grant.installScript() }, failure: "Could not enable lid-closed holds.")
        case .disableLidClosed:
            runAsAdmin(script: { try grant.removeScript() }, failure: "Could not disable lid-closed holds.")
        case .setBatteryFloor(let floor):
            do { try SettingsStore(fileURL: paths.settingsFile).write(Settings(batteryFloor: floor)) }
            catch { present(error: "Could not save the battery floor.", detail: "\(error)") }
```

`start(duration:)` passes `lidClosed: preferences.lidClosed`. Add:

```swift
    /// The only privileged code in the app: one admin dialog running a Core-generated
    /// shell script. Everything at runtime goes through `sudo -n` and the grant.
    private func runAsAdmin(script: () throws -> String, failure: String) {
        do {
            let shell = try script()
            let escaped = shell
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let source = "do shell script \"\(escaped)\" with administrator privileges"
            var error: NSDictionary?
            guard let apple = NSAppleScript(source: source) else {
                present(error: failure, detail: "Could not build the admin script."); return
            }
            apple.executeAndReturnError(&error)
            if let error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
                // -128 is the user cancelling the dialog: not an error worth an alert.
                if (error[NSAppleScript.errorNumber] as? Int) != -128 {
                    present(error: failure, detail: message)
                }
            }
        } catch {
            present(error: failure, detail: "\(error)")
        }
    }
```

- [ ] **Step 3: Build and exercise the app**

```bash
swift build && ./scripts/make-app.sh debug && open Teainate.app
```

Check by eye: "Allow closing the lid (enable below)" greyed; "Enable lid-closed holds…" present; the Battery floor submenu appears after enabling on a machine where you choose to grant. Do **not** take a lid-closed hold on a machine running other Claude Code sessions unless you intend to; it is safe, but the grant is a real system change. Quit the app after.

- [ ] **Step 4: Commit**

```bash
git add Sources/TeainateApp/MenuRenderer.swift Sources/TeainateApp/AppDelegate.swift
git commit -m "feat(app): lid-closed modifier, grant dialog, battery floor submenu"
```

---

### Task 15: Skill text, version, docs

**Files:**
- Modify: `Sources/TeainateCore/SkillInstaller.swift`, `Sources/TeainateCore/Version.swift`, `Resources/Info.plist`, `README.md`, `CLAUDE.md`, `docs/followups.md`, `docs/superpowers/specs/2026-09-03-lid-closed-holds-design.md`
- Test: `Tests/TeainateCoreTests/SkillInstallerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test func skillExplainsLidClosedHolds() {
    let text = renderSkillTemplate(cliPath: "/x/teainate")
    #expect(text.contains("--lid-closed"))
    #expect(text.contains("Enable lid-closed holds"))
    #expect(!text.contains("battery floor"))     // the skill never sets or mentions it
}
```

- [ ] **Step 2: Add the skill section** (in `skillTemplate`, after "## Options" list add `- \`--lid-closed\` — keep the Mac awake even with the lid closed; see below`, and before "## Releasing"):

```markdown
## Closing the lid

Only when the user has said they will close the laptop or take it somewhere:

```bash
{{CLI_PATH}} on --session --lid-closed --label "overnight migration"
```

Always pair `--lid-closed` with `--session` or `--for`; it refuses to run indefinitely
from the command line. If it fails with "not enabled", tell the user to choose
**Enable lid-closed holds…** in the Teainate menu. Do not try to work around it with
`pmset` or `sudo` yourself — the menu sets up a narrow, revocable grant, and anything
else leaves the Mac unable to sleep.
```

- [ ] **Step 3: Version bump**

`TeainateVersion.current = "0.2.0"`; in `Resources/Info.plist` set `CFBundleShortVersionString` to `0.2.0` (`grep -n ShortVersion Resources/Info.plist` to find it). The installed skill now reports stale and offers "Update Claude Code skill".

- [ ] **Step 4: README** — add after "### Modes":

```markdown
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
```

- [ ] **Step 5: CLAUDE.md** — under Safety add:

```markdown
**Never run `sudo pmset -a disablesleep` from a test, and never construct
`SudoSleepFlagController` in one.** The real-process watcher test passes `--no-flag`.
If this machine has the grant, a test that cleared the flag would end a real
lid-closed hold — possibly one keeping another session alive.
```

and under "Two traps" a third: the watcher's `ucomm` is `teainate`; `reconcile` is kind-aware, and `RealLidWatchTests` is the only test that proves it.

- [ ] **Step 6: followups.md** — add under "Worth doing next":

```markdown
**Lid-closed holds: deferred rails.** Low Power Mode step-aside (overlaps the floor;
one more thing to poll), a per-hold floor override for humans at the CLI, and a
`status` line for "grant present but sudo refuses" (only detectable by a `sudo -n`
probe, which `status` deliberately never runs — today it surfaces at `on` time).
```

- [ ] **Step 7: Spec touch-up** — in the spec's watcher section, replace the illustrative command line with the exact one from `lidWatchArguments` (`--caffeinate "-i -t 7200"` rather than `-- -i -t 7200`), and in Error handling note that "grant present but not working" surfaces at `on`, not in `status` (see followups).

- [ ] **Step 8: Run everything**

Run: `swift test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add -A Sources/TeainateCore/SkillInstaller.swift Sources/TeainateCore/Version.swift Resources/Info.plist README.md CLAUDE.md docs/
git commit -m "docs: lid-closed holds in skill, README, CLAUDE.md; bump to 0.2.0"
```

---

## Manual checklist (required before calling this shipped)

Nothing here can be automated: setting the real flag needs the grant and closing the lid needs a human. Do it on a MacBook, on battery, with nothing else important running.

1. `./scripts/make-app.sh debug && open Teainate.app`, choose **Enable lid-closed holds…**, enter the admin password. `cat /etc/sudoers.d/teainate-$USER` shows the one rule. `pmset -g | grep SleepDisabled` is 0 or absent.
2. On battery above the floor: `.build/debug/teainate on --lid-closed --for 10m --label lidtest`. `pmset -g | grep SleepDisabled` shows 1. `teainate status` shows `lidtest — 10 min left (lid ok, off at 15%)`.
3. `while sleep 60; do date >> ~/awake.log; done &`, close the lid for ten minutes, open it. `wc -l ~/awake.log` is 10 (±1).
4. Wait for expiry. `pmset -g | grep SleepDisabled` is 0 or absent; `teainate status` shows no holds; `lid-watch.log` ends with `ended: timer expired`.
5. Set the floor to 50% from the menu with the battery below 50%. `teainate on --lid-closed --for 5m` is refused with "Battery at N%, at or below the 50% floor". Plug in, run it again (allowed), unplug: within a minute `status` shows `Last lid-closed hold ended: battery N% at floor 50%` and the flag is clear. Reset the floor to 15%.
6. Take a hold, `pkill -9 -f lid-watch`, run `teainate status`: the flag is clear and the menu shows no warning.
7. **Disable lid-closed holds…** from the menu. The sudoers file is gone; `teainate on --lid-closed --for 1m` says "not enabled". `rm ~/awake.log`.
