//
//  Grok_macOSApp.swift
//  Grok-macOS
//
//  Created by Nicholas Hershy on 7/8/26.
//

import AppKit
import SwiftUI

@main
struct Grok_macOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = BrowserState()

    var body: some Scene {
        // No Window scene — SwiftUI was forcing the chat window on every
        // activation. Chat is an AppKit window opened only on demand.
        Settings {
            SettingsView(state: state)
        }
        .commands {
            BrowserCommands(state: state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var companion: CompanionController?
    private let statusBar = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        CompanionDebug.log("app.launch experimental=\(BrowserState.shared?.experimentalCompanion ?? false) grok=\(GrokCLI.resolveBinary()?.path ?? "MISSING")")
        HotKeyManager.shared.register()
        DispatchQueue.main.async { [weak self] in
            if let state = BrowserState.shared {
                self?.attachCompanion(state: state)
                self?.statusBar.attach(state: state)
            }
            let siriVoice = PendingVoiceStart.isPending
            if !siriVoice, BrowserState.shared?.hideInDock != true {
                ChatWindowController.shared.show()
            }
            PendingVoiceStart.flush()
        }
    }

    func attachCompanion(state: BrowserState) {
        guard companion == nil else { return }
        companion = CompanionController(state: state)
    }

    static func revealMainWindow() {
        ChatWindowController.shared.show()
    }

    // Keep running when the window closes so Option+Space can resummon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if HotKeyManager.shared.suppressChatReveal { return false }
        HotKeyManager.shared.showMainWindow()
        return true
    }
}
