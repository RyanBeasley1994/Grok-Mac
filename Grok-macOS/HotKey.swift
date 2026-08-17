//
//  HotKey.swift
//  Grok-macOS
//
//  Global hotkeys via Carbon RegisterEventHotKey: Option+Space toggles the
//  window, Option+Shift+Space starts voice. Works inside the sandbox and
//  needs no Accessibility/Input Monitoring permission.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class HotKeyManager {

    static let shared = HotKeyManager()

    static let signature = OSType(0x47_52_4F_4B) // 'GROK'
    static let toggleHotKeyID: UInt32 = 1
    static let voiceHotKeyID: UInt32 = 2
    static let escapeHotKeyID: UInt32 = 3
    static let askHotKeyID: UInt32 = 4

    weak var mainWindow: NSWindow?
    /// Voice start must not raise the SwiftUI chat window.
    var suppressChatReveal = false

    // BrowserState installs this so Option+Shift+Space can start voice on
    // the live tab after the window is ordered front.
    var onVoiceHotKey: (() -> Void)?
    var onStopVoice: (() -> Void)?

    private var toggleHotKeyRef: EventHotKeyRef?
    private var voiceHotKeyRef: EventHotKeyRef?
    private var askHotKeyRef: EventHotKeyRef?
    private var escapeHotKeyRef: EventHotKeyRef?
    private var escapeMonitor: Any?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func register() {
        if handlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventType, nil, &handlerRef)
        }
        reregister()
    }

    func unregister() {
        if let toggleHotKeyRef {
            UnregisterEventHotKey(toggleHotKeyRef)
            self.toggleHotKeyRef = nil
        }
        if let voiceHotKeyRef {
            UnregisterEventHotKey(voiceHotKeyRef)
            self.voiceHotKeyRef = nil
        }
        if let askHotKeyRef {
            UnregisterEventHotKey(askHotKeyRef)
            self.askHotKeyRef = nil
        }
        setEscapeStopsVoice(false)
    }

    func reregister() {
        unregister()
        let toggle = KeyCombo.stored(.toggle)
        RegisterEventHotKey(
            toggle.keyCode,
            toggle.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: Self.toggleHotKeyID),
            GetApplicationEventTarget(),
            0,
            &toggleHotKeyRef
        )
        let voice = KeyCombo.stored(.voice)
        RegisterEventHotKey(
            voice.keyCode,
            voice.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: Self.voiceHotKeyID),
            GetApplicationEventTarget(),
            0,
            &voiceHotKeyRef
        )
        let ask = KeyCombo.stored(.ask)
        RegisterEventHotKey(
            ask.keyCode,
            ask.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: Self.askHotKeyID),
            GetApplicationEventTarget(),
            0,
            &askHotKeyRef
        )
    }

    func handle(hotKeyID: EventHotKeyID) {
        CompanionDebug.log("hotkey id=\(hotKeyID.id)")
        guard hotKeyID.signature == Self.signature else { return }
        switch hotKeyID.id {
        case Self.toggleHotKeyID:
            toggle()
        case Self.voiceHotKeyID:
            startVoiceChat()
        case Self.askHotKeyID:
            SelectionCapture.askGrok()
        case Self.escapeHotKeyID:
            onStopVoice?()
        default:
            break
        }
    }

    /// While a voice session is live, Esc hangs up (global + in-app).
    func setEscapeStopsVoice(_ enabled: Bool) {
        if let escapeHotKeyRef {
            UnregisterEventHotKey(escapeHotKeyRef)
            self.escapeHotKeyRef = nil
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        guard enabled else { return }
        RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            EventHotKeyID(signature: Self.signature, id: Self.escapeHotKeyID),
            GetApplicationEventTarget(),
            0,
            &escapeHotKeyRef
        )
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            MainActor.assumeIsolated { HotKeyManager.shared.onStopVoice?() }
            return nil
        }
    }

    func toggle() {
        ChatWindowController.shared.toggle()
    }

    func isMainWindowShowing() -> Bool {
        ChatWindowController.shared.isShowing()
    }

    func startVoiceChat() {
        onVoiceHotKey?()
    }

    func activateApp() {
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost != .current {
            NSRunningApplication.current.activate(from: frontmost, options: [])
        } else {
            NSApp.activate()
        }
    }

    func hideChatWindow() {
        ChatWindowController.shared.hideImmediately()
    }

    func showMainWindow() {
        ChatWindowController.shared.show()
    }

    /// After voice starts, put the chat away if we only opened it for the mic.
    func minimizeMainWindow() {
        guard let window = mainWindow else { return }
        ChatWindowController.shared.hide()
    }

    /// Keep the signed-in page alive and on-screen for the mic, but invisible.
    /// Opening the chat UI is opt-in via Option+Space.
    func concealMainWindow() {
        // Unused: fading the chat window made it impossible to reopen
        // (isVisible stayed true). Voice starts on the real window instead.
        showMainWindow()
    }
}

// Carbon requires a C function pointer, which cannot carry actor isolation;
// the event arrives on the main thread, so hop back explicitly.
private nonisolated func hotKeyEventHandler(
    _ handler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    if let event {
        GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
    }
    Task { @MainActor in
        HotKeyManager.shared.handle(hotKeyID: hotKeyID)
    }
    return noErr
}

// Grabs the hosting NSWindow so the hotkey can order it front after it has
// been closed (SwiftUI keeps the Window scene's NSWindow instance alive).
struct WindowGrabber: NSViewRepresentable {

    private final class GrabberView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                HotKeyManager.shared.mainWindow = window
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        GrabberView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Transparent strip that steals hits from WKWebView so the window can be
/// dragged and double-clicked to zoom without a visible title bar.
struct TitlebarDragRegion: NSViewRepresentable {
    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { self }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.zoom(nil)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
