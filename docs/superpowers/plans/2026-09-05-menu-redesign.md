# Menu Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the menu bar UI so every checkbox reflects live state, each hold carries its own controls, new-hold defaults persist, one-time setup lives under Settings, and the icon is a template cup.

**Architecture:** All decisions stay in `TeainateCore` (`MenuModel.swift`, `StatusRendering.swift`, `TeainateService.swift`); the AppKit app remains a thin renderer. Editing a live hold is a new `TeainateService.modify` that composes the existing `on` (spawn the replacement) and `off` (release the original), in that order, so the Mac is never unheld. A replacement gets a fresh id and records lineage in a new `replaces` field so `off --id <original>` keeps working.

**Tech Stack:** Swift 6.3, SwiftPM, Swift Testing (`import Testing`, `#expect`, `#require`), AppKit for the app only.

**Spec:** `docs/superpowers/specs/2026-09-05-menu-redesign-design.md`

## Global Constraints

- `swiftLanguageModes: [.v6]`: strict concurrency, everything crossing a boundary is `Sendable`.
- Core must never import AppKit. The app and CLI never spawn processes; everything goes through `TeainateService`.
- JSON keys are snake_case. New keys: `replaces`, `watched_pid` (on status), `new_hold_defaults` with `display`, `ac_only`, `lid_closed`.
- `MenuRenderer` contains no decisions; every show/enable/check decision is in `MenuModel.swift`.
- Tests: Swift Testing only, never XCTest. Hermetic tests in `Tests/TeainateCoreTests`; real-process tests in `Tests/TeainateIntegrationTests`.
- Real-process tests: only terminate PIDs the test spawned, give every caffeinate a short `-t` backstop, clean up in `defer`. Never run `teainate off --untracked`. Never call `set()` or `clear()` on a real `SudoSleepFlagController`. Never run `sudo pmset`.
- Run the fast suite with `swift test --filter TeainateCoreTests`; the full suite with `swift test` (needs `swift build` first so the CLI binary exists for the watcher tests).
- Commit messages end with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01RSceqhFUtg1vZMS5hh5hmT
  ```

---

## File map

| File | Change |
| --- | --- |
| `Sources/TeainateCore/Hold.swift` | Add `HoldModifier`; `replaces` on `HoldOptions` and `Hold`; `replacementOptions(for:changing:to:now:)` |
| `Sources/TeainateCore/TeainateService.swift` | `watchedPID` and `replaces` on `HoldStatus`; `off(id:exact:)` lineage matching; `modify`; `ServiceError.holdNotFound` |
| `Sources/TeainateCore/Errors.swift` | Sentence for `holdNotFound` |
| `Sources/TeainateCore/Settings.swift` | `NewHoldDefaults`, `Settings.newHoldDefaults`, tolerant decoding |
| `Sources/TeainateCore/StatusRendering.swift` | `menuTitle(for:)`, `menuDetail(for:now:calendar:locale:)`, shared `modifierFacts` |
| `Sources/TeainateCore/MenuModel.swift` | Rewritten: new `MenuAction`, five-block `buildMenu`, `newHoldOptions` |
| `Sources/teainate/Teainate.swift` | `On.run` passes `watchedPID` and `replaces` into `HoldStatus` |
| `Sources/TeainateApp/AppDelegate.swift` | Defaults from settings, `modify` wiring, template icon |
| `Tests/TeainateCoreTests/HoldStoreTests.swift` | Legacy record decodes with `replaces == nil` |
| `Tests/TeainateCoreTests/ReplacementOptionsTests.swift` | New |
| `Tests/TeainateCoreTests/SettingsTests.swift` | Defaults round-trip and tolerance |
| `Tests/TeainateCoreTests/ServiceTests.swift` | `modify`, lineage, `holdNotFound` |
| `Tests/TeainateCoreTests/LidClosedServiceTests.swift` | Lid transitions through `modify` |
| `Tests/TeainateCoreTests/OutputTests.swift` | `menuTitle`, `menuDetail`, status JSON keys |
| `Tests/TeainateCoreTests/MenuModelTests.swift` | Rewritten |
| `Tests/TeainateIntegrationTests/RealCaffeinateTests.swift` | Real `modify` |
| `Tests/TeainateIntegrationTests/RealLidWatchTests.swift` | Real lid transitions via `NoFlagWatcherSpawner` |
| `docs/followups.md`, `CLAUDE.md`, `Sources/TeainateCore/Version.swift`, `Resources/Info.plist` | Docs and version |

---

### Task 1: `HoldModifier`, lineage, and watched pid on records and status

**Files:**
- Modify: `Sources/TeainateCore/Hold.swift`
- Modify: `Sources/TeainateCore/TeainateService.swift` (`HoldStatus` at ~line 68, `on` at ~261, `onLidClosed` record at ~410, `status()` at ~466)
- Modify: `Sources/teainate/Teainate.swift` (`On.run`, the `HoldStatus(...)` construction)
- Test: `Tests/TeainateCoreTests/HoldStoreTests.swift`, `Tests/TeainateCoreTests/OutputTests.swift`

**Interfaces:**
- Produces: `public enum HoldModifier: String, Sendable, Equatable, CaseIterable { case display, acOnly, lidClosed }`
- Produces: `HoldOptions.replaces: String?` (init parameter, default nil, last)
- Produces: `Hold.replaces: String?` (init parameter `replaces: String? = nil`, after `processStartedAt`), JSON key `replaces`
- Produces: `HoldStatus.watchedPID: pid_t?` (JSON `watched_pid`) and `HoldStatus.replaces: String?` (JSON `replaces`), both init parameters with default nil, after `batteryFloor`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TeainateCoreTests/HoldStoreTests.swift`:

```swift
@Test func holdRecordRoundTripsLineage() throws {
    var h = hold("h_2", pid: 100)
    h.replaces = "h_1"
    let data = try Hold.encoder.encode(h)
    #expect(String(decoding: data, as: UTF8.self).contains("\"replaces\""))
    #expect(try Hold.decoder.decode(Hold.self, from: data) == h)
}
```

In the existing `oldArrayShapedStateFileStillLoads` test, add after the `processStartedAt == nil` line:

```swift
    #expect(state.holds.first?.replaces == nil)
```

Append to `Tests/TeainateCoreTests/OutputTests.swift`:

```swift
@Test func statusJSONCarriesWatchedPIDAndLineage() throws {
    let hold = HoldStatus(
        id: "h_2", kind: .process, label: nil, source: .claude,
        expiresAt: nil, remainingSeconds: nil, display: false, acOnly: false,
        watchedPID: 6707, replaces: "h_1"
    )
    let text = String(decoding: try Status.encoder.encode(status(holds: [hold])), as: UTF8.self)
    #expect(text.contains("\"watched_pid\""))
    #expect(text.contains("6707"))
    #expect(text.contains("\"replaces\""))
    #expect(text.contains("\"h_1\""))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "holdRecordRoundTripsLineage|statusJSONCarriesWatchedPIDAndLineage|oldArrayShapedStateFileStillLoads"`
Expected: compile errors, `replaces` and `watchedPID` do not exist.

- [ ] **Step 3: Add `HoldModifier` and `replaces` in `Hold.swift`**

Below `HoldSource`, add:

```swift
/// One of the three per-hold switches the menu can flip on a live hold.
public enum HoldModifier: String, Sendable, Equatable, CaseIterable {
    case display, acOnly, lidClosed
}
```

In `HoldOptions`, add a stored property and init parameter:

```swift
    /// The id of the hold this one replaces (see `TeainateService.modify`). Copied
    /// onto the record so `off --id` with the original id still finds the live hold.
    public var replaces: String?
```

and in `init`, add `replaces: String? = nil` as the last parameter with `self.replaces = replaces`.

In `Hold`, after `processStartedAt`:

```swift
    /// Lineage: the id of the *first* hold in a chain of `modify` replacements. A
    /// replacement never reuses an id — an exiting lid-closed watcher removes its
    /// record by id, and would take a same-id successor with it — so this is how the
    /// id a creator was given keeps naming the live hold.
    public var replaces: String?
```

Add `replaces: String? = nil` as the last `init` parameter (`self.replaces = replaces`), add `case replaces` to `CodingKeys`, and in `init(from:)` add:

```swift
        replaces = try c.decodeIfPresent(String.self, forKey: .replaces)
```

- [ ] **Step 4: Carry it through `HoldStatus`, `on`, `onLidClosed`, `status()`, and the CLI**

In `TeainateService.swift`, `HoldStatus`: add

```swift
    public let watchedPID: pid_t?
    public let replaces: String?
```

Extend the init with `watchedPID: pid_t? = nil, replaces: String? = nil` after `batteryFloor` and assign both. Add to `CodingKeys`:

```swift
        case watchedPID = "watched_pid"
        case replaces
```

In `on`, the `Hold(...)` construction: add `replaces: options.replaces` after `processStartedAt: startedAt`. In `onLidClosed`, the `Hold(...)` construction: add `replaces: options.replaces` after `processStartedAt: startedAt`.

In `status()`, the `HoldStatus(...)` construction: add `watchedPID: hold.watchedPID, replaces: hold.replaces` after `batteryFloor: hold.batteryFloor`.

In `Sources/teainate/Teainate.swift`, `On.run`, the `HoldStatus(...)` construction: add `watchedPID: hold.watchedPID, replaces: hold.replaces` after `batteryFloor: hold.batteryFloor`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter TeainateCoreTests`
Expected: all pass, including the three from Step 1.

- [ ] **Step 6: Commit**

```bash
git add Sources/TeainateCore/Hold.swift Sources/TeainateCore/TeainateService.swift Sources/teainate/Teainate.swift Tests/TeainateCoreTests/HoldStoreTests.swift Tests/TeainateCoreTests/OutputTests.swift
git commit -m "feat(core): HoldModifier; hold lineage (replaces); watched pid on status"
```

---

### Task 2: `replacementOptions`

**Files:**
- Modify: `Sources/TeainateCore/Hold.swift`
- Create: `Tests/TeainateCoreTests/ReplacementOptionsTests.swift`

**Interfaces:**
- Consumes: `HoldModifier`, `HoldOptions.replaces`, `Hold.replaces` (Task 1)
- Produces: `public func replacementOptions(for hold: Hold, changing modifier: HoldModifier, to value: Bool, now: Date) -> HoldOptions?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/TeainateCoreTests/ReplacementOptionsTests.swift`:

```swift
import Testing
import Foundation
@testable import TeainateCore

private let now = Date(timeIntervalSince1970: 1_000_000)

private func hold(
    kind: HoldKind = .timer, expiresAt: Date? = now.addingTimeInterval(2520),
    watched: pid_t? = nil, label: String? = "build", source: HoldSource = .cli,
    display: Bool = false, acOnly: Bool = false, lidClosed: Bool = false,
    replaces: String? = nil
) -> Hold {
    Hold(
        id: "h_orig", kind: kind, label: label, source: source, caffeinatePID: 100,
        flags: ["-i"], startedAt: now.addingTimeInterval(-60), expiresAt: expiresAt,
        watchedPID: watched, display: display, acOnly: acOnly, lidClosed: lidClosed,
        batteryFloor: lidClosed ? 15 : nil, replaces: replaces
    )
}

@Test func flipsOnlyTheRequestedModifier() throws {
    let base = hold(display: false, acOnly: true, lidClosed: false)
    let display = try #require(replacementOptions(for: base, changing: .display, to: true, now: now))
    #expect(display.display == true && display.acOnly == true && display.lidClosed == false)

    let ac = try #require(replacementOptions(for: base, changing: .acOnly, to: false, now: now))
    #expect(ac.display == false && ac.acOnly == false && ac.lidClosed == false)

    let lid = try #require(replacementOptions(for: base, changing: .lidClosed, to: true, now: now))
    #expect(lid.display == false && lid.acOnly == true && lid.lidClosed == true)
}

@Test func preservesKindLabelSourceAndWatchedPID() throws {
    let options = try #require(replacementOptions(
        for: hold(kind: .process, expiresAt: nil, watched: 6707, label: "migration", source: .claude),
        changing: .display, to: true, now: now))
    #expect(options.kind == .process)
    #expect(options.watchedPID == 6707)
    #expect(options.label == "migration")
    #expect(options.source == .claude)
    #expect(options.duration == nil)
}

@Test func timerCarriesRemainingSecondsNotOriginalLength() throws {
    let options = try #require(replacementOptions(
        for: hold(expiresAt: now.addingTimeInterval(2520)), changing: .display, to: true, now: now))
    #expect(options.duration == 2520)
    #expect(options.kind == .timer)
}

@Test func foreverHoldStaysForever() throws {
    let options = try #require(replacementOptions(
        for: hold(kind: .forever, expiresAt: nil), changing: .acOnly, to: true, now: now))
    #expect(options.kind == .forever)
    #expect(options.duration == nil)
}

@Test func underASecondLeftYieldsNothing() {
    #expect(replacementOptions(for: hold(expiresAt: now.addingTimeInterval(0.5)), changing: .display, to: true, now: now) == nil)
    #expect(replacementOptions(for: hold(expiresAt: now.addingTimeInterval(-10)), changing: .display, to: true, now: now) == nil)
}

@Test func lineagePointsAtTheFirstHoldInTheChain() throws {
    let first = try #require(replacementOptions(for: hold(), changing: .display, to: true, now: now))
    #expect(first.replaces == "h_orig")

    let later = try #require(replacementOptions(for: hold(replaces: "h_root"), changing: .display, to: true, now: now))
    #expect(later.replaces == "h_root")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ReplacementOptionsTests`
Expected: compile error, `replacementOptions` not found.

- [ ] **Step 3: Implement**

Append to `Sources/TeainateCore/Hold.swift`:

```swift
/// The options that recreate `hold` with one modifier flipped, for
/// `TeainateService.modify`. The end time stays where it was: a timer carries only
/// its remaining seconds. nil when under a second remains — there is nothing left to
/// recreate, and the caller reports the hold as gone.
public func replacementOptions(
    for hold: Hold, changing modifier: HoldModifier, to value: Bool, now: Date
) -> HoldOptions? {
    var duration: TimeInterval?
    if let expiresAt = hold.expiresAt {
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining >= 1 else { return nil }
        duration = remaining
    }
    var options = HoldOptions(
        duration: duration, watchedPID: hold.watchedPID, acOnly: hold.acOnly,
        display: hold.display, label: hold.label, lidClosed: hold.lidClosed,
        source: hold.source, replaces: hold.replaces ?? hold.id
    )
    switch modifier {
    case .display: options.display = value
    case .acOnly: options.acOnly = value
    case .lidClosed: options.lidClosed = value
    }
    return options
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ReplacementOptionsTests`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateCore/Hold.swift Tests/TeainateCoreTests/ReplacementOptionsTests.swift
git commit -m "feat(core): replacementOptions builds a hold's successor with one modifier flipped"
```

---

### Task 3: Persistent `NewHoldDefaults`

**Files:**
- Modify: `Sources/TeainateCore/Settings.swift`
- Test: `Tests/TeainateCoreTests/SettingsTests.swift`

**Interfaces:**
- Consumes: `HoldModifier` (Task 1)
- Produces: `public struct NewHoldDefaults: Codable, Sendable, Equatable { var display, acOnly, lidClosed: Bool; init(display:acOnly:lidClosed:) all default false; static let off; subscript(HoldModifier) -> Bool get/set }`
- Produces: `Settings.newHoldDefaults: NewHoldDefaults`; `Settings.init(batteryFloor: Int = defaultBatteryFloor, newHoldDefaults: NewHoldDefaults = .off)`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TeainateCoreTests/SettingsTests.swift`:

```swift
@Test func newHoldDefaultsRoundTrip() throws {
    let store = tempSettings()
    try store.write(Settings(batteryFloor: 20, newHoldDefaults: NewHoldDefaults(display: true, acOnly: false, lidClosed: true)))
    let (settings, warning) = store.read()
    #expect(settings.batteryFloor == 20)
    #expect(settings.newHoldDefaults == NewHoldDefaults(display: true, acOnly: false, lidClosed: true))
    #expect(warning == nil)
}

@Test func settingsFileWithoutDefaultsReadsAsAllOff() throws {
    let store = tempSettings()
    try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"battery_floor": 30}"#.write(to: store.fileURL, atomically: true, encoding: .utf8)
    let (settings, warning) = store.read()
    #expect(settings.batteryFloor == 30)
    #expect(settings.newHoldDefaults == .off)
    #expect(warning == nil)
}

@Test func newHoldDefaultsUseSnakeCaseKeys() throws {
    let store = tempSettings()
    try store.write(Settings(newHoldDefaults: NewHoldDefaults(acOnly: true, lidClosed: true)))
    let text = try String(contentsOf: store.fileURL, encoding: .utf8)
    #expect(text.contains("\"new_hold_defaults\""))
    #expect(text.contains("\"ac_only\" : true"))
    #expect(text.contains("\"lid_closed\" : true"))
}

@Test func defaultsSubscriptReadsAndWritesEachModifier() {
    var defaults = NewHoldDefaults.off
    for modifier in HoldModifier.allCases {
        #expect(defaults[modifier] == false)
        defaults[modifier] = true
        #expect(defaults[modifier] == true)
    }
    #expect(defaults == NewHoldDefaults(display: true, acOnly: true, lidClosed: true))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SettingsTests`
Expected: compile errors, `NewHoldDefaults` not found.

- [ ] **Step 3: Implement**

In `Sources/TeainateCore/Settings.swift`, add above `Settings`:

```swift
/// What a hold started from the menu gets unless the user changes it afterwards.
/// Persisted so a ticked box means the same thing next week — a physical switch does
/// not reset itself when you close the lid.
public struct NewHoldDefaults: Codable, Sendable, Equatable {
    public var display: Bool
    public var acOnly: Bool
    public var lidClosed: Bool

    public init(display: Bool = false, acOnly: Bool = false, lidClosed: Bool = false) {
        self.display = display
        self.acOnly = acOnly
        self.lidClosed = lidClosed
    }

    enum CodingKeys: String, CodingKey {
        case display
        case acOnly = "ac_only"
        case lidClosed = "lid_closed"
    }

    public static let off = NewHoldDefaults()

    public subscript(modifier: HoldModifier) -> Bool {
        get {
            switch modifier {
            case .display: return display
            case .acOnly: return acOnly
            case .lidClosed: return lidClosed
            }
        }
        set {
            switch modifier {
            case .display: display = newValue
            case .acOnly: acOnly = newValue
            case .lidClosed: lidClosed = newValue
            }
        }
    }
}
```

Replace the `Settings` struct with:

```swift
public struct Settings: Codable, Sendable, Equatable {
    public var batteryFloor: Int
    public var newHoldDefaults: NewHoldDefaults

    public init(batteryFloor: Int = defaultBatteryFloor, newHoldDefaults: NewHoldDefaults = .off) {
        self.batteryFloor = batteryFloor
        self.newHoldDefaults = newHoldDefaults
    }

    enum CodingKeys: String, CodingKey {
        case batteryFloor = "battery_floor"
        case newHoldDefaults = "new_hold_defaults"
    }

    /// Explicit so a settings.json written before new-hold defaults existed still loads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        batteryFloor = try c.decodeIfPresent(Int.self, forKey: .batteryFloor) ?? defaultBatteryFloor
        newHoldDefaults = try c.decodeIfPresent(NewHoldDefaults.self, forKey: .newHoldDefaults) ?? .off
    }

    public static let `default` = Settings()
}
```

`SettingsStore.read()` and `write(_:)` are unchanged; the floor checks still apply.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SettingsTests`
Expected: all pass (existing seven plus four new).

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateCore/Settings.swift Tests/TeainateCoreTests/SettingsTests.swift
git commit -m "feat(core): persistent new-hold defaults in settings.json"
```

---

### Task 4: `modify`, lineage-aware `off`, and `holdNotFound`

**Files:**
- Modify: `Sources/TeainateCore/TeainateService.swift` (`ServiceError` at line 3, `off` at ~437)
- Modify: `Sources/TeainateCore/Errors.swift`
- Test: `Tests/TeainateCoreTests/ServiceTests.swift`, `Tests/TeainateCoreTests/ErrorDescriptionTests.swift`

**Interfaces:**
- Consumes: `replacementOptions` (Task 2), `Hold.replaces` (Task 1)
- Produces: `ServiceError.holdNotFound(String)`
- Produces: `public func off(id: String?, exact: Bool = false) throws -> [Hold]` — with `exact == false`, `id` matches `hold.id` or `hold.replaces`
- Produces: `public func modify(id: String, changing modifier: HoldModifier, to value: Bool) throws -> Hold`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TeainateCoreTests/ServiceTests.swift`:

```swift
// modify is `on` then `off`: the replacement exists before the original is signalled,
// so the Mac is never unheld in between.
@Test func modifySpawnsReplacementBeforeTerminatingOriginal() throws {
    let spawner = RecordingSpawner()
    let service = makeService(spawner: spawner, snapshotter: StubSnapshotter(table: liveTable(100, 101)))
    let original = try service.on(HoldOptions(duration: 3600, source: .menu))

    let replacement = try service.modify(id: original.id, changing: .display, to: true)

    #expect(spawner.spawned == [["-i", "-t", "3600"], ["-i", "-d", "-t", "3600"]])
    #expect(spawner.terminated == [100])
    #expect(replacement.caffeinatePID == 101)
    #expect(replacement.id != original.id)
    #expect(replacement.replaces == original.id)
    #expect(replacement.display)
    #expect(replacement.kind == .timer)
    let drift = abs(replacement.expiresAt!.timeIntervalSince(original.expiresAt!))
    #expect(drift < 1)
    #expect(try service.status().holds.map(\.id) == [replacement.id])
}

@Test func refusedModifyLeavesTheOriginalUntouched() throws {
    let spawner = RecordingSpawner()
    let service = makeService(spawner: spawner, snapshotter: StubSnapshotter(table: liveTable(100)))
    let original = try service.on(HoldOptions(source: .menu))
    spawner.shouldFail = true

    #expect(throws: ServiceError.spawnFailed("boom")) {
        try service.modify(id: original.id, changing: .display, to: true)
    }
    #expect(spawner.terminated.isEmpty)
    #expect(try service.status().holds.map(\.id) == [original.id])
}

@Test func modifyUnknownIDThrowsHoldNotFound() {
    let service = makeService()
    #expect(throws: ServiceError.holdNotFound("h_nope")) {
        try service.modify(id: "h_nope", changing: .display, to: true)
    }
}

@Test func offByOriginalIDReleasesTheReplacementChain() throws {
    let spawner = RecordingSpawner()
    let service = makeService(spawner: spawner, snapshotter: StubSnapshotter(table: liveTable(100, 101, 102)))
    let original = try service.on(HoldOptions(source: .menu))
    let second = try service.modify(id: original.id, changing: .display, to: true)
    // Addressed by the original id even though only the replacement is live.
    let third = try service.modify(id: original.id, changing: .acOnly, to: true)
    #expect(second.replaces == original.id)
    #expect(third.replaces == original.id)
    #expect(third.flags == ["-s", "-d"])

    let released = try service.off(id: original.id)
    #expect(released.map(\.id) == [third.id])
    #expect(spawner.terminated == [100, 101, 102])
    #expect(try service.status().holds.isEmpty)
}

@Test func offByReplacementIDStillWorks() throws {
    let spawner = RecordingSpawner()
    let service = makeService(spawner: spawner, snapshotter: StubSnapshotter(table: liveTable(100, 101)))
    let original = try service.on(HoldOptions(source: .menu))
    let replacement = try service.modify(id: original.id, changing: .display, to: true)
    #expect(try service.off(id: replacement.id).map(\.id) == [replacement.id])
}
```

Append to `Tests/TeainateCoreTests/ErrorDescriptionTests.swift`:

```swift
@Test func holdNotFoundReadsAsASentence() {
    #expect("\(ServiceError.holdNotFound("h_1"))" == "No hold with id 'h_1'. It may have already ended.")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "ServiceTests|ErrorDescriptionTests"`
Expected: compile errors, `modify` and `holdNotFound` not found.

- [ ] **Step 3: Implement**

In `TeainateService.swift`, add to `ServiceError`:

```swift
    case holdNotFound(String)
```

In `Errors.swift`, add to the `ServiceError` switch:

```swift
        case .holdNotFound(let id):
            return "No hold with id '\(id)'. It may have already ended."
```

Replace `off` with:

```swift
    /// Releases one hold by id, or every hold when `id` is nil. Returns what was released.
    ///
    /// An id matches a hold's own id or its lineage (`replaces`), so the id `on` printed
    /// keeps releasing that hold after the menu has edited it. `exact` restricts the
    /// match to the hold's own id: `modify` uses it to release the original without
    /// also releasing the replacement it just made, which shares the lineage.
    public func off(id: String?, exact: Bool = false) throws -> [Hold] {
        let released = try store.mutate { holds -> [Hold] in
            let matching = holds.filter { hold in
                guard let id else { return true }
                return hold.id == id || (!exact && hold.replaces == id)
            }
            holds.removeAll { hold in matching.contains { $0.id == hold.id } }
            return matching
        }
        for hold in released {
            spawner.terminate(pid: hold.caffeinatePID)
        }
        // The release already happened (holds removed, processes signalled); a lock
        // timeout here must not turn that into a reported failure. The next read
        // retries this cleanup.
        try? clearOrphanedFlag()
        return released
    }

    /// Recreates one live hold with a modifier flipped, keeping its lifetime.
    ///
    /// `on` first, `off` second: the replacement is spawned and recorded before the
    /// original is signalled, so the Mac is never unheld between them. Every lid-closed
    /// pre-flight applies to the replacement; if `on` refuses, nothing has changed. The
    /// replacement carries a fresh id (see `Hold.replaces` for why) and the original's
    /// lineage. For a moment both holds are live and `status` reports both — true, if
    /// brief.
    public func modify(id: String, changing modifier: HoldModifier, to value: Bool) throws -> Hold {
        let holds = try store.read()
        guard let original = holds.first(where: { $0.id == id }) ?? holds.first(where: { $0.replaces == id }),
              let options = replacementOptions(for: original, changing: modifier, to: value, now: now())
        else { throw ServiceError.holdNotFound(id) }
        let replacement = try on(options)
        _ = try off(id: original.id, exact: true)
        return replacement
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TeainateCoreTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateCore/TeainateService.swift Sources/TeainateCore/Errors.swift Tests/TeainateCoreTests/ServiceTests.swift Tests/TeainateCoreTests/ErrorDescriptionTests.swift
git commit -m "feat(core): modify recreates a hold with one modifier flipped; off matches lineage"
```

---

### Task 5: Lid transitions through `modify` (hermetic)

**Files:**
- Test: `Tests/TeainateCoreTests/LidClosedServiceTests.swift`

**Interfaces:**
- Consumes: `TeainateService.modify` (Task 4). No production code changes expected; if a test fails, the fix belongs in `modify`, not in the test.

- [ ] **Step 1: Add a state reader to `Rig`**

Inside the `Rig` struct (after the `lid(...)` helper), add:

```swift
    /// The persisted store state, read through a fresh store over the given table.
    func state(table: [pid_t: ProcessSnapshot]) throws -> StoreState {
        let clock = self.clock
        return try HoldStore(fileURL: stateFile, snapshotter: StubSnapshotter(table: table),
                             startTimes: StubStartTimes(times: [:]), now: { clock.time }).readState()
    }
```

- [ ] **Step 2: Write the failing tests**

Append to `LidClosedServiceTests.swift`:

```swift
// off→on: the watcher is spawned (and the flag set) while the plain caffeinate is
// still alive; only then is the caffeinate signalled.
@Test func modifyToLidClosedSpawnsTheWatcherBeforeReleasingTheCaffeinate() throws {
    let table = Rig.table((500, "caffeinate"), (100, "teainate"))
    let rig = Rig(table: table)
    let plain = try rig.service.on(HoldOptions(duration: 7200, source: .menu))
    #expect(plain.caffeinatePID == 500)
    rig.watcher.onSpawn = { #expect(rig.spawner.terminated.isEmpty, "caffeinate signalled before the watcher existed") }

    let lid = try rig.service.modify(id: plain.id, changing: .lidClosed, to: true)

    #expect(lid.lidClosed)
    #expect(lid.caffeinatePID == 100)
    #expect(lid.replaces == plain.id)
    #expect(rig.flag.setCount == 1)
    #expect(rig.watcher.launches.count == 1)
    #expect(rig.watcher.launches[0].1.contains("-i -t 7200"))
    #expect(rig.spawner.terminated == [500])
    let state = try rig.state(table: table)
    #expect(state.holds.map(\.id) == [lid.id])
    #expect(state.lidFlagOwned)
}

// on→off: no watcher runs hermetically, so nothing clears the flag on the watcher's
// exit. The service's own orphan cleanup at the end of `off` sees the marker owned
// with no lid-closed hold live and clears it.
@Test func modifyFromLidClosedReleasesTheWatcherAndCleanupClearsTheFlag() throws {
    let table = Rig.table((500, "caffeinate"), (100, "teainate"))
    let rig = Rig(table: table)
    let lid = try rig.service.on(rig.lid())
    #expect(rig.flag.value)

    let plain = try rig.service.modify(id: lid.id, changing: .lidClosed, to: false)

    #expect(!plain.lidClosed)
    #expect(plain.caffeinatePID == 500)
    #expect(rig.spawner.terminated == [100])
    #expect(rig.flag.value == false)
    #expect(rig.flag.clearCount == 1)
    let state = try rig.state(table: table)
    #expect(state.holds.map(\.id) == [plain.id])
    #expect(state.lidFlagOwned == false)
}

// on→on: two watchers overlap briefly; the marker and flag stay owned throughout.
@Test func modifyOnALidHoldKeepsTheFlagOwnedThroughout() throws {
    let table = Rig.table((100, "teainate"), (101, "teainate"))
    let rig = Rig(table: table)
    let first = try rig.service.on(rig.lid())

    let second = try rig.service.modify(id: first.id, changing: .display, to: true)

    #expect(second.lidClosed && second.display)
    #expect(second.caffeinatePID == 101)
    #expect(rig.watcher.launches.count == 2)
    #expect(rig.watcher.launches[1].1.contains("-i -d -t 7200"))
    #expect(rig.spawner.terminated == [100])
    #expect(rig.flag.value)
    #expect(rig.flag.clearAttempts == 0)
    let state = try rig.state(table: table)
    #expect(state.holds.map(\.id) == [second.id])
    #expect(state.lidFlagOwned)
}

@Test func refusedLidModifyLeavesTheOriginalLive() throws {
    let table = Rig.table((100, "teainate"))
    let rig = Rig(battery: BatteryState(source: .battery, percent: 90), table: table)
    let lid = try rig.service.on(rig.lid())

    #expect(throws: ServiceError.notOnACPower) {
        try rig.service.modify(id: lid.id, changing: .acOnly, to: true)
    }
    #expect(rig.spawner.terminated.isEmpty)
    #expect(rig.watcher.launches.count == 1)
    #expect(try rig.service.status().holds.map(\.id) == [lid.id])
    #expect(rig.flag.value)
}
```

- [ ] **Step 3: Run the tests**

Run: `swift test --filter LidClosedServiceTests`
Expected: all pass. If `modifyFromLidClosedReleasesTheWatcherAndCleanupClearsTheFlag` fails on `clearCount`, check that `off` still ends with `try? clearOrphanedFlag()` and that the replacement was recorded with `lidFlagPendingSince == nil`; do not change the test's expectations.

- [ ] **Step 4: Commit**

```bash
git add Tests/TeainateCoreTests/LidClosedServiceTests.swift
git commit -m "test(core): lid-closed transitions through modify"
```

---

### Task 6: `menuTitle` and `menuDetail`

**Files:**
- Modify: `Sources/TeainateCore/StatusRendering.swift`
- Test: `Tests/TeainateCoreTests/OutputTests.swift`

**Interfaces:**
- Consumes: `HoldStatus.watchedPID` (Task 1)
- Produces: `public func menuTitle(for hold: HoldStatus) -> String`
- Produces: `public func menuDetail(for hold: HoldStatus, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TeainateCoreTests/OutputTests.swift`:

```swift
// Menu rows: facts joined with middle dots, no id, no verb.
@Test func menuTitleJoinsLabelLifetimeAndModifiers() {
    #expect(menuTitle(for: holdStatus(kind: .timer, remaining: 2520)) == "42 min left")
    #expect(menuTitle(for: holdStatus(kind: .timer, label: "build", remaining: 2520, display: true, lidClosed: true, floor: 15))
            == "build · 42 min left · display on · lid ok · off at 15%")
    #expect(menuTitle(for: holdStatus(kind: .forever, acOnly: true)) == "indefinitely · only while plugged in")
    #expect(menuTitle(for: holdStatus(kind: .forever, label: "focus time")) == "focus time")
}

@Test func menuTitleNamesAClaudeSession() {
    let claude = HoldStatus(id: "h_c", kind: .process, label: nil, source: .claude,
                            expiresAt: nil, remainingSeconds: nil, display: false, acOnly: false, watchedPID: 6707)
    #expect(menuTitle(for: claude) == "Claude session · until it exits")
    #expect(menuTitle(for: holdStatus(kind: .process)) == "until session exits")
}

private var utcEnglish: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}

@Test func menuDetailStatesTheTimerEndAsAClockTime() {
    let now = ISO8601DateFormatter().date(from: "2026-09-05T14:00:00Z")!
    let end = now.addingTimeInterval(72 * 60)                      // 15:12 UTC, same day
    let hold = HoldStatus(id: "h_t", kind: .timer, label: nil, source: .menu,
                          expiresAt: end, remainingSeconds: 4320, display: false, acOnly: false)
    let text = menuDetail(for: hold, now: now, calendar: utcEnglish, locale: Locale(identifier: "en_US"))
    #expect(text.hasPrefix("until 3:12"))
    #expect(!text.contains("Sep"))
}

@Test func menuDetailAddsTheDateWhenTheEndIsNotToday() {
    let now = ISO8601DateFormatter().date(from: "2026-09-05T14:00:00Z")!
    let end = now.addingTimeInterval(25 * 3600)                    // 2026-09-06 15:00 UTC
    let hold = HoldStatus(id: "h_t", kind: .timer, label: nil, source: .menu,
                          expiresAt: end, remainingSeconds: 90000, display: false, acOnly: false)
    let text = menuDetail(for: hold, now: now, calendar: utcEnglish, locale: Locale(identifier: "en_US"))
    #expect(text.hasPrefix("until "))
    #expect(text.contains("Sep 6"))
    #expect(text.contains("3:00"))
}

@Test func menuDetailNamesTheWatchedProcessOrSaysIndefinitely() {
    let watched = HoldStatus(id: "h_p", kind: .process, label: nil, source: .claude,
                             expiresAt: nil, remainingSeconds: nil, display: false, acOnly: false, watchedPID: 6707)
    #expect(menuDetail(for: watched, now: Date()) == "until pid 6707 exits")
    #expect(menuDetail(for: holdStatus(kind: .forever), now: Date()) == "indefinitely")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter OutputTests`
Expected: compile errors, `menuTitle` and `menuDetail` not found.

- [ ] **Step 3: Implement**

In `Sources/TeainateCore/StatusRendering.swift`, replace `describe(_:includingID:)` and `defaultLabel(for:)` with:

```swift
/// A one-line description of a hold for the CLI.
///
/// A label never replaces the remaining time — "how much longer do I have?" is the
/// question this tool exists to answer, so a labelled timer shows both:
/// `build — 42 min left`.
///
/// `includingID` exists because the two surfaces need different things: in the CLI the
/// id is essential (you need it for `off --id`), but in the menu you click a row to
/// release it, so the id is noise.
public func describe(_ hold: HoldStatus, includingID: Bool = true) -> String {
    var parts: [String] = []

    let lifetime = defaultLabel(for: hold)
    if let label = hold.label {
        parts.append(hold.kind == .forever ? label : "\(label) — \(lifetime)")
    } else {
        parts.append(lifetime)
    }

    let modifiers = modifierFacts(for: hold)
    if !modifiers.isEmpty { parts.append("(\(modifiers.joined(separator: ", ")))") }

    if includingID { parts.append("[\(hold.id)]") }
    return parts.joined(separator: " ")
}

/// The menu row for a hold: what it is and how it is set, as facts joined with middle
/// dots — `build · 42 min left · display on · lid ok`. The row opens the hold's
/// controls, so there is no id and no verb. A Claude session with no label is named
/// as such, because "until session exits" alone does not say whose.
public func menuTitle(for hold: HoldStatus) -> String {
    var facts: [String] = []
    let subject = hold.label ?? (hold.source == .claude ? "Claude session" : nil)
    if let subject { facts.append(subject) }
    switch hold.kind {
    case .forever:
        if subject == nil { facts.append("indefinitely") }
    case .process:
        facts.append(subject == nil ? "until session exits" : "until it exits")
    case .timer:
        facts.append(defaultLabel(for: hold))
    }
    facts += modifierFacts(for: hold)
    return facts.joined(separator: " · ")
}

/// The precise end of a hold, for the first row of its submenu: `until 3:12 PM`,
/// `until pid 6707 exits`, or `indefinitely`. The date joins the time once the end is
/// not today. `calendar` and `locale` are parameters so tests can pin them.
public func menuDetail(
    for hold: HoldStatus, now: Date, calendar: Calendar = .current, locale: Locale = .current
) -> String {
    switch hold.kind {
    case .forever:
        return "indefinitely"
    case .process:
        guard let pid = hold.watchedPID else { return "until the watched process exits" }
        return "until pid \(pid) exits"
    case .timer:
        guard let end = hold.expiresAt else { return "timed" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = calendar.isDate(end, inSameDayAs: now) ? .none : .medium
        return "until \(formatter.string(from: end))"
    }
}

/// The modifier facts both surfaces list, in one order.
private func modifierFacts(for hold: HoldStatus) -> [String] {
    var facts: [String] = []
    if hold.display { facts.append("display on") }
    if hold.acOnly { facts.append("only while plugged in") }
    if hold.lidClosed {
        facts.append("lid ok")
        if let floor = hold.batteryFloor { facts.append("off at \(floor)%") }
    }
    return facts
}

private func defaultLabel(for hold: HoldStatus) -> String {
    switch hold.kind {
    case .forever:
        return "indefinitely"
    case .timer:
        guard let remaining = hold.remainingSeconds else { return "timed" }
        return "\(remainingLabel(seconds: remaining)) left"
    case .process:
        return "until session exits"
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter OutputTests`
Expected: all pass, including the existing `describe` tests (their output is unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateCore/StatusRendering.swift Tests/TeainateCoreTests/OutputTests.swift
git commit -m "feat(core): menuTitle and menuDetail for hold rows"
```

---

### Task 7: Rewrite the menu model

**Files:**
- Modify: `Sources/TeainateCore/MenuModel.swift` (full rewrite)
- Modify: `Tests/TeainateCoreTests/MenuModelTests.swift` (full rewrite)

**Interfaces:**
- Consumes: `HoldModifier`, `NewHoldDefaults`, `menuTitle`, `menuDetail`, `SkillInstallState`, `batteryFloorChoices`, `describeEnded`, `pmsetUnavailableLine`
- Produces: the new `MenuAction` (below); `public func buildMenu(status: Status, defaults: NewHoldDefaults, skillState: SkillInstallState, now: Date = Date()) -> [MenuItem]`; `public func newHoldOptions(duration: TimeInterval?, defaults: NewHoldDefaults, lidEnabled: Bool) -> HoldOptions`; `statusIconIsActive` and `menuDurationChoices` unchanged. `MenuPreferences` is deleted.

The app will not compile between Step 3 and Task 8. That is expected; `swift test --filter TeainateCoreTests` builds only Core and its tests.

- [ ] **Step 1: Write the new test file**

Replace the whole of `Tests/TeainateCoreTests/MenuModelTests.swift` with:

```swift
import Testing
import Foundation
@testable import TeainateCore

private func status(
    holds: [HoldStatus] = [],
    foreign: [ForeignAssertion] = [],
    untracked: [UntrackedCaffeinate] = [],
    lid: LidClosedStatus = .unavailable,
    pmsetAvailable: Bool = true
) -> Status {
    Status(
        awake: !holds.isEmpty, holds: holds,
        foreignAssertions: foreign, untrackedCaffeinate: untracked, lidClosed: lid,
        pmsetAvailable: pmsetAvailable
    )
}

private func holdStatus(
    id: String = "h_1", kind: HoldKind = .forever, label: String? = nil, source: HoldSource = .menu,
    remaining: Int? = nil, expiresAt: Date? = nil, display: Bool = false, acOnly: Bool = false,
    lidClosed: Bool = false, floor: Int? = nil, watched: pid_t? = nil
) -> HoldStatus {
    HoldStatus(
        id: id, kind: kind, label: label, source: source,
        expiresAt: expiresAt, remainingSeconds: remaining, display: display, acOnly: acOnly,
        lidClosed: lidClosed, batteryFloor: floor, watchedPID: watched
    )
}

private let granted = LidClosedStatus(enabled: true, flagSet: false, flagSetBy: nil, batteryFloor: 15, lastEnded: nil, warnings: [])
private let notGranted = LidClosedStatus(enabled: false, flagSet: false, flagSetBy: nil, batteryFloor: 15, lastEnded: nil, warnings: [])

private func menu(
    _ status: Status = status(), defaults: NewHoldDefaults = .off, skill: SkillInstallState = .current
) -> [MenuItem] {
    buildMenu(status: status, defaults: defaults, skillState: skill, now: Date(timeIntervalSince1970: 1_000_000))
}

private func titles(_ items: [MenuItem]) -> [String] {
    items.filter { !$0.isSeparator }.map(\.title)
}

/// Every item at every depth, parents before children.
private func flatten(_ items: [MenuItem]) -> [MenuItem] {
    items.flatMap { [$0] + flatten($0.submenu) }
}

private func item(_ items: [MenuItem], action: MenuAction) -> MenuItem? {
    flatten(items).first { $0.action == action }
}

private func item(_ items: [MenuItem], titled title: String) -> MenuItem? {
    flatten(items).first { $0.title == title }
}

// MARK: Block order

@Test func blocksAppearInActionOrder() {
    let items = menu(status(holds: [holdStatus()], foreign: [ForeignAssertion(pid: 640, process: "Claude", type: "NoIdleSleepAssertion")]))
    let t = titles(items)
    let newHolds = t.firstIndex(of: "New holds")!
    let holding = t.firstIndex(of: "Holding")!
    let others = t.firstIndex(of: "Also keeping this Mac awake")!
    let settings = t.firstIndex(of: "Settings")!
    #expect(newHolds < holding && holding < others && others < settings)
    #expect(items.last?.action == .quit)
}

@Test func noStatusHeaderRow() {
    let t = titles(menu(status(holds: [holdStatus(kind: .timer, remaining: 2520)])))
    #expect(t.first == "New holds")
    #expect(!t.contains { $0.hasPrefix("●") || $0.hasPrefix("○") })
}

// MARK: Warnings

@Test func warningsLeadTheMenu() {
    let warned = LidClosedStatus(enabled: true, flagSet: true, flagSetBy: "teainate", batteryFloor: 15, lastEnded: nil,
                                 warnings: ["first warning", "second warning"])
    let t = titles(menu(status(lid: warned)))
    #expect(t[0] == "⚠ first warning")
    #expect(t[1] == "⚠ second warning")
    #expect(t[2] == "New holds")
}

@Test func lastEndedReasonLeadsTheMenu() {
    let ended = EndedHold(id: "h_x", label: "build", reason: "battery 14% at floor 15%", at: Date())
    let lid = LidClosedStatus(enabled: true, flagSet: false, flagSetBy: nil, batteryFloor: 15, lastEnded: ended, warnings: [])
    #expect(titles(menu(status(lid: lid))).first == "Last lid-closed hold (build) ended: battery 14% at floor 15%")
}

// MARK: New holds

@Test func newHoldCheckboxesReflectDefaults() {
    let items = menu(status(lid: granted), defaults: NewHoldDefaults(display: true, acOnly: false, lidClosed: true))
    // The action carries the value a click sets: the opposite of the current state.
    #expect(item(items, action: .setDefault(.display, false))?.isChecked == true)
    #expect(item(items, action: .setDefault(.acOnly, true))?.isChecked == false)
    #expect(item(items, action: .setDefault(.lidClosed, false))?.isChecked == true)
}

@Test func newHoldLidCheckboxIsGreyedAndUncheckedWithoutTheGrant() throws {
    let items = menu(status(lid: notGranted), defaults: NewHoldDefaults(lidClosed: true))
    let row = try #require(item(items, titled: "Allow closing the lid (enable in Settings)"))
    #expect(row.isEnabled == false)
    #expect(row.isChecked == false)
    #expect(row.action == .none)
    #expect(item(items, action: .setDefault(.lidClosed, false)) == nil)
}

@Test func durationsLiveInAKeepAwakeForSubmenu() throws {
    let items = menu()
    let row = try #require(item(items, titled: "Keep awake for"))
    #expect(row.isEnabled)
    #expect(row.submenu.map(\.action) == menuDurationChoices.map { .holdFor($0.seconds) } + [.holdForever])
    #expect(row.submenu.last?.title == "Indefinitely")
    #expect(!items.contains { $0.action == .holdForever })   // not at top level
}

@Test func newHoldOptionsApplyDefaultsButNeverLidWithoutTheGrant() {
    let defaults = NewHoldDefaults(display: true, acOnly: true, lidClosed: true)
    let granted = newHoldOptions(duration: 900, defaults: defaults, lidEnabled: true)
    #expect(granted.duration == 900 && granted.display && granted.acOnly && granted.lidClosed)
    #expect(granted.source == .menu)
    let revoked = newHoldOptions(duration: nil, defaults: defaults, lidEnabled: false)
    #expect(revoked.duration == nil && revoked.display && revoked.acOnly && !revoked.lidClosed)
}

// MARK: Holding

@Test func emptyHoldingBlockSaysSo() {
    let t = titles(menu())
    #expect(t.contains("Nothing is holding the Mac awake"))
    #expect(item(menu(), action: .releaseAll) == nil)
}

@Test func eachHoldIsARowWithItsOwnControls() throws {
    let hold = holdStatus(id: "h_a", kind: .timer, label: "build", remaining: 2520,
                          expiresAt: Date(timeIntervalSince1970: 1_002_520), display: true)
    let items = menu(status(holds: [hold], lid: granted))
    let row = try #require(item(items, titled: "build · 42 min left · display on"))
    #expect(row.indent == 1)
    let sub = row.submenu
    #expect(sub.first?.title.hasPrefix("until ") == true)
    #expect(sub.first?.isEnabled == false)
    #expect(sub.contains { $0.action == .setModifier(id: "h_a", .display, false) && $0.isChecked })
    #expect(sub.contains { $0.action == .setModifier(id: "h_a", .acOnly, true) && !$0.isChecked })
    #expect(sub.contains { $0.action == .setModifier(id: "h_a", .lidClosed, true) && !$0.isChecked })
    #expect(sub.last?.action == .release("h_a"))
    #expect(sub.last?.title == "Release")
}

@Test func holdCheckboxesReflectTheHoldNotTheDefaults() throws {
    let hold = holdStatus(id: "h_a", display: false, acOnly: true)
    let items = menu(status(holds: [hold], lid: granted), defaults: NewHoldDefaults(display: true, acOnly: false))
    let row = try #require(item(items, titled: menuTitle(for: hold)))
    #expect(row.submenu.first { $0.action == .setModifier(id: "h_a", .display, true) }?.isChecked == false)
    #expect(row.submenu.first { $0.action == .setModifier(id: "h_a", .acOnly, false) }?.isChecked == true)
}

@Test func lidHoldRowShowsTheFloorAndCanAlwaysBeTurnedOff() throws {
    let hold = holdStatus(id: "h_l", lidClosed: true, floor: 15)
    // Grant revoked after the hold was taken: turning lid-closed off needs no grant.
    let items = menu(status(holds: [hold], lid: notGranted))
    let row = try #require(item(items, titled: menuTitle(for: hold)))
    let lid = try #require(row.submenu.first { $0.action == .setModifier(id: "h_l", .lidClosed, false) })
    #expect(lid.isEnabled)
    #expect(lid.isChecked)
    #expect(lid.title == "Allow closing the lid (off at 15%)")
}

@Test func plainHoldLidRowIsGreyedWithoutTheGrant() throws {
    let hold = holdStatus(id: "h_p")
    let row = try #require(item(menu(status(holds: [hold], lid: notGranted)), titled: menuTitle(for: hold)))
    let lid = try #require(row.submenu.first { $0.title == "Allow closing the lid (enable in Settings)" })
    #expect(!lid.isEnabled)
    #expect(lid.action == .none)
}

@Test func detailRowNamesTheWatchedProcess() throws {
    let hold = holdStatus(id: "h_c", kind: .process, source: .claude, watched: 6707)
    let row = try #require(item(menu(status(holds: [hold])), titled: "Claude session · until it exits"))
    #expect(row.submenu.first?.title == "until pid 6707 exits")
}

@Test func releaseAllAppearsOnlyWithTwoOrMoreHolds() {
    #expect(item(menu(status(holds: [holdStatus(id: "h_a")])), action: .releaseAll) == nil)
    let two = menu(status(holds: [holdStatus(id: "h_a"), holdStatus(id: "h_b")]))
    #expect(item(two, action: .releaseAll) != nil)
    #expect(item(two, action: .release("h_a")) != nil)
    #expect(item(two, action: .release("h_b")) != nil)
}

// MARK: Also keeping this Mac awake

@Test func foreignAssertionsAppearWhenPresent() {
    let t = titles(menu(status(foreign: [ForeignAssertion(pid: 640, process: "Claude", type: "NoIdleSleepAssertion")])))
    #expect(t.contains("Also keeping this Mac awake"))
    #expect(t.contains("Claude (pid 640)"))
}

@Test func othersSectionOmittedWhenNothingToList() {
    let t = titles(menu())
    #expect(!t.contains("Also keeping this Mac awake"))
    #expect(item(menu(), action: .reclaimUntracked) == nil)
}

@Test func pmsetFailureIsShownInTheOthersSection() {
    let t = titles(menu(status(pmsetAvailable: false)))
    #expect(t.contains("Also keeping this Mac awake"))
    #expect(t.contains("Other sleep assertions: unavailable (pmset failed)"))
}

@Test func untrackedCaffeinateIsListedWithItsFlagsAndAReclaimAction() throws {
    let items = menu(status(untracked: [UntrackedCaffeinate(pid: 555, arguments: "caffeinate -i")]))
    #expect(titles(items).contains("Also keeping this Mac awake"))
    #expect(titles(items).contains("caffeinate -i (pid 555, not teainate's)"))
    let reclaim = try #require(item(items, action: .reclaimUntracked))
    #expect(reclaim.title == "Release untracked caffeinate…")
}

// MARK: Settings

@Test func settingsSubmenuOffersEnableWhenNotGranted() throws {
    let settings = try #require(item(menu(status(lid: notGranted)), titled: "Settings"))
    #expect(settings.submenu.contains { $0.action == .enableLidClosed && $0.title == "Enable lid-closed holds…" })
    #expect(!settings.submenu.contains { $0.action == .disableLidClosed })
    #expect(!settings.submenu.contains { $0.title.hasPrefix("Battery floor") })
}

@Test func settingsSubmenuOffersFloorAndDisableWhenGranted() throws {
    let settings = try #require(item(menu(status(lid: granted)), titled: "Settings"))
    #expect(settings.submenu.contains { $0.title == "Lid-closed holds enabled ✓" && !$0.isEnabled })
    let floor = try #require(settings.submenu.first { $0.title == "Battery floor: 15%" })
    #expect(floor.submenu.map(\.action) == batteryFloorChoices.map { .setBatteryFloor($0) })
    #expect(floor.submenu.first { $0.action == .setBatteryFloor(15) }?.isChecked == true)
    #expect(floor.submenu.first { $0.action == .setBatteryFloor(30) }?.isChecked == false)
    #expect(settings.submenu.first { $0.action == .disableLidClosed }?.isEnabled == true)
}

@Test func disableIsGreyedWhileALidHoldIsLive() throws {
    let settings = try #require(item(menu(status(holds: [holdStatus(lidClosed: true)], lid: granted)), titled: "Settings"))
    #expect(settings.submenu.first { $0.action == .disableLidClosed }?.isEnabled == false)
}

@Test func skillRowLivesInSettings() throws {
    let install = try #require(item(menu(skill: .notInstalled), titled: "Settings")).submenu.first { $0.action == .installSkill }
    #expect(install?.title == "Install Claude Code skill…")
    #expect(install?.isEnabled == true)

    let current = try #require(item(menu(skill: .current), titled: "Settings")).submenu.first { $0.title.contains("Claude Code skill") }
    #expect(current?.title == "Claude Code skill installed ✓")
    #expect(current?.isEnabled == false)

    let stale = try #require(item(menu(skill: .stale("gone")), titled: "Settings")).submenu.first { $0.action == .installSkill }
    #expect(stale?.title == "Update Claude Code skill")
    #expect(item(menu(skill: .notInstalled), action: .installSkill)?.title != nil)
    #expect(!menu(skill: .notInstalled).contains { $0.action == .installSkill })   // not at top level
}

// MARK: Invariants

// MenuRenderer relies solely on `isEnabled`, so this layer must never emit an enabled
// row that does nothing. Rows that open a submenu are the one exception: they have no
// action of their own but must stay enabled for the submenu to open.
@Test func actionlessItemsAreNeverEnabledAtAnyDepth() {
    let statuses = [
        status(),
        status(holds: [holdStatus(id: "h_a"), holdStatus(id: "h_b", kind: .timer, remaining: 90, expiresAt: Date())], lid: granted),
        status(holds: [holdStatus(id: "h_l", lidClosed: true, floor: 15)], lid: notGranted),
        status(foreign: [ForeignAssertion(pid: 640, process: "Claude", type: "NoIdleSleepAssertion")]),
        status(untracked: [UntrackedCaffeinate(pid: 555, arguments: "caffeinate -i")]),
        status(pmsetAvailable: false),
    ]
    let skillStates: [SkillInstallState] = [.notInstalled, .current, .stale("gone")]
    let defaults = [NewHoldDefaults.off, NewHoldDefaults(display: true, acOnly: true, lidClosed: true)]

    for status in statuses {
        for skillState in skillStates {
            for defaultSet in defaults {
                let items = buildMenu(status: status, defaults: defaultSet, skillState: skillState)
                for item in flatten(items) where item.action == .none && item.submenu.isEmpty {
                    #expect(!item.isEnabled, "'\(item.title)' has action .none but isEnabled == true")
                }
                for item in flatten(items) where !item.submenu.isEmpty {
                    #expect(item.isEnabled, "'\(item.title)' opens a submenu but is disabled")
                }
            }
        }
    }
}

@Test func quitIsAlwaysLast() {
    #expect(menu().last?.action == .quit)
    #expect(menu(status(holds: [holdStatus()], lid: granted)).last?.action == .quit)
}

@Test func iconIsActiveOnlyWhenHoldsExist() {
    #expect(statusIconIsActive(status()) == false)
    #expect(statusIconIsActive(status(holds: [holdStatus()])) == true)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MenuModelTests`
Expected: compile errors (`NewHoldDefaults` parameter, `setDefault`, `setModifier`, `newHoldOptions` missing).

- [ ] **Step 3: Rewrite `MenuModel.swift`**

Replace the whole file with:

```swift
import Foundation

public enum MenuAction: Sendable, Equatable {
    case holdFor(TimeInterval)
    case holdForever
    /// Set a new-hold default. The value is what the click sets, not a toggle.
    case setDefault(HoldModifier, Bool)
    /// Change a live hold. The value is what the click sets.
    case setModifier(id: String, HoldModifier, Bool)
    case release(String)
    case releaseAll
    case reclaimUntracked
    case installSkill
    case enableLidClosed
    case disableLidClosed
    case setBatteryFloor(Int)
    case quit
    case none
}

public struct MenuItem: Sendable, Equatable {
    public let title: String
    public let action: MenuAction
    public let isEnabled: Bool
    public let isChecked: Bool
    public let isSeparator: Bool
    public let indent: Int
    public let submenu: [MenuItem]

    public init(
        title: String, action: MenuAction = .none, isEnabled: Bool = true,
        isChecked: Bool = false, isSeparator: Bool = false, indent: Int = 0,
        submenu: [MenuItem] = []
    ) {
        self.title = title
        self.action = action
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.isSeparator = isSeparator
        self.indent = indent
        self.submenu = submenu
    }

    public static let separator = MenuItem(title: "", isEnabled: false, isSeparator: true)
}

public let menuDurationChoices: [(label: String, seconds: TimeInterval)] = [
    ("15 minutes", 900), ("30 minutes", 1800),
    ("1 hour", 3600), ("2 hours", 7200), ("4 hours", 14400),
]

public func statusIconIsActive(_ status: Status) -> Bool {
    !status.holds.isEmpty
}

/// The options a "Keep awake for" click produces. A lid-closed default is ignored
/// while the grant is absent — the checkbox is greyed, and a refused hold on every
/// click would be a worse surprise than a hold without the lid.
public func newHoldOptions(duration: TimeInterval?, defaults: NewHoldDefaults, lidEnabled: Bool) -> HoldOptions {
    HoldOptions(
        duration: duration, acOnly: defaults.acOnly, display: defaults.display,
        lidClosed: defaults.lidClosed && lidEnabled, source: .menu
    )
}

/// Five blocks, in the order you act on them: warnings, new holds, what is holding,
/// what else is holding, settings. Every show/enable/check decision is here.
public func buildMenu(
    status: Status,
    defaults: NewHoldDefaults,
    skillState: SkillInstallState,
    now: Date = Date()
) -> [MenuItem] {
    var items: [MenuItem] = []
    let lidEnabled = status.lidClosed.enabled

    // Warnings first: what you most need to know and least expect.
    var notices = status.lidClosed.warnings.map { MenuItem(title: "⚠ \($0)", isEnabled: false) }
    if let ended = status.lidClosed.lastEnded {
        notices.append(MenuItem(title: describeEnded(ended), isEnabled: false))
    }
    if !notices.isEmpty {
        items += notices
        items.append(.separator)
    }

    // New holds: the defaults above the durations, so reading order is action order.
    items.append(MenuItem(title: "New holds", isEnabled: false))
    items += modifierRows(
        display: defaults.display, acOnly: defaults.acOnly,
        lidChecked: defaults.lidClosed && lidEnabled, lidEnabled: lidEnabled, floor: nil, indent: 1
    ) { modifier, value in .setDefault(modifier, value) }
    let durations = menuDurationChoices.map { MenuItem(title: $0.label, action: .holdFor($0.seconds)) }
        + [MenuItem(title: "Indefinitely", action: .holdForever)]
    items.append(MenuItem(title: "Keep awake for", indent: 1, submenu: durations))
    items.append(.separator)

    // Holding: one row per hold, each opening its own live controls.
    items.append(MenuItem(title: "Holding", isEnabled: false))
    if status.holds.isEmpty {
        items.append(MenuItem(title: "Nothing is holding the Mac awake", isEnabled: false, indent: 1))
    }
    for hold in status.holds {
        items.append(MenuItem(
            title: menuTitle(for: hold), indent: 1,
            submenu: holdControls(hold, lidEnabled: lidEnabled, now: now)
        ))
    }
    // Only when it would not duplicate the single Release above it.
    if status.holds.count > 1 {
        items.append(MenuItem(title: "Release all", action: .releaseAll, indent: 1))
    }

    let others = otherHolders(status)
    if !others.isEmpty {
        items.append(.separator)
        items += others
    }

    items.append(.separator)
    items.append(MenuItem(title: "Settings", submenu: lidClosedItems(status) + [.separator, skillItem(skillState)]))
    items.append(MenuItem(title: "Quit teainate", action: .quit))
    return items
}

/// The three modifier checkboxes, for the defaults block and for each hold. Each
/// action carries the value a click sets. Turning lid-closed *off* never needs the
/// grant, so a lid-closed hold's row stays enabled even after the grant is revoked.
private func modifierRows(
    display: Bool, acOnly: Bool, lidChecked: Bool, lidEnabled: Bool, floor: Int?, indent: Int,
    action: (HoldModifier, Bool) -> MenuAction
) -> [MenuItem] {
    let lidUsable = lidEnabled || lidChecked
    var lidTitle = "Allow closing the lid"
    if !lidUsable {
        lidTitle += " (enable in Settings)"
    } else if lidChecked, let floor {
        lidTitle += " (off at \(floor)%)"
    }
    return [
        MenuItem(title: "Keep display on", action: action(.display, !display), isChecked: display, indent: indent),
        MenuItem(title: "Only while plugged in", action: action(.acOnly, !acOnly), isChecked: acOnly, indent: indent),
        MenuItem(
            title: lidTitle, action: lidUsable ? action(.lidClosed, !lidChecked) : .none,
            isEnabled: lidUsable, isChecked: lidChecked, indent: indent
        ),
    ]
}

private func holdControls(_ hold: HoldStatus, lidEnabled: Bool, now: Date) -> [MenuItem] {
    [MenuItem(title: menuDetail(for: hold, now: now), isEnabled: false), .separator]
        + modifierRows(
            display: hold.display, acOnly: hold.acOnly, lidChecked: hold.lidClosed,
            lidEnabled: lidEnabled, floor: hold.batteryFloor, indent: 0
        ) { modifier, value in .setModifier(id: hold.id, modifier, value) }
        + [.separator, MenuItem(title: "Release", action: .release(hold.id))]
}

/// Foreign assertions (read-only) and untracked caffeinate (releasable on request),
/// in one section. Empty when there is nothing to list.
private func otherHolders(_ status: Status) -> [MenuItem] {
    var rows: [MenuItem] = []
    if !status.pmsetAvailable {
        rows.append(MenuItem(title: pmsetUnavailableLine, isEnabled: false, indent: 1))
    } else {
        rows += status.foreignAssertions.map {
            MenuItem(title: "\($0.process) (pid \($0.pid))", isEnabled: false, indent: 1)
        }
    }
    // Actionable, unlike foreign assertions: we can terminate these on request.
    rows += status.untrackedCaffeinate.map {
        MenuItem(title: "\($0.arguments) (pid \($0.pid), not teainate's)", isEnabled: false, indent: 1)
    }
    if !status.untrackedCaffeinate.isEmpty {
        rows.append(MenuItem(title: "Release untracked caffeinate…", action: .reclaimUntracked, indent: 1))
    }
    guard !rows.isEmpty else { return [] }
    return [MenuItem(title: "Also keeping this Mac awake", isEnabled: false)] + rows
}

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

private func skillItem(_ state: SkillInstallState) -> MenuItem {
    switch state {
    case .notInstalled:
        return MenuItem(title: "Install Claude Code skill…", action: .installSkill)
    case .stale:
        return MenuItem(title: "Update Claude Code skill", action: .installSkill)
    case .current:
        return MenuItem(title: "Claude Code skill installed ✓", action: .none, isEnabled: false)
    }
}
```

- [ ] **Step 4: Run the Core tests to verify they pass**

Run: `swift test --filter TeainateCoreTests`
Expected: all pass. (`swift build` of the whole package fails until Task 8 because the app still references `MenuPreferences`; that is expected here.)

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateCore/MenuModel.swift Tests/TeainateCoreTests/MenuModelTests.swift
git commit -m "feat(core): five-block menu with per-hold live controls and persistent defaults"
```

---

### Task 8: App wiring and the template icon

**Files:**
- Modify: `Sources/TeainateApp/AppDelegate.swift`

**Interfaces:**
- Consumes: `buildMenu(status:defaults:skillState:)`, `newHoldOptions`, `NewHoldDefaults`, `Settings.newHoldDefaults`, `TeainateService.modify`, `MenuAction.setDefault` / `.setModifier`

No unit tests: the app is a thin client and Core is not allowed to import AppKit. Verification is a build plus a hand check.

- [ ] **Step 1: Replace preferences with settings-backed defaults**

In `AppDelegate`, delete `private var preferences = MenuPreferences()` and add:

```swift
    private var settingsStore: SettingsStore { SettingsStore(fileURL: paths.settingsFile) }
```

Replace `refresh()` with:

```swift
    private func refresh() {
        let status = (try? service.status())
            ?? Status(awake: false, holds: [], foreignAssertions: [], untrackedCaffeinate: [])
        let skillState = SkillInstaller(paths: paths, cliPath: cliPath).state()
        let defaults = settingsStore.read().settings.newHoldDefaults

        updateIcon(active: statusIconIsActive(status), status: status)
        statusItem.menu = renderer.render(
            buildMenu(status: status, defaults: defaults, skillState: skillState)
        )

        if let ended = status.lidClosed.lastEnded, ended.at != lastReportedEnded {
            lastReportedEnded = ended.at
            let name = ended.label.map { " (\($0))" } ?? ""
            present(error: "Lid-closed hold\(name) ended early.", detail: ended.reason)
        }
    }

    /// A template cup follows the menu bar's own colour, dark mode, and inactive
    /// dimming. Empty when idle, filled when holding — the convention Caffeine and
    /// KeepingYouAwake users already carry. Falls back to text if the symbol is missing.
    private func updateIcon(active: Bool, status: Status) {
        guard let button = statusItem.button else { return }
        let symbol = active ? "cup.and.saucer.fill" : "cup.and.saucer"
        let label = active ? "Teainate, holding the Mac awake" : "Teainate, idle"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = active ? "☕️" : "🍵"
        }
        button.toolTip = renderStatus(status)
    }
```

- [ ] **Step 2: Rewire `handle` and `start`**

Replace the `handle(_:)` switch's changed cases. The full switch becomes:

```swift
    private func handle(_ action: MenuAction) {
        switch action {
        case .holdFor(let seconds):
            start(duration: seconds)
        case .holdForever:
            start(duration: nil)
        case .setDefault(let modifier, let value):
            updateSettings(failure: "Could not save the new-hold defaults.") { $0.newHoldDefaults[modifier] = value }
        case .setModifier(let id, let modifier, let value):
            do { _ = try service.modify(id: id, changing: modifier, to: value) }
            catch { present(error: "Could not change the hold.", detail: "\(error)") }
        case .release(let id):
            do { _ = try service.off(id: id) }
            catch { present(error: "Could not release the hold.", detail: "\(error)") }
        case .releaseAll:
            do { _ = try service.off(id: nil) }
            catch { present(error: "Could not release the holds.", detail: "\(error)") }
        case .reclaimUntracked:
            reclaimUntracked()
        case .installSkill:
            installSkill()
        case .quit:
            NSApp.terminate(nil)
        case .enableLidClosed:
            runAsAdmin(script: { try grant.installScript() }, failure: "Could not enable lid-closed holds.")
        case .disableLidClosed:
            runAsAdmin(script: { try grant.removeScript() }, failure: "Could not disable lid-closed holds.")
        case .setBatteryFloor(let floor):
            updateSettings(failure: "Could not save the battery floor.") { $0.batteryFloor = floor }
        case .none:
            break
        }
        refresh()
    }

    /// Read-modify-write of settings.json, so changing one field keeps the others.
    private func updateSettings(failure: String, _ change: (inout Settings) -> Void) {
        var settings = settingsStore.read().settings
        change(&settings)
        do { try settingsStore.write(settings) }
        catch { present(error: failure, detail: "\(error)") }
    }

    private func start(duration: TimeInterval?) {
        let defaults = settingsStore.read().settings.newHoldDefaults
        let lidEnabled = (try? service.status())?.lidClosed.enabled ?? false
        do {
            _ = try service.on(newHoldOptions(duration: duration, defaults: defaults, lidEnabled: lidEnabled))
        } catch {
            present(error: "Could not start the hold.", detail: "\(error)")
        }
    }
```

Remove the old `.toggleACOnly`, `.toggleDisplay`, `.toggleLidClosed` cases and the old `start(duration:)`.

- [ ] **Step 3: Build everything**

Run: `swift build && swift test --filter TeainateCoreTests`
Expected: the whole package builds (app included); Core tests pass.

- [ ] **Step 4: Hand-verify the app**

Run: `./scripts/make-app.sh debug && open Teainate.app` (or the path the script prints). Confirm:

1. The menu bar shows an empty template cup that matches neighbouring icons in both light and dark appearance.
2. "New holds" checkboxes tick and stay ticked after quitting and relaunching the app.
3. "Keep awake for → 15 minutes" fills the cup; the hold row reads like `15 min left`; its submenu's first row reads `until <time>`.
4. Ticking "Keep display on" in the hold's submenu changes the row to `… · display on`, and `pmset -g assertions` now lists a `PreventUserIdleDisplaySleep` for the new pid.
5. Release empties the cup.

Do **not** exercise the lid-closed transitions by hand unless the grant is installed on this Mac and no other session depends on a lid-closed hold.

- [ ] **Step 5: Commit**

```bash
git add Sources/TeainateApp/AppDelegate.swift
git commit -m "feat(app): settings-backed defaults, per-hold modify, template cup icon"
```

---

### Task 9: Real-process tests for `modify`

**Files:**
- Modify: `Tests/TeainateIntegrationTests/RealCaffeinateTests.swift`
- Modify: `Tests/TeainateIntegrationTests/RealLidWatchTests.swift`

**Interfaces:**
- Consumes: `TeainateService.modify`, `LidClosedDependencies`, `WatcherSpawning`, `SystemWatcherSpawner`, `lidWatchArguments`, `watcherProcessName`

Every spawned process here has a `-t 20` backstop through the hold's `duration`, and every test releases through `service.off(id: nil)` in `defer`, which only touches holds this test's own state file recorded.

- [ ] **Step 1: Add the real plain `modify` test**

Append to `RealCaffeinateTests.swift`:

```swift
// Real spawner and real ps together, like reconcile in production: the replacement is
// recognised and the original is gone. Fakes hardcode `command: "caffeinate"` and
// could not see a flags or naming regression here.
@Test func realModifyReplacesTheProcessAndSurvivesReconciliation() throws {
    let (service, _) = realService()
    let original = try service.on(HoldOptions(duration: 20, source: .menu))
    defer { _ = try? service.off(id: nil) }

    let replacement = try service.modify(id: original.id, changing: .display, to: true)

    #expect(replacement.flags.starts(with: ["-i", "-d", "-t"]))
    #expect(replacement.replaces == original.id)

    var attempts = 0
    while attempts < 50, try PSProcessSnapshotter().snapshot()[original.caffeinatePID] != nil {
        usleep(100_000); attempts += 1
    }
    let table = try PSProcessSnapshotter().snapshot()
    #expect(table[original.caffeinatePID] == nil)
    #expect(table[replacement.caffeinatePID]?.command == "caffeinate")
    #expect(try service.status().holds.map(\.id) == [replacement.id])
    #expect(try PMSetAssertionReader().assertions().contains { $0.pid == replacement.caffeinatePID })
}
```

- [ ] **Step 2: Add the no-flag spawner and fakes to `RealLidWatchTests.swift`**

Below `tempState()`, add:

```swift
/// Forwards to the real spawner with `--no-flag` appended: a real watcher binary that
/// never touches the kernel sleep flag. The service itself never passes this hook.
private struct NoFlagWatcherSpawner: WatcherSpawning {
    func spawnWatcher(executable: URL, arguments: [String]) throws -> pid_t {
        try SystemWatcherSpawner().spawnWatcher(executable: executable, arguments: arguments + ["--no-flag"])
    }
}

private final class FakeFlag: SleepFlagControlling, @unchecked Sendable {
    var value = false
    var clearCount = 0
    func set() throws { value = true }
    func clear() throws { clearCount += 1; value = false }
    func isSet() throws -> Bool { value }
}

private struct AlwaysGranted: PrivilegeGranting {
    func isGranted() -> Bool { true }
}

private struct OnACPower: BatteryReading {
    func read() throws -> BatteryState? { BatteryState(source: .ac, percent: 90) }
}

/// Real service, real caffeinate, real watcher binary, real ps; faked flag, grant, and
/// battery. The only shape of test that proves a lid transition composes correctly.
private func realLidService() throws -> (service: TeainateService, flag: FakeFlag, state: URL) {
    let state = tempState()
    let snapshotter = PSProcessSnapshotter()
    let flag = FakeFlag()
    let service = TeainateService(
        store: HoldStore(fileURL: state, snapshotter: snapshotter),
        spawner: SystemCaffeinateSpawner(),
        assertionReader: PMSetAssertionReader(),
        snapshotter: snapshotter,
        lidClosed: LidClosedDependencies(
            flag: flag, grant: AlwaysGranted(), battery: OnACPower(),
            settings: SettingsStore(fileURL: state.deletingLastPathComponent().appendingPathComponent("settings.json")),
            watcherSpawner: NoFlagWatcherSpawner(),
            watcherExecutable: try cliBinary(), stateFile: state)
    )
    return (service, flag, state)
}

private func storeState(_ state: URL) throws -> StoreState {
    try HoldStore(fileURL: state, snapshotter: PSProcessSnapshotter()).readState()
}
```

- [ ] **Step 3: Add the three transition tests**

Append to `RealLidWatchTests.swift`:

```swift
// off→on through the real service: a real watcher replaces a real caffeinate.
@Test func realModifyToLidClosedSpawnsAWatcherAndReleasesTheCaffeinate() throws {
    let (service, flag, state) = try realLidService()
    let plain = try service.on(HoldOptions(duration: 20, source: .menu))
    defer { _ = try? service.off(id: nil) }

    let lid = try service.modify(id: plain.id, changing: .lidClosed, to: true)

    #expect(lid.lidClosed)
    #expect(lid.replaces == plain.id)
    #expect(flag.value)
    try waitUntilGone(plain.caffeinatePID)
    let table = try PSProcessSnapshotter().snapshot()
    #expect(table[plain.caffeinatePID] == nil)
    #expect(table[lid.caffeinatePID]?.command == watcherProcessName)
    #expect(try service.status().holds.map(\.id) == [lid.id])
    #expect(try storeState(state).lidFlagOwned)
}

// on→off: the watcher ran with --no-flag, so it cleared nothing on exit. The service's
// own orphan cleanup, run at the end of `off`, is what clears the fake flag.
@Test func realModifyFromLidClosedReleasesTheWatcherAndClearsTheFlag() throws {
    let (service, flag, state) = try realLidService()
    let lid = try service.on(HoldOptions(duration: 20, lidClosed: true, source: .menu))
    defer { _ = try? service.off(id: nil) }
    #expect(flag.value)

    let plain = try service.modify(id: lid.id, changing: .lidClosed, to: false)

    #expect(!plain.lidClosed)
    try waitUntilGone(lid.caffeinatePID)
    let table = try PSProcessSnapshotter().snapshot()
    #expect(table[lid.caffeinatePID] == nil)
    #expect(table[plain.caffeinatePID]?.command == "caffeinate")
    #expect(flag.value == false)
    #expect(flag.clearCount == 1)
    #expect(try storeState(state).lidFlagOwned == false)
    #expect(try service.status().holds.map(\.id) == [plain.id])
}

// on→on: two real watchers overlap, then only the new one remains; the flag is never cleared.
@Test func realModifyOnALidHoldSwapsWatchersWithoutClearingTheFlag() throws {
    let (service, flag, state) = try realLidService()
    let first = try service.on(HoldOptions(duration: 20, lidClosed: true, source: .menu))
    defer { _ = try? service.off(id: nil) }

    let second = try service.modify(id: first.id, changing: .display, to: true)

    #expect(second.lidClosed && second.display)
    try waitUntilGone(first.caffeinatePID)
    let table = try PSProcessSnapshotter().snapshot()
    #expect(table[first.caffeinatePID] == nil)
    #expect(table[second.caffeinatePID]?.command == watcherProcessName)
    #expect(flag.value)
    #expect(flag.clearCount == 0)
    #expect(try storeState(state).lidFlagOwned)
    #expect(try service.status().holds.map(\.id) == [second.id])
}
```

- [ ] **Step 4: Run the full suite**

Run: `swift build && swift test`
Expected: all pass. While it runs, `pmset -g assertions` may briefly list this test's caffeinate pids; they self-terminate within 20 seconds regardless.

If `realModifyFromLidClosedReleasesTheWatcherAndClearsTheFlag` reports `clearCount == 2`, the outgoing watcher is clearing too, which means the `--no-flag` argument did not reach it: check `NoFlagWatcherSpawner` appends after `lidWatchArguments`' own arguments.

- [ ] **Step 5: Commit**

```bash
git add Tests/TeainateIntegrationTests/RealCaffeinateTests.swift Tests/TeainateIntegrationTests/RealLidWatchTests.swift
git commit -m "test(integration): modify with real caffeinate and real lid-watch transitions"
```

---

### Task 10: Docs, followups, and version

**Files:**
- Modify: `docs/followups.md`
- Modify: `docs/superpowers/specs/2026-09-05-menu-redesign-design.md`
- Modify: `CLAUDE.md`
- Modify: `Sources/TeainateCore/Version.swift`, `Resources/Info.plist`

- [ ] **Step 1: Close the watched-pid followup**

In `docs/followups.md`, delete the bullet beginning `- **A process-kind hold cannot say which process it is watching.**`.

- [ ] **Step 2: Correct the spec's on→off wording**

In the spec's "Real processes, lid transitions" section, replace the on→off bullet with:

```
- on→off: the record becomes a plain caffeinate hold and the old watcher exits.
  With `--no-flag` the watcher never touches any flag, so the marker is left owned
  with no lid-closed hold live; the service's own orphan cleanup, run at the end of
  `off`, then clears the fake flag (`clear()` called once, marker dropped).
```

- [ ] **Step 3: Record the new traps in `CLAUDE.md`**

Under "## Architecture", after the "Spawn before recording" bullet, add:

```markdown
- **`modify` is `on` then `off`, never a swap in place.** The replacement is spawned
  and recorded before the original is signalled, so the Mac is never unheld. A
  replacement never reuses an id: a lid-closed watcher removes its record *by id* on
  exit, and would take a same-id successor with it. Lineage lives in `replaces`, and
  `off(id:)` matches it, so the id `on` printed keeps working after menu edits.
```

Under "## Conventions", add:

```markdown
- Menu checkboxes mean what checkboxes mean: a hold row's boxes are that hold's live
  flags, and the "New holds" boxes are persisted defaults. Never add a checkbox whose
  state only applies to something that has not happened yet.
```

- [ ] **Step 4: Bump the version**

Set `TeainateVersion.current` to `"0.3.0"` in `Sources/TeainateCore/Version.swift`, and `CFBundleShortVersionString` to `0.3.0` in `Resources/Info.plist`. `VersionTests.bundleVersionMatchesSwiftVersion` goes red if only one changes.

- [ ] **Step 5: Run the full suite and build the app**

Run: `swift build && swift test && ./scripts/make-app.sh debug`
Expected: all pass; the app assembles.

- [ ] **Step 6: Commit**

```bash
git add docs/followups.md docs/superpowers/specs/2026-09-05-menu-redesign-design.md CLAUDE.md Sources/TeainateCore/Version.swift Resources/Info.plist
git commit -m "docs: menu redesign traps and conventions; close watched-pid followup; bump to 0.3.0"
```
