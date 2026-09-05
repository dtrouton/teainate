import AppKit
import Foundation
import TeainateCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var renderer: MenuRenderer!
    private let paths = TeainatePaths.standard()
    private var settingsStore: SettingsStore { SettingsStore(fileURL: paths.settingsFile) }
    private var cliPath: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/teainate")
    }
    private lazy var service = TeainateService.standard(paths: paths, watcherExecutable: cliPath)
    private var refreshTimer: Timer?
    private var lastReportedEnded: Date?
    private let grant = SudoersGrant()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        renderer = MenuRenderer { [weak self] action in self?.handle(action) }

        // Do not alert about a hold that ended before this launch.
        lastReportedEnded = (try? service.status())?.lidClosed.lastEnded?.at

        refresh()

        // Keeps the icon and countdown honest when holds expire on their own.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

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
        let lidEnabled = grant.isGranted()
        do {
            _ = try service.on(newHoldOptions(duration: duration, defaults: defaults, lidEnabled: lidEnabled))
        } catch {
            present(error: "Could not start the hold.", detail: "\(error)")
        }
    }

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

    /// Confirms first: these are processes teainate did not start and cannot prove
    /// are stale, so terminating them is never silent.
    private func reclaimUntracked() {
        let status = (try? service.status())
        let count = status?.untrackedCaffeinate.count ?? 0
        guard count > 0 else { return }

        let alert = NSAlert()
        alert.messageText = "Release \(count) untracked caffeinate process\(count == 1 ? "" : "es")?"
        alert.informativeText = """
            These were not started by teainate. They may be leftovers from a teainate \
            crash, or they may belong to another tool that is deliberately keeping \
            this Mac awake.
            """
        alert.alertStyle = .warning
        // Cancel is first (= Return-key default); Release carries no key equivalent at
        // all, so a reflexive Enter can never terminate processes teainate didn't start.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Release")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        do { _ = try service.reclaimUntracked() }
        catch { present(error: "Could not release the untracked processes.", detail: "\(error)") }
    }

    private func installSkill() {
        do {
            try SkillInstaller(paths: paths, cliPath: cliPath).install()
        } catch {
            present(error: "Could not install the Claude Code skill.",
                    detail: error.localizedDescription)
        }
    }

    private func present(error message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}
