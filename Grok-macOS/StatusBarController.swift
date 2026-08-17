//
//  StatusBarController.swift
//  Grok-macOS
//
//  Menu-bar extra used when the Dock icon is hidden.
//

import AppKit
import Combine

@MainActor
final class StatusBarController: NSObject {

    private weak var state: BrowserState?
    private var item: NSStatusItem?
    private var cancellable: AnyCancellable?

    func attach(state: BrowserState) {
        self.state = state
        AppPresentation.statusBar = self
        cancellable = state.$hideInDock.sink { _ in
            AppPresentation.sync()
        }
        AppPresentation.sync()
    }

    func apply(hideInDock: Bool) {
        if hideInDock {
            showItem()
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        } else {
            hideItem()
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
            NSApp.activate()
        }
    }

    private func showItem() {
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                button.image = Self.menuBarLogo()
                button.toolTip = "Grok"
            }
            item.menu = buildMenu()
            self.item = item
        }
        refreshMenu()
    }

    private func hideItem() {
        if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = MenuDelegate.shared
        MenuDelegate.shared.onOpen = { [weak self] in self?.refreshMenu() }
        return menu
    }

    private func refreshMenu() {
        guard let menu = item?.menu, let state else { return }
        menu.removeAllItems()

        menu.addItem(action("Open Grok", #selector(openGrok)))
        menu.addItem(action(
            state.isVoiceActive ? "Stop Voice Chat" : "Start Voice Chat",
            #selector(toggleVoice)
        ))
        let parent = NSMenuItem(title: "Start voice with", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for mode in VoiceActivationMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectVoiceActivation(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.menuTag
            item.state = state.voiceActivationMode == mode ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
        menu.addItem(action(
            state.companionVisible ? "Hide Companion" : "Show Companion",
            #selector(toggleCompanion)
        ))
        let experimental = action(
            "Experimental Companion",
            #selector(toggleExperimental)
        )
        experimental.state = state.experimentalCompanion ? .on : .off
        menu.addItem(experimental)
        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(action("Quit Grok", #selector(quit)))
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openGrok() {
        ChatWindowController.shared.show()
    }

    @objc private func toggleVoice() {
        state?.toggleVoiceChat()
    }

    @objc private func toggleCompanion() {
        guard let state else { return }
        state.setCompanionVisible(!state.companionVisible)
    }

    @objc private func toggleExperimental() {
        guard let state else { return }
        state.setExperimentalCompanion(!state.experimentalCompanion)
    }

    @objc private func selectVoiceActivation(_ sender: NSMenuItem) {
        guard let mode = VoiceActivationMode(menuTag: sender.tag) else { return }
        state?.setVoiceActivationMode(mode)
    }

    @objc private func openSettings() {
        SettingsWindow.open()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static func menuBarLogo() -> NSImage {
        let names = ["MenuBarLogo", "glyph"]
        var source: NSImage?
        for name in names {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                source = image
                break
            }
            if let image = NSImage(named: name) {
                source = image
                break
            }
        }
        let image = source ?? NSImage(systemSymbolName: "circle.slash", accessibilityDescription: "Grok")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image ?? NSImage()
    }
}

/// Dock only while the chat window is up. Voice (including experimental)
/// does not put the app in the Dock.
@MainActor
enum AppPresentation {
    static weak var statusBar: StatusBarController?
    private static var chatPresented = false

    static func sync(chatVisible: Bool? = nil) {
        // Only an explicit show/hide may change this. Voice and other
        // publishers used to call sync() while the sidebar was still
        // ordering front, which flipped the app back to accessory and
        // the panel never appeared.
        if let chatVisible {
            chatPresented = chatVisible
        }
        statusBar?.apply(hideInDock: !chatPresented)
    }
}

/// Rebuilds the status menu each time it opens so voice/companion titles stay current.
private final class MenuDelegate: NSObject, NSMenuDelegate {
    static let shared = MenuDelegate()
    var onOpen: (() -> Void)?

    func menuWillOpen(_ menu: NSMenu) {
        onOpen?()
    }
}
