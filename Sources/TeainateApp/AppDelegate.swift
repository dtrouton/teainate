import AppKit
import Foundation
import TeainateCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var renderer: MenuRenderer!
    private var preferences = MenuPreferences()
    private let service = TeainateService.standard()
    private let paths = TeainatePaths.standard()
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        renderer = MenuRenderer { [weak self] action in self?.handle(action) }
        refresh()

        // Keeps the icon and countdown honest when holds expire on their own.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private var cliPath: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/teainate")
    }

    private func refresh() {
        let status = (try? service.status())
            ?? Status(awake: false, holds: [], foreignAssertions: [], untrackedCaffeinate: [])
        let skillState = SkillInstaller(paths: paths, cliPath: cliPath).state()

        statusItem.button?.title = statusIconIsActive(status) ? "☕️" : "🍵"
        statusItem.button?.toolTip = renderStatus(status)
        statusItem.menu = renderer.render(
            buildMenu(status: status, preferences: preferences, skillState: skillState)
        )
    }

    private func handle(_ action: MenuAction) {
        switch action {
        case .holdFor(let seconds):
            start(duration: seconds)
        case .holdForever:
            start(duration: nil)
        case .toggleACOnly:
            preferences.acOnly.toggle()
        case .toggleDisplay:
            preferences.display.toggle()
        case .release(let id):
            _ = try? service.off(id: id)
        case .releaseAll:
            _ = try? service.off(id: nil)
        case .reclaimUntracked:
            reclaimUntracked()
        case .installSkill:
            installSkill()
        case .quit:
            NSApp.terminate(nil)
        case .none:
            break
        }
        refresh()
    }

    private func start(duration: TimeInterval?) {
        do {
            _ = try service.on(HoldOptions(
                duration: duration,
                acOnly: preferences.acOnly,
                display: preferences.display,
                source: .menu
            ))
        } catch {
            present(error: "Could not start the hold.", detail: error.localizedDescription)
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

        _ = try? service.reclaimUntracked()
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
