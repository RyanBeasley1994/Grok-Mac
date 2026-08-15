//
//  TalkToGrokIntent.swift
//  Grok-macOS
//
//  Siri / Shortcuts entry: “Hey Siri, talk to Grok”.
//

import AppIntents
import AppKit

struct TalkToGrokIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to Grok"
    static var description = IntentDescription("Start a voice conversation with Grok.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            PendingVoiceStart.request()
        }
        return .result()
    }
}

struct GrokAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToGrokIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Ask \(.applicationName)",
                "Start voice chat with \(.applicationName)",
            ],
            shortTitle: "Talk to Grok",
            systemImageName: "waveform"
        )
    }
}

@MainActor
enum PendingVoiceStart {
    private static var requested = false

    static func request() {
        if let state = BrowserState.shared {
            state.startVoiceChat()
        } else {
            requested = true
        }
    }

    static var isPending: Bool { requested }

    static func flush() {
        guard requested else { return }
        requested = false
        BrowserState.shared?.startVoiceChat()
    }
}

enum SiriSettings {
    static func open() {
        let urls = [
            "x-apple.systempreferences:com.apple.Siri-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.speech",
        ]
        for raw in urls {
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
}
