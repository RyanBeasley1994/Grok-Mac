//
//  BrowserCommands.swift
//  Grok-macOS
//

import SwiftUI

struct BrowserCommands: Commands {
    @ObservedObject var state: BrowserState

    // Per-tab actions resolve state.focusedTab inside the closures so they
    // always hit the tab focused at invocation time.
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { state.focusedTab.newChat() }
                .keyboardShortcut("n", modifiers: .command)

            Button(state.isVoiceActive ? "Stop Voice Chat" : "Start Voice Chat") {
                state.toggleVoiceChat()
            }
            // No ⌘⇧O here — that's grok.com's toggle. Binding it in the
            // menu would recapture the key we send into the hidden webview
            // and immediately stop the session.

            Button("Close") {
                HotKeyManager.shared.mainWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: .command)
        }

        CommandMenu("Navigate") {
            Button("Reload Page") { state.focusedTab.reload() }
                .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("Back") { state.focusedTab.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!state.focusedTab.canGoBack)

            Button("Forward") { state.focusedTab.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!state.focusedTab.canGoForward)

            Divider()

            Button("Home") { state.focusedTab.newChat() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
        }

        CommandMenu("Companion") {
            Button(state.companionVisible ? "Hide Desktop Companion" : "Show Desktop Companion") {
                state.setCompanionVisible(!state.companionVisible)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Menu("Start voice with") {
                ForEach(VoiceActivationMode.allCases) { mode in
                    Button(mode.title) {
                        state.setVoiceActivationMode(mode)
                    }
                }
            }

            Button(state.experimentalCompanion
                   ? "Turn Off Experimental Companion"
                   : "Turn On Experimental Companion") {
                state.setExperimentalCompanion(!state.experimentalCompanion)
            }

            Button("Settings…") {
                SettingsWindow.open()
            }
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { state.focusedTab.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)

            Button("Zoom Out") { state.focusedTab.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)

            Button("Actual Size") { state.focusedTab.zoomReset() }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}
