# teainate — menu redesign

**Date:** 2026-09-05
**Status:** Approved

## Purpose

Rework the menu bar UI so that what it shows is what is true, and what you act on
is what changes. The redesign is guided by Don Norman's *The Design of Everyday
Things*: signifiers that mean what they look like, layout that follows the order of
action, feedback for every act, and one-time setup kept apart from daily controls.

Three answers shaped it:

- Holds are mostly created **by hand, from the menu**. The menu is the primary
  creator, not a dashboard over Claude's holds.
- The thing that actually happens mid-hold is **wanting to change a modifier**
  (display on, plugged-in only, lid closed) after the hold has started.
- Every hold is an **equal**: whoever started it, it gets the same row and the same
  controls. Lid-closed is a **regular modifier**, not a special mode.

## Problems with the current menu

- **The modifier checkboxes are a hidden mode.** A checked box in a menu reads as
  "this is the current state". Today it only shapes the *next* hold and never
  touches a running one. Ticking "Keep display on" during a hold changes nothing.
- **Reading order contradicts action order.** Durations sit above the modifiers you
  must set first.
- **Setup is mixed with use.** The skill installer and the lid-closed grant live
  permanently beside daily controls; once installed the skill row is dead forever.
- **Lid-closed lives in two places.** A greyed row up top points at a setup block at
  the bottom.
- **The icon is an emoji**, not a template image, so it ignores dark mode, wallpaper
  tinting, and inactive dimming, and its teacup-versus-coffee-cup swap is a weaker
  signal than the empty-cup/full-cup convention users of Caffeine and
  KeepingYouAwake already hold.
- **Preferences reset on relaunch.** One more hidden mode.

## Non-goals

- No "add time" / extend. Cheap once the hold submenu exists, but not asked for.
- No countdown text beside the menu bar icon.
- No popover or custom views; the menu stays a native `NSMenu`.
- No CLI `modify` command. The skill's contract remains on, off, status, and an id
  printed by `on` keeps releasing that hold after any menu edit.
- No per-process release of untracked caffeinate; the service is all-or-nothing there.
- The ended-early modal alert stays a modal. Converting it to a notification is
  already its own followup.
- No distinct icon while a lid-closed hold is live.

## 1. Menu model

All decisions live in `MenuModel.swift` and are unit-tested. `MenuRenderer` needs
nothing new: submenus, indentation, and check marks already exist.

Five blocks, top to bottom, in the order you act on them:

```
⚠ <lid-closed warnings, if any>
Last lid-closed hold ended: <reason>          (if any)
──────────────────────────────
New holds
  ☐ Keep display on
  ☐ Only while plugged in
  ☑ Allow closing the lid
  Keep awake for              ▸  15 min · 30 min · 1 h · 2 h · 4 h · Indefinitely
──────────────────────────────
Holding
  build · 42 min left · lid ok ▸  until 3:12 pm
  Claude session · until it exits ▸ ─────────────────────
  Release all                    ☐ Keep display on
──────────────────────────────   ☐ Only while plugged in
Also keeping this Mac awake      ☑ Allow closing the lid (off at 15%)
  Terminal (pid 1234)            ─────────────────────
  caffeinate -i -t 300 (pid 5)   Release
  Release untracked caffeinate…
──────────────────────────────
Settings                      ▸  Lid-closed holds: Enabled ✓ / Disable…
Quit                             Battery floor ▸ 5 … 50 %
                                 Claude Code skill: Installed ✓ / Install… / Update
```

**Warnings.** Lid-closed warnings and the last-ended line stay first. Omitted, with
their separator, when there is nothing to say.

**New holds.** A disabled label row, then three checkboxes whose state is the
persisted `NewHoldDefaults` (see §3). The lid checkbox is disabled and titled
"Allow closing the lid (enable in Settings)" until the grant exists. Below them one
"Keep awake for" row whose submenu holds the five `menuDurationChoices` plus
"Indefinitely". Choosing one creates a hold with the defaults as its modifiers.

**Holding.** A disabled label row, then one row per hold. When there are none, a
single disabled row "Nothing is holding the Mac awake". Each hold row's title is
built by a new `menuTitle(for:)` in `StatusRendering.swift`: label if present, then
the lifetime, then the modifiers, joined with " · ". Examples:

- `42 min left`
- `build · 42 min left · display on · lid ok`
- `Claude session · until it exits` (source `.claude`, kind `.process`)
- `indefinitely · only while plugged in`

`describe(_:includingID:)` is unchanged; the CLI keeps its wording.

Each hold row's submenu:

1. A disabled detail row stating the end precisely: `until 3:12 pm` (timer, local
   time, date added when not today), `until pid 6707 exits` (process), or
   `indefinitely`. This surfaces `watched_pid`, closing that followup.
2. Separator.
3. Three checkboxes reflecting **this hold's live flags**: Keep display on, Only
   while plugged in, Allow closing the lid. The lid row shows "(off at N%)" when
   checked, and is disabled with "(enable in Settings)" when the grant is absent.
4. Separator.
5. Release.

"Release all" appears after the hold rows only when there are two or more holds, so
it is never a duplicate of the single Release above it.

**Also keeping this Mac awake.** One section for foreign assertions (disabled rows,
as today) and untracked caffeinate (disabled rows plus the single "Release
untracked caffeinate…" action with its confirming dialog). When `pmset` failed, the
`pmsetUnavailableLine` row replaces the foreign entries as today. Omitted entirely
when there is nothing to list.

**Settings.** One submenu: the lid-closed enable/disable and battery floor rows
exactly as `lidClosedItems` builds them today, then the skill row from `skillItem`.
Quit stays last at top level.

The "● Awake — …" / "○ Off" header row is removed; the icon and the hold rows carry
the same information.

### `MenuAction` changes

```swift
public enum HoldModifier: Sendable, Equatable { case display, acOnly, lidClosed }

case setDefault(HoldModifier, Bool)            // replaces toggleACOnly/toggleDisplay/toggleLidClosed
case setModifier(id: String, HoldModifier, Bool)
```

`holdFor`, `holdForever`, `release`, `releaseAll`, `reclaimUntracked`,
`installSkill`, `enableLidClosed`, `disableLidClosed`, `setBatteryFloor`, `quit`,
`none` are unchanged. `MenuPreferences` is deleted; `buildMenu` takes
`NewHoldDefaults` in its place.

## 2. Modify in the service

A watcher exiting removes its own record **by id**. A replacement that kept the old
id would have its record deleted by the outgoing watcher moments after the swap.
The replacement therefore gets a **fresh id** and records its **lineage**: a new
optional `replaces` field on `Hold` (JSON `replaces`) holding the id of the *first*
hold in the chain. A replacement of a replacement carries the same original id
forward, so any generation answers to the id the creator was given.

`off(id:)` releases a hold when `id` matches either `hold.id` or `hold.replaces`.
That keeps the skill's documented workflow (`on` prints an id, `off --id` releases
it) working after any number of menu edits. `status --json` includes `replaces` when
present; the human `status` and the menu do not show it.

**Pure function** in `Hold.swift`:

```swift
public func replacementOptions(for hold: Hold, changing modifier: HoldModifier,
                               to value: Bool, now: Date) -> HoldOptions?
```

Same kind, label, source, and watched pid. For a timer, `duration` is the seconds
remaining to `expiresAt` (so the end time stays put); returns nil when under one
second remains. The three modifier flags come from the hold with one flipped.
`HoldOptions` gains an optional `replaces: String?`, set here to
`hold.replaces ?? hold.id`; `on` copies it onto the record.

**Service:**

```swift
public func modify(id: String, changing: HoldModifier, to: Bool) throws -> Hold
```

1. Read state (this reconciles). Resolve `id` against `hold.id` or `hold.replaces`.
   Throw new `ServiceError.holdNotFound(id)` when no hold matches or
   `replacementOptions` returns nil.
2. `let replacement = try on(options)` — every lid-closed pre-flight, undo path, and
   battery check is reused untouched. If this throws, nothing has changed and the
   original hold is still live.
3. `_ = try off(id: original.id)` — terminate the original by its *own* id. `off`
   matches lineage too, so this must pass the resolved hold's current id, not the
   caller's; otherwise the replacement, which shares the lineage, would be released
   as well. `off` therefore takes a second internal parameter, `exact: Bool`, that
   the CLI and menu never set.
4. Return the replacement.

`on` before `off` means the Mac is never unheld. Lid transitions fall out of the
order: off→on sets the flag while the old caffeinate is alive, then the old one is
terminated; on→off starts the new caffeinate, then signals the old watcher, whose
exit code already clears the flag only when no other lid-closed hold is live; on→on
overlaps two watchers briefly and the marker stays owned throughout.

The two-hold window is milliseconds long and visible only to a concurrent
`status`, which reports two live holds, both true. If `off` fails after `on`
succeeded (only a lock timeout can cause this) both remain and the next refresh
shows both rows.

A lid-closed replacement takes the battery floor currently in settings, not the
floor the original was taken with. It is a new hold, and its menu row shows its
floor.

`ServiceError.holdNotFound` gets a sentence: "No hold with id 'h_…'. It may have
already ended."

## 3. Persistent new-hold defaults

`Settings` gains:

```swift
public struct NewHoldDefaults: Codable, Sendable, Equatable {
    public var display: Bool      // "display"
    public var acOnly: Bool       // "ac_only"
    public var lidClosed: Bool    // "lid_closed"
}
public var newHoldDefaults: NewHoldDefaults   // "new_hold_defaults"
```

Decoding is tolerant: an existing `settings.json` without the key yields all-off.
A corrupt file falls back to `.default` with the existing warning. The app writes
the whole `Settings` on every change through `SettingsStore.write`, preserving the
battery floor. `TeainateService.status()` is unchanged; the app reads defaults via
`SettingsStore.read()` on each refresh.

A lid-closed default that is set while the grant is later revoked is harmless: the
lid checkbox is greyed and unchecked, and `newHoldOptions` drops the lid from the
new hold rather than letting `on` refuse it, so every "Keep awake for" click still
produces a hold. The default itself stays stored and reappears when the grant is
restored.

## 4. Icon and visual language

- `statusItem.button?.image` is `NSImage(systemSymbolName: "cup.and.saucer.fill", …)`
  when any hold is live and `"cup.and.saucer"` when idle, with `isTemplate = true`.
  The button title is cleared. If the symbol is unavailable the current text titles
  remain as the fallback.
- `accessibilityDescription` is "Teainate, holding the Mac awake" or "Teainate,
  idle".
- The tooltip remains `renderStatus(status)`.
- `statusIconIsActive` stays the single decision point for the icon state.
- Menu text: middle dots between facts in hold titles, sentence case, ellipses only
  on rows that open a dialog. No "●" / "○" in menu titles.
- Errors from refused clicks stay `NSAlert`s carrying the Core error sentence.

## 5. App wiring

`AppDelegate.handle`:

- `.setDefault(m, v)` — read settings, set the field, write, refresh.
- `.setModifier(id, m, v)` — `service.modify(...)`; on error present
  "Could not change the hold." with the error sentence.
- `.holdFor` / `.holdForever` — build `HoldOptions` from the current defaults.
- Everything else as today.

`MenuPreferences` and its three toggle cases are removed from the app.

## 6. Testing

**Menu model (hermetic).** `MenuModelTests.swift` is rewritten against the new
structure rather than patched: New holds checks come from defaults; the lid
checkbox is greyed without the grant; each hold row has a submenu whose checkboxes
reflect that hold's flags and not the defaults; the detail row states the precise
end for each kind; Release all appears only with two or more holds; the empty state
is one disabled row; Settings contains grant, floor, and skill rows; Quit is last;
warnings and last-ended still lead. The "actionless items are never enabled"
invariant stays.

**Replacement options (pure).** Each modifier flip alone; kind, label, source, and
watched pid preserved; a timer carries remaining seconds, not its original length;
under one second left yields nil.

**Service (faked).** The fake spawner records spawns and terminations in order:
replacement spawned before the original is terminated; replacement id differs;
expiry within one second of the original; a refused `on` leaves the original
untouched; unknown id throws `holdNotFound`. In `LidClosedServiceTests`: off→on
sets the flag through the existing pre-flight; on→off leaves the marker owned (the
watcher clears it, and watchers do not run hermetically); on→on keeps the marker
owned; acOnly on battery is refused with the original still live.

**Settings.** Defaults round-trip; an old file without the key decodes to all-off;
a corrupt value falls back like the floor does.

**Real processes (integration), one test.** Copying
`realSpawnedCaffeinateSurvivesReconciliation`: spawn a real caffeinate with a short
`-t` backstop, `modify` display on, then assert with the real `PSProcessSnapshotter`
that the new pid is alive and matched, the old pid is gone, and the hold survives
reconciliation. `defer` terminates whatever is left of both pids.

**Real processes, lid transitions.** The service takes its watcher spawner through
`WatcherSpawning`. A test-only conformer in `RealLidWatchTests.swift` forwards to
`SystemWatcherSpawner` with `--no-flag` appended, so `modify` runs through the real
service, a real watcher binary, and the real process table, with the flag, grant,
and battery faked through `LidClosedDependencies`. The service itself never passes
the hook. Three cases, each with a short `-t` backstop and `defer` cleanup of every
spawned pid:

- off→on: the record becomes lid-closed with a `teainate` watcher pid, the old
  caffeinate is gone, the store marker is owned, and the hold survives
  reconciliation.
- on→off: the record becomes a plain caffeinate hold and the old watcher exits.
  With `--no-flag` the watcher never touches any flag, so the marker is left owned
  with no lid-closed hold live; the service's own orphan cleanup, run at the end of
  `off`, then clears the fake flag (`clear()` called once, marker dropped).
- on→on: two watchers overlap, then only the new one remains, the marker stays
  owned, and `status()` does **not** call the fake flag's `clear()`.

The watcher's own exit-time flag decision is not exercised here (its process runs
with `--no-flag`); that logic stays covered by `LidWatchRunnerTests`. What these
three prove is the composition: real spawn arguments, real process identity through
`ps`, real signalling, and the record and marker state the service is left with.

No test calls `set()` or `clear()` on a real flag controller.

**Lineage.** `off --id` with the original id releases a once-edited and a
twice-edited hold; `off` with the replacement's own id also works; `modify` never
releases the replacement it just made (the `exact` path); `status --json` carries
`replaces`; a record without the field decodes.

**Hand verification** after `make-app.sh`: tick display on a live hold and confirm
the assertion changes in `pmset -g assertions`; convert a plain hold to lid-closed
and close the lid.

## Followups created by this design

None. Both edges found in review (a stale id after a menu edit, and lid
transitions untested with real processes) are closed by lineage and the injected
no-flag spawner above.
