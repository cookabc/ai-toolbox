import AppKit
import SwiftUI

struct OverflowMenuButton: NSViewRepresentable {
    let isRefreshing: Bool
    let refresh: () -> Void
    let openDataDirectory: () -> Void
    let quit: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.title = ""
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多操作")
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "更多操作"
        button.setAccessibilityLabel("更多操作")
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.frame.size = NSSize(width: 28, height: 28)
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: OverflowMenuButton

        init(parent: OverflowMenuButton) {
            self.parent = parent
        }

        @MainActor @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let refreshItem = NSMenuItem(
                title: "刷新用量",
                action: #selector(refreshUsage),
                keyEquivalent: "r"
            )
            refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
            refreshItem.target = self
            refreshItem.isEnabled = !parent.isRefreshing
            menu.addItem(refreshItem)

            let folderItem = NSMenuItem(
                title: "打开数据目录",
                action: #selector(openFolder),
                keyEquivalent: ""
            )
            folderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            folderItem.target = self
            menu.addItem(folderItem)
            menu.addItem(.separator())

            let quitItem = NSMenuItem(
                title: "退出 AI 用量",
                action: #selector(quitApp),
                keyEquivalent: "q"
            )
            quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
            quitItem.target = self
            menu.addItem(quitItem)

            guard let event = NSApp.currentEvent else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: sender)
        }

        @MainActor @objc private func refreshUsage() { parent.refresh() }
        @MainActor @objc private func openFolder() { parent.openDataDirectory() }
        @MainActor @objc private func quitApp() { parent.quit() }
    }
}
