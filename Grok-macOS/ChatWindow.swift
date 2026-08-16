//
//  ChatWindow.swift
//  Grok-macOS
//
//  The full grok.com window is created only when the user asks for it.
//  SwiftUI's Window scene was raising itself on every NSApp.activate(),
//  which made voice-from-mascot impossible to keep headless.
//

import AppKit
import SwiftUI

@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {

    static let shared = ChatWindowController()

    private var window: NSWindow?

    func isShowing() -> Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    func show() {
        HotKeyManager.shared.suppressChatReveal = false
        AppPresentation.sync(chatVisible: true)
        let window = existing()
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        if window.isMiniaturized { window.deminiaturize(nil) }
        HotKeyManager.shared.activateApp()
        window.makeKeyAndOrderFront(nil)
        HotKeyManager.shared.mainWindow = window
        AppPresentation.sync(chatVisible: true)
    }

    func hide() {
        window?.orderOut(nil)
        AppPresentation.sync(chatVisible: false)
    }

    func toggle() {
        if isShowing() {
            hide()
        } else {
            show()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    private func existing() -> NSWindow {
        if let window { return window }
        let state = BrowserState.shared ?? BrowserState()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Grok"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(white: 0.08, alpha: 1)
        window.minSize = NSSize(width: 800, height: 600)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("grok.chat")
        window.setFrameAutosaveName("GrokChat")
        window.delegate = self
        window.contentView = NSHostingView(rootView: ContentView(state: state))
        window.center()
        self.window = window
        HotKeyManager.shared.mainWindow = window
        return window
    }
}
