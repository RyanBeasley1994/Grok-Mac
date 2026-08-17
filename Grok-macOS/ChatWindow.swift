//
//  ChatWindow.swift
//  Grok-macOS
//
//  Chat is a right-edge sidebar. Opening starts a new grok.com chat.
//

import AppKit
import SwiftUI

enum ChatLayout: String, CaseIterable, Identifiable {
    case sidebar
    case window

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sidebar: return "Sidebar"
        case .window: return "Full window"
        }
    }
}

enum ChatSidebarEdge: String, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {

    static let shared = ChatWindowController()

    private var window: NSWindow?
    private var created = false
    private static let widthKey = "chatSidebarWidth"
    private static let defaultWidth: CGFloat = 440
    private static let minWidth: CGFloat = 360
    private static let maxWidth: CGFloat = 720

    func isShowing() -> Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    func show() {
        CompanionDebug.log("chat.show begin")
        HotKeyManager.shared.suppressChatReveal = false
        AppPresentation.sync(chatVisible: true)

        let first = !created
        let window = existing()
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        if !first {
            BrowserState.shared?.focusedTab.newChat()
        }

        // Switching accessory → regular needs a turn of the run loop
        // before orderFront, or the window never appears.
        DispatchQueue.main.async {
            HotKeyManager.shared.activateApp()
            Self.shared.applyChrome(to: window)
            window.setFrame(Self.onscreenFrame(), display: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate()
            HotKeyManager.shared.mainWindow = window
            AppPresentation.sync(chatVisible: true)
            CompanionDebug.log(
                "chat.show visible=\(window.isVisible) frame=\(NSStringFromRect(window.frame)) policy=\(NSApp.activationPolicy().rawValue)"
            )
        }
    }

    func openWithPrompt(_ text: String) {
        show()
        BrowserState.shared?.focusedTab.askAbout(text)
    }

    func openWithFiles(_ urls: [URL]) {
        show()
        BrowserState.shared?.focusedTab.attachFiles(urls)
    }

    func hide() {
        hideImmediately()
    }

    func hideImmediately() {
        CompanionDebug.log("chat.hide")
        persistFrame(window?.frame)
        window?.orderOut(nil)
        AppPresentation.sync(chatVisible: false)
    }

    func toggle() {
        CompanionDebug.log("chat.toggle showing=\(isShowing())")
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

    func applyLayout() {
        guard let window else { return }
        applyChrome(to: window)
        window.setFrame(Self.onscreenFrame(), display: true, animate: true)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        persistFrame(window?.frame)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        if BrowserState.shared?.chatLayout == .window {
            return NSSize(
                width: max(frameSize.width, 800),
                height: max(frameSize.height, 560)
            )
        }
        return NSSize(
            width: min(max(frameSize.width, Self.minWidth), Self.maxWidth),
            height: sender.frame.height
        )
    }

    private func existing() -> NSWindow {
        if let window { return window }
        let state = BrowserState.shared ?? BrowserState()
        let frame = Self.onscreenFrame()
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Grok"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.backgroundColor = NSColor(white: 0.08, alpha: 1)
        window.identifier = NSUserInterfaceItemIdentifier("grok.chat")
        window.delegate = self
        window.contentView = NSHostingView(rootView: ContentView(state: state))
        applyChrome(to: window)
        window.setFrame(frame, display: true)
        self.window = window
        created = true
        HotKeyManager.shared.mainWindow = window
        return window
    }

    private func applyChrome(to window: NSWindow) {
        let sidebar = BrowserState.shared?.chatLayout != .window
        if sidebar {
            window.minSize = NSSize(width: Self.minWidth, height: 400)
            window.maxSize = NSSize(width: Self.maxWidth, height: 20_000)
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        } else {
            window.minSize = NSSize(width: 800, height: 560)
            window.maxSize = NSSize(width: 10_000, height: 10_000)
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isHidden = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary, .managed]
        }
    }

    fileprivate static func onscreenFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        if BrowserState.shared?.chatLayout == .window {
            return storedWindowFrame(in: visible)
        }
        let width = storedWidth()
        let x = BrowserState.shared?.chatSidebarEdge == .left
            ? visible.minX
            : visible.maxX - width
        return NSRect(x: x, y: visible.minY, width: width, height: visible.height)
    }

    private static func storedWidth() -> CGFloat {
        let stored = UserDefaults.standard.object(forKey: Self.widthKey) == nil
            ? Self.defaultWidth
            : CGFloat(UserDefaults.standard.double(forKey: Self.widthKey))
        return min(max(stored, Self.minWidth), Self.maxWidth)
    }

    private static let windowFrameKey = "chatWindowFrame"

    private static func storedWindowFrame(in visible: NSRect) -> NSRect {
        if let values = UserDefaults.standard.array(forKey: windowFrameKey) as? [Double], values.count == 4 {
            var frame = NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
            if frame.width < 800 { frame.size.width = 1100 }
            if frame.height < 560 { frame.size.height = 740 }
            if !visible.intersects(frame) {
                frame.origin.x = visible.midX - frame.width / 2
                frame.origin.y = visible.midY - frame.height / 2
            }
            return frame
        }
        let size = NSSize(width: 1100, height: 740)
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func persistFrame(_ frame: NSRect?) {
        guard let frame else { return }
        if BrowserState.shared?.chatLayout == .window {
            UserDefaults.standard.set(
                [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].map(Double.init),
                forKey: Self.windowFrameKey
            )
        } else if frame.width >= Self.minWidth, frame.width <= Self.maxWidth {
            UserDefaults.standard.set(Double(frame.width), forKey: Self.widthKey)
        }
    }
}
