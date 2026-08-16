//
//  SettingsView.swift
//  Grok-macOS
//

import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: BrowserState
    @State private var toggleCombo = KeyCombo.stored(.toggle)
    @State private var voiceCombo = KeyCombo.stored(.voice)
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var voiceIdentifier = SystemVoice.selectedIdentifier
    @State private var grokPath = GrokCLI.customPath

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open Grok at login", isOn: launchBinding)
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Always hide Dock icon", isOn: dockBinding)
                Text("Off: chat shows in the Dock; closing the window leaves only the menu-bar icon. On: stay in the menu bar even while chat is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent("Microphone", value: MicPermission.label)
                LabeledContent("Speech Recognition", value: SpeechPermission.label)
                Text("Allow each once. Grok is signed with a stable local identity so macOS keeps the grant across launches and rebuilds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if MicPermission.status == .denied || MicPermission.status == .restricted {
                        Button("Microphone Settings") { MicPermission.openSystemSettings() }
                    } else if MicPermission.status == .notDetermined {
                        Button("Allow Microphone") { MicPermission.request() }
                    }
                    if SpeechPermission.status == .denied || SpeechPermission.status == .restricted {
                        Button("Speech Settings") { SpeechPermission.openSystemSettings() }
                    }
                }
            }

            Section("Start voice with") {
                voiceOption(
                    .off,
                    subtitle: "Hotkey, Grokling, or menu only."
                )
                voiceOption(
                    .heyGrok,
                    subtitle: "Grok listens on this Mac. The mic indicator stays on."
                )
                voiceOption(
                    .heySiri,
                    subtitle: "Say “Hey Siri, talk to Grok”. Siri starts voice — no always-on mic."
                )
                if state.voiceActivationMode == .heyGrok {
                    Text(state.wakeWordStatus.caption)
                        .font(.caption)
                        .foregroundStyle(wakeWordCaptionColor)
                    if state.wakeWordStatus == .denied {
                        HStack {
                            Button("Microphone Settings") { MicPermission.openSystemSettings() }
                            Button("Speech Settings") { SpeechPermission.openSystemSettings() }
                        }
                    } else if state.wakeWordStatus == .unavailable {
                        Button("Open Keyboard Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                } else if state.voiceActivationMode == .heySiri {
                    Button("Open Siri Settings") { SiriSettings.open() }
                }
            }

            Section("Companion") {
                Toggle("Show desktop companion", isOn: companionBinding)
                Text("A Grokling stays on your desktop. Click it to start or stop voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Experimental companion (Mac speech + Grok CLI)", isOn: experimentalBinding)
                Text(state.experimentalCompanion
                     ? "What you say is sent to a Grok CLI session that can work on this Mac. Grok answers out loud first, then does any work."
                     : "Off: voice still runs on grok.com inside the Grokling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Mascot size")
                        Spacer()
                        Text("\(Int(state.companionScale * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { state.companionScale },
                            set: { state.setCompanionScale($0) }
                        ),
                        in: 0.6...2.0,
                        step: 0.1
                    )
                }
            }

            if state.experimentalCompanion {
                Section("Companion speech") {
                    Picker("Voice", selection: voiceIdentifierBinding) {
                        Text("System default").tag("")
                        Section("Apple Intelligence") {
                            ForEach(SystemVoice.catalog.filter { $0.kind == .siri }) { voice in
                                Text(voice.menuLabel).tag(voice.identifier)
                            }
                        }
                        Section("Other") {
                            ForEach(SystemVoice.catalog.filter { $0.kind == .system }) { voice in
                                Text(voice.menuLabel).tag(voice.identifier)
                            }
                        }
                    }
                    Button("Preview voice") {
                        CompanionSpeaker.preview()
                    }
                    Text("Apple Intelligence voices are the Voice 1 / Voice 2 list from Siri settings, including British English.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let talkError = state.companionTalk.lastError {
                        Text(talkError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    LabeledContent("Status", value: state.companionTalk.debugLine)
                    if let heard = state.companionTalk.lastHeard {
                        Text("Last heard: \(heard)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Open companion log") {
                        CompanionDebug.revealLog()
                    }
                    Text("Writes every listen / Grok CLI / speech step to ~/Library/Logs/Grok-companion.log")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Grok CLI") {
                    LabeledContent("Status", value: grokCLIStatus)
                    TextField("CLI path (optional)", text: grokPathBinding)
                        .textFieldStyle(.roundedBorder)
                    Text("Leave blank to use ~/.grok/bin/grok. The session runs with full computer access so Grok can do work, then it answers in conversation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Keyboard shortcuts") {
                LabeledContent("Show or hide Grok") {
                    HotkeyRecorder(combo: $toggleCombo) { apply(.toggle, $0) }
                }
                LabeledContent("Start or stop voice") {
                    HotkeyRecorder(combo: $voiceCombo) { apply(.voice, $0) }
                }
                Button("Reset to defaults") {
                    KeyCombo.reset(.toggle)
                    KeyCombo.reset(.voice)
                    toggleCombo = .defaultToggle
                    voiceCombo = .defaultVoice
                    HotKeyManager.shared.reregister()
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, idealWidth: 460, minHeight: 680)
        .onAppear {
            toggleCombo = KeyCombo.stored(.toggle)
            voiceCombo = KeyCombo.stored(.voice)
            launchAtLogin = LaunchAtLogin.isEnabled
            voiceIdentifier = SystemVoice.selectedIdentifier
            grokPath = GrokCLI.customPath
        }
    }

    private var voiceIdentifierBinding: Binding<String> {
        Binding(
            get: { voiceIdentifier },
            set: {
                voiceIdentifier = $0
                SystemVoice.selectedIdentifier = $0
            }
        )
    }

    private var grokPathBinding: Binding<String> {
        Binding(
            get: { grokPath },
            set: {
                grokPath = $0
                GrokCLI.customPath = $0
            }
        )
    }

    private var grokCLIStatus: String {
        if GrokCLI.resolveBinary() != nil {
            return "Found"
        }
        return "Not found"
    }

    private var dockBinding: Binding<Bool> {
        Binding(
            get: { state.hideInDock },
            set: { state.setHideInDock($0) }
        )
    }

    private var companionBinding: Binding<Bool> {
        Binding(
            get: { state.companionVisible },
            set: { state.setCompanionVisible($0) }
        )
    }

    private var experimentalBinding: Binding<Bool> {
        Binding(
            get: { state.experimentalCompanion },
            set: { state.setExperimentalCompanion($0) }
        )
    }

    private func voiceOption(_ mode: VoiceActivationMode, subtitle: String) -> some View {
        Button {
            state.setVoiceActivationMode(mode)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: state.voiceActivationMode == mode ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(state.voiceActivationMode == mode ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var wakeWordCaptionColor: Color {
        guard state.voiceActivationMode == .heyGrok else { return .secondary }
        switch state.wakeWordStatus {
        case .denied, .unavailable, .failed:
            return .red
        default:
            return .secondary
        }
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { enabled in
                do {
                    try LaunchAtLogin.setEnabled(enabled)
                    launchAtLogin = LaunchAtLogin.isEnabled
                    launchError = nil
                } catch {
                    launchAtLogin = LaunchAtLogin.isEnabled
                    launchError = error.localizedDescription
                }
            }
        )
    }

    private func apply(_ slot: KeyCombo.Slot, _ combo: KeyCombo) {
        let other: KeyCombo.Slot = slot == .toggle ? .voice : .toggle
        if combo == KeyCombo.stored(other) { return }
        combo.save(slot)
        switch slot {
        case .toggle: toggleCombo = combo
        case .voice: voiceCombo = combo
        }
        HotKeyManager.shared.reregister()
    }
}

struct HotkeyRecorder: View {
    @Binding var combo: KeyCombo
    var onChange: (KeyCombo) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type a shortcut…" : combo.display)
                .font(.body.monospaced())
                .frame(minWidth: 128)
        }
        .buttonStyle(.bordered)
        .help(recording ? "Press Esc to cancel" : "Click, then press a new shortcut")
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKeyManager.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            if let next = KeyCombo.from(event: event) {
                onChange(next)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recording = false
        HotKeyManager.shared.reregister()
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
enum SettingsWindow {
    private static var panel: NSPanel?

    static func open() {
        guard let state = BrowserState.shared else { return }
        NSApp.activate()

        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingView(rootView: SettingsView(state: state))
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = NSSize(width: 480, height: 920)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Grok Settings"
        panel.identifier = NSUserInterfaceItemIdentifier("grok.settings")
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        Self.panel = panel
    }
}
