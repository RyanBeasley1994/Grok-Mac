//
//  VoiceHost.swift
//  Grok-macOS
//
//  An off-screen, full-size grok.com window that exists so voice can run
//  without opening the chat UI. WKWebView needs a real laid-out page and a
//  key window to take the mic; this gives it both while the Grokling is
//  what the user actually looks at.
//

import AppKit
import Combine
import WebKit

@MainActor
final class VoiceHost: ObservableObject {

    let model = WebViewModel()

    var isVoiceActive: Bool { model.isVoiceActive }

    private var window: NSWindow?
    private static let pageSize = NSSize(width: 1100, height: 760)

    init() {
        // Keep a full-size grok.com session rendered off-screen from launch
        // so ⌘⇧O can fire immediately — no waiting for a page load.
        _ = hostWindow()
    }

    func start() {
        let window = hostWindow()
        parkOffscreen(window)
        window.orderFrontRegardless()
        // Become key for getUserMedia / ⌘⇧O, but do not show the chat window.
        NSApp.activate()
        window.makeKey()
        window.makeFirstResponder(model.webView)
        model.startVoiceChat()
    }

    func stop() {
        model.stopVoiceChat()
    }

    func toggle() {
        if isVoiceActive {
            stop()
        } else {
            start()
        }
    }

    private func hostWindow() -> NSWindow {
        if let window { return window }

        let window = OffscreenWindow(
            contentRect: NSRect(origin: .zero, size: Self.pageSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("grok.voice-host")
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.hidesOnDeactivate = false
        window.hasShadow = false
        window.animationBehavior = .none
        window.backgroundColor = NSColor(white: 0.08, alpha: 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        window.level = .normal

        let container = NSView(frame: NSRect(origin: .zero, size: Self.pageSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        model.webView.frame = container.bounds
        model.webView.autoresizingMask = [.width, .height]
        container.addSubview(model.webView)
        window.contentView = container

        parkOffscreen(window)
        // Stay ordered (off-screen) so the SPA actually paints and cookies
        // apply. orderOut would freeze the page as a blank document.
        window.orderFrontRegardless()
        self.window = window
        return window
    }

    private func parkOffscreen(_ window: NSWindow) {
        let frames = NSScreen.screens.map(\.frame)
        let minX = frames.map(\.minX).min() ?? 0
        let minY = frames.map(\.minY).min() ?? 0
        window.setFrame(
            NSRect(
                x: minX - Self.pageSize.width - 200,
                y: minY - Self.pageSize.height - 200,
                width: Self.pageSize.width,
                height: Self.pageSize.height
            ),
            display: true
        )
    }
}

/// AppKit otherwise slides windows back onto a display. Voice must stay hidden.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
