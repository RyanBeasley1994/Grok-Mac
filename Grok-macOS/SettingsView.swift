//
//  SettingsView.swift
//  Grok-macOS
//
//  Grok-dark control deck: void, violet signal, rounded type.
//

import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

private enum GrokInk {
    static let void = Color(red: 0.03, green: 0.016, blue: 0.05)
    static let ink = Color(red: 0.055, green: 0.04, blue: 0.08)
    static let slab = Color(red: 0.09, green: 0.07, blue: 0.13)
    static let line = Color(red: 0.18, green: 0.14, blue: 0.24)
    static let mist = Color(red: 0.72, green: 0.69, blue: 0.78)
    static let paper = Color(red: 0.96, green: 0.94, blue: 0.98)
    static let signal = Color(red: 0.79, green: 0.61, blue: 1.0)
    static let signalDeep = Color(red: 0.62, green: 0.36, blue: 1.0)
    static let ember = Color(red: 1.0, green: 0.48, blue: 0.54)
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case live, hear, companion, keys
    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "Live"
        case .hear: return "Hear"
        case .companion: return "Companion"
        case .keys: return "Keys"
        }
    }

}

struct SettingsView: View {
    @ObservedObject var state: BrowserState
    @State private var pane: SettingsPane = .live
    @State private var toggleCombo = KeyCombo.stored(.toggle)
    @State private var voiceCombo = KeyCombo.stored(.voice)
    @State private var askCombo = KeyCombo.stored(.ask)
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var voiceIdentifier = SystemVoice.selectedIdentifier
    @State private var grokPath = GrokCLI.customPath

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle()
                .fill(GrokInk.line)
                .frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    switch pane {
                    case .live: livePane
                    case .hear: hearPane
                    case .companion: companionPane
                    case .keys: keysPane
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(GrokInk.ink)
        }
        .background(GrokInk.void)
        .preferredColorScheme(.dark)
        .frame(minWidth: 720, minHeight: 560)
        .onAppear {
            toggleCombo = KeyCombo.stored(.toggle)
            voiceCombo = KeyCombo.stored(.voice)
            askCombo = KeyCombo.stored(.ask)
            launchAtLogin = LaunchAtLogin.isEnabled
            voiceIdentifier = SystemVoice.selectedIdentifier
            grokPath = GrokCLI.customPath
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GROK")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(3.2)
                .foregroundStyle(GrokInk.signal)
                .padding(.horizontal, 16)
                .padding(.top, 22)
                .padding(.bottom, 18)

            ForEach(SettingsPane.allCases) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { pane = item }
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(pane == item ? GrokInk.signal : Color.clear)
                            .frame(width: 2, height: 14)
                        Text(item.title)
                            .font(.system(size: 14, weight: pane == item ? .semibold : .regular, design: .rounded))
                            .foregroundStyle(pane == item ? GrokInk.paper : GrokInk.mist)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(pane == item ? GrokInk.slab : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("on this Mac")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(GrokInk.mist.opacity(0.45))
                .padding(16)
        }
        .frame(width: 168)
        .background(GrokInk.void)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pane.title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(2.4)
                .foregroundStyle(GrokInk.signal)
            Text(headerLine)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(GrokInk.paper)
        }
    }

    private var headerLine: String {
        switch pane {
        case .live: return "How Grok sits on the desk."
        case .hear: return "How it starts listening."
        case .companion: return "The Grokling, and how it talks."
        case .keys: return "Hands stay on the keyboard."
        }
    }

    // MARK: - Live

    private var livePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            slab {
                GrokSwitch(title: "Open at login", detail: "Grok is waiting after you sign in.", isOn: launchBinding)
                if let launchError {
                    Text(launchError)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(GrokInk.ember)
                }
                hairline
                GrokSwitch(
                    title: "Start in the menu bar",
                    detail: "No chat on launch. Dock only while chat is open.",
                    isOn: dockBinding
                )
            }
            slab {
                Text("Chat shape")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(GrokInk.mist)
                choiceRow(
                    title: ChatLayout.sidebar.title,
                    detail: "Tall strip on one edge of the screen.",
                    selected: state.chatLayout == .sidebar
                ) { state.setChatLayout(.sidebar) }
                choiceRow(
                    title: ChatLayout.window.title,
                    detail: "A normal movable window you can resize.",
                    selected: state.chatLayout == .window
                ) { state.setChatLayout(.window) }
                if state.chatLayout == .sidebar {
                    hairline
                    Text("Sidebar edge")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(GrokInk.mist)
                    HStack(spacing: 10) {
                        edgeButton(.left)
                        edgeButton(.right)
                    }
                }
            }
            slab {
                permissionRow("Microphone", MicPermission.label)
                hairline
                permissionRow("Speech", SpeechPermission.label)
                Text("Allow each once. A stable Grok Local signature keeps the grant.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(GrokInk.mist)
                HStack(spacing: 8) {
                    if MicPermission.status == .denied || MicPermission.status == .restricted {
                        ghostButton("Microphone Settings") { MicPermission.openSystemSettings() }
                    } else if MicPermission.status == .notDetermined {
                        ghostButton("Allow Microphone") { MicPermission.request() }
                    }
                    if SpeechPermission.status == .denied || SpeechPermission.status == .restricted {
                        ghostButton("Speech Settings") { SpeechPermission.openSystemSettings() }
                    }
                }
            }
        }
    }

    // MARK: - Hear

    private var hearPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            voiceTile(.off, "Hotkey, Grokling, or menu only.")
            voiceTile(.heyGrok, "On-device. The mic indicator stays on.")
            voiceTile(.heySiri, "“Hey Siri, talk to Grok.” No always-on mic.")

            if state.voiceActivationMode == .heyGrok {
                slab {
                    Text(state.wakeWordStatus.caption)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(wakeWordCaptionColor)
                    if state.wakeWordStatus == .denied {
                        HStack {
                            ghostButton("Microphone Settings") { MicPermission.openSystemSettings() }
                            ghostButton("Speech Settings") { SpeechPermission.openSystemSettings() }
                        }
                    } else if state.wakeWordStatus == .unavailable {
                        ghostButton("Open Keyboard Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } else if state.voiceActivationMode == .heySiri {
                slab {
                    ghostButton("Open Siri Settings") { SiriSettings.open() }
                }
            }
        }
    }

    // MARK: - Companion

    private var companionPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            slab {
                GrokSwitch(
                    title: "Show the Grokling",
                    detail: "Click to talk. Drop a file to open chat. Drag to move.",
                    isOn: companionBinding
                )
                hairline
                GrokSwitch(
                    title: "Experimental voice",
                    detail: state.experimentalCompanion
                        ? "Mac speech in, Grok CLI works, Mac speech out."
                        : "Off: voice still runs on grok.com inside the Grokling.",
                    isOn: experimentalBinding
                )
                hairline
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Size")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(GrokInk.paper)
                        Spacer()
                        Text("\(Int(state.companionScale * 100))%")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(GrokInk.signal)
                    }
                    Slider(
                        value: Binding(
                            get: { state.companionScale },
                            set: { state.setCompanionScale($0) }
                        ),
                        in: 0.6...2.0,
                        step: 0.1
                    )
                    .tint(GrokInk.signalDeep)
                }
            }

            if state.experimentalCompanion {
                slab {
                    Text("Voice")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(GrokInk.mist)
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
                    .labelsHidden()
                    ghostButton("Preview voice") { CompanionSpeaker.preview() }
                    if let talkError = state.companionTalk.lastError {
                        Text(talkError)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(GrokInk.ember)
                    }
                    HStack {
                        Text("Status")
                            .foregroundStyle(GrokInk.mist)
                        Spacer()
                        Text(state.companionTalk.debugLine)
                            .foregroundStyle(GrokInk.paper)
                    }
                    .font(.system(size: 13, design: .rounded))
                    if let heard = state.companionTalk.lastHeard {
                        Text("Last heard: \(heard)")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(GrokInk.mist)
                    }
                    ghostButton("Open companion log") { CompanionDebug.revealLog() }
                }
                slab {
                    HStack {
                        Text("Grok CLI")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(GrokInk.paper)
                        Spacer()
                        Text(grokCLIStatus)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(grokCLIStatus == "Found" ? GrokInk.signal : GrokInk.ember)
                    }
                    TextField("CLI path (optional)", text: grokPathBinding)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(GrokInk.void, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(GrokInk.line, lineWidth: 1)
                        )
                    Text("Blank uses ~/.grok/bin/grok. Full computer access; answers in conversation.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(GrokInk.mist)
                }
            }
        }
    }

    // MARK: - Keys

    private var keysPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            slab {
                keyRow("Show or hide Grok", $toggleCombo, .toggle)
                hairline
                keyRow("Start or stop voice", $voiceCombo, .voice)
                hairline
                keyRow("Ask Grok about selection", $askCombo, .ask)
                Text("Highlighted text in any app. Finder can send files.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(GrokInk.mist)
            }
            ghostButton("Reset to defaults") {
                KeyCombo.reset(.toggle)
                KeyCombo.reset(.voice)
                KeyCombo.reset(.ask)
                toggleCombo = .defaultToggle
                voiceCombo = .defaultVoice
                askCombo = .defaultAsk
                HotKeyManager.shared.reregister()
            }
        }
    }

    // MARK: - Pieces

    private func slab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GrokInk.slab, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(GrokInk.line, lineWidth: 1)
        )
    }

    private var hairline: some View {
        Rectangle()
            .fill(GrokInk.line)
            .frame(height: 1)
    }

    private func permissionRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(GrokInk.paper)
            Spacer()
            Text(value.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(value.lowercased().contains("allow") ? GrokInk.signal : GrokInk.ember)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    (value.lowercased().contains("allow") ? GrokInk.signal : GrokInk.ember).opacity(0.12),
                    in: Capsule()
                )
        }
    }

    private func voiceTile(_ mode: VoiceActivationMode, _ subtitle: String) -> some View {
        let on = state.voiceActivationMode == mode
        return Button {
            state.setVoiceActivationMode(mode)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .strokeBorder(on ? GrokInk.signal : GrokInk.line, lineWidth: on ? 5 : 1.5)
                    .frame(width: 16, height: 16)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(GrokInk.paper)
                    Text(subtitle)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(GrokInk.mist)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GrokInk.slab, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(on ? GrokInk.signal.opacity(0.55) : GrokInk.line, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func keyRow(_ title: String, _ combo: Binding<KeyCombo>, _ slot: KeyCombo.Slot) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(GrokInk.paper)
            Spacer()
            HotkeyRecorder(combo: combo) { apply(slot, $0) }
        }
    }

    private func choiceRow(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .strokeBorder(selected ? GrokInk.signal : GrokInk.line, lineWidth: selected ? 5 : 1.5)
                    .frame(width: 16, height: 16)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(GrokInk.paper)
                    Text(detail)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(GrokInk.mist)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func edgeButton(_ edge: ChatSidebarEdge) -> some View {
        let on = state.chatSidebarEdge == edge
        return Button {
            state.setChatSidebarEdge(edge)
        } label: {
            Text(edge.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(on ? GrokInk.void : GrokInk.paper)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(on ? GrokInk.signal : GrokInk.void, in: Capsule())
                .overlay(Capsule().stroke(on ? GrokInk.signal : GrokInk.line, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func ghostButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(GrokInk.paper)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minHeight: 36)
                .background(GrokInk.void, in: Capsule())
                .overlay(Capsule().stroke(GrokInk.line, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
        GrokCLI.resolveBinary() != nil ? "Found" : "Not found"
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

    private var wakeWordCaptionColor: Color {
        guard state.voiceActivationMode == .heyGrok else { return GrokInk.mist }
        switch state.wakeWordStatus {
        case .denied, .unavailable, .failed:
            return GrokInk.ember
        default:
            return GrokInk.mist
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
        let taken = KeyCombo.Slot.allCases.contains { $0 != slot && combo == KeyCombo.stored($0) }
        if taken { return }
        combo.save(slot)
        switch slot {
        case .toggle: toggleCombo = combo
        case .voice: voiceCombo = combo
        case .ask: askCombo = combo
        }
        HotKeyManager.shared.reregister()
    }
}

private struct GrokSwitch: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(GrokInk.paper)
                Text(detail)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(GrokInk.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(GrokInk.signalDeep)
                .labelsHidden()
                .scaleEffect(1.05)
                .frame(minWidth: 52, minHeight: 36)
                .contentShape(Rectangle())
        }
        .contentShape(Rectangle())
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
            Text(recording ? "type it" : combo.display)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(recording ? GrokInk.void : GrokInk.paper)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minWidth: 108, minHeight: 36)
                .background(
                    recording ? GrokInk.signal : GrokInk.void,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(recording ? GrokInk.signal : GrokInk.line, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
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
            panel.contentView = NSHostingView(rootView: SettingsView(state: state))
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingView(rootView: SettingsView(state: state))
        let size = NSSize(width: 760, height: 600)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Grok"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.backgroundColor = NSColor(red: 0.03, green: 0.016, blue: 0.05, alpha: 1)
        panel.identifier = NSUserInterfaceItemIdentifier("grok.settings")
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 680, height: 520)
        panel.contentView = hosting
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        Self.panel = panel
    }
}
