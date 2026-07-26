import AppKit
import TeainateCore

/// Translates a `MenuItem` list into an `NSMenu`. Deliberately contains no decisions —
/// every choice about what appears lives in `buildMenu`, which is unit-tested.
@MainActor
final class MenuRenderer {
    private var actions: [Int: MenuAction] = [:]
    private let handler: (MenuAction) -> Void

    init(handler: @escaping (MenuAction) -> Void) {
        self.handler = handler
    }

    func render(_ items: [MenuItem]) -> NSMenu {
        actions.removeAll()
        let menu = NSMenu()
        menu.autoenablesItems = false

        for (index, item) in items.enumerated() {
            guard !item.isSeparator else {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(
                title: item.title, action: #selector(fire(_:)), keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.tag = index
            menuItem.isEnabled = item.isEnabled
            menuItem.state = item.isChecked ? .on : .off
            menuItem.indentationLevel = item.indent
            actions[index] = item.action
            menu.addItem(menuItem)
        }
        return menu
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard let action = actions[sender.tag] else { return }
        handler(action)
    }
}
