//
//  CompanionController.swift
//  Grok-macOS
//
//  Always-on-top desktop pet: a draggable Grokling that toggles voice chat
//  and morphs into a talking orb while voice is live. Classic mode uses a
//  hidden grok.com page; experimental mode uses Mac speech + Grok CLI.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class CompanionController {

    private let state: BrowserState
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    private static let baseSize = NSSize(width: 148, height: 168)
    private static let pageSize = NSSize(width: 1100, height: 760)
    private static let xKey = "companionX"
    private static let yKey = "companionY"

    init(state: BrowserState) {
        self.state = state
        state.$companionVisible
            .sink { [weak self] visible in
                if visible {
                    self?.show()
                } else {
                    self?.hide()
                }
            }
            .store(in: &cancellables)
        state.$companionScale
            .sink { [weak self] _ in
                self?.applySize()
            }
            .store(in: &cancellables)
        state.prepareMascotBrowser = { [weak self] in
            self?.prepareForVoice()
        }
        if state.companionVisible {
            show()
        }
    }

    func prepareForVoice() {
        let panel = existingPanel()
        applySize()
        panel.orderFrontRegardless()
        HotKeyManager.shared.activateApp()
        if HotKeyManager.shared.suppressChatReveal {
            HotKeyManager.shared.hideChatWindow()
        }
        panel.makeKey()
        panel.makeFirstResponder(state.mascotBrowser.webView)
    }

    func show() {
        let panel = existingPanel()
        applySize()
        panel.setFrameOrigin(clamped(savedOrigin() ?? defaultOrigin()))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func persistPosition() {
        guard let origin = panel?.frame.origin else { return }
        UserDefaults.standard.set(origin.x, forKey: Self.xKey)
        UserDefaults.standard.set(origin.y, forKey: Self.yKey)
    }

    private func currentSize() -> NSSize {
        let scale = state.companionScale
        return NSSize(width: Self.baseSize.width * scale, height: Self.baseSize.height * scale)
    }

    private func applySize() {
        guard let panel else { return }
        let size = currentSize()
        var frame = panel.frame
        frame.size = size
        panel.setFrame(clamped(frame), display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
    }

    private func existingPanel() -> NSPanel {
        if let panel { return panel }
        let panel = CompanionPanel(
            contentRect: NSRect(origin: .zero, size: currentSize()),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("grok.companion")
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none

        let root = NSView(frame: NSRect(origin: .zero, size: currentSize()))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor

        // Full grok.com layout lives in this window but is clipped out of
        // sight so only the Grokling shows. Classic voice needs the page
        // on-screen so the mic can attach without opening chat.
        let web = state.mascotBrowser.webView
        web.frame = NSRect(origin: .zero, size: Self.pageSize)
        web.autoresizingMask = []
        web.alphaValue = 0
        root.addSubview(web)

        let hosting = ClearHostingView(rootView: CompanionView(state: state) { [weak self] in
            self?.persistPosition()
        })
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.frame = root.bounds
        hosting.autoresizingMask = [.width, .height]
        root.addSubview(hosting)

        panel.contentView = root
        self.panel = panel
        return panel
    }

    private func savedOrigin() -> NSPoint? {
        guard UserDefaults.standard.object(forKey: Self.xKey) != nil else { return nil }
        return NSPoint(
            x: UserDefaults.standard.double(forKey: Self.xKey),
            y: UserDefaults.standard.double(forKey: Self.yKey)
        )
    }

    private func defaultOrigin() -> NSPoint {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = currentSize()
        return NSPoint(
            x: visible.maxX - size.width - 18,
            y: visible.minY + 28
        )
    }

    private func clamped(_ origin: NSPoint) -> NSPoint {
        clamped(NSRect(origin: origin, size: currentSize())).origin
    }

    private func clamped(_ frame: NSRect) -> NSRect {
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            return frame
        }
        return NSRect(origin: defaultOrigin(), size: frame.size)
    }
}

private final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ClearHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

struct CompanionView: View {
    @ObservedObject var state: BrowserState
    var onMoved: () -> Void

    @State private var hovered = false
    @State private var floating = false
    @State private var dragOrigin: NSPoint?
    @State private var dragMouse: NSPoint?
    @State private var didDrag = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if state.isVoiceActive {
                talkingOrb
                    .transition(.opacity.combined(with: .scale(scale: 0.82)))
            } else {
                mascotImage((hovered || state.isWakeWordListening) ? "MascotListen" : "MascotIdle")
                    .shadow(color: .white.opacity(0.55), radius: 10)
                    .offset(y: reduceMotion ? 0 : (floating ? -4 : 3))
                    .transition(.opacity.combined(with: .scale(scale: 0.82)))
            }
        }
        .frame(width: 148 * state.companionScale, height: 168 * state.companionScale)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: state.isVoiceActive)
        .animation(.easeInOut(duration: 0.2), value: state.isWakeWordListening)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 2.3).repeatForever(autoreverses: true),
            value: floating
        )
        .onHover { hovered = $0 }
        .onAppear {
            if !reduceMotion { floating = true }
        }
        .help(companionHelp)
        .gesture(moveGesture)
        .contextMenu {
            Button(state.isVoiceActive ? "Stop Voice Chat" : "Start Voice Chat") {
                state.toggleVoiceChat()
            }
            Menu("Start voice with") {
                ForEach(VoiceActivationMode.allCases) { mode in
                    Button {
                        state.setVoiceActivationMode(mode)
                    } label: {
                        if state.voiceActivationMode == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            }
            Button(state.experimentalCompanion ? "Use grok.com Voice" : "Use Experimental Voice") {
                state.setExperimentalCompanion(!state.experimentalCompanion)
            }
            Button("Open Grok") { HotKeyManager.shared.showMainWindow() }
            Button("Settings…") { SettingsWindow.open() }
            Divider()
            Button("Hide Companion") { state.setCompanionVisible(false) }
        }
    }

    private var companionHelp: String {
        if state.isVoiceActive {
            return state.experimentalCompanion
                ? "Click to hang up. \(state.companionTalk.phase.label.capitalized)."
                : "Click to end voice chat"
        }
        if state.isWakeWordListening { return "Listening for “Hey Grok”. Click to start voice, or drag to move." }
        if state.voiceActivationMode == .heySiri { return "Say “Hey Siri, talk to Grok”. Click to start voice, or drag to move." }
        return state.experimentalCompanion
            ? "Click to talk. What you say goes to a Grok CLI session; Grok answers out loud."
            : "Click to start voice chat. Drag to move."
    }

    private var talkingOrb: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: reduceMotion)) { timeline in
            let frames = Self.talkingFrames
            if frames.isEmpty {
                return AnyView(mascotImage("MascotOrb"))
            }
            let index = Int(timeline.date.timeIntervalSinceReferenceDate * 12) % frames.count
            return AnyView(
                Image(nsImage: frames[index])
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .shadow(color: .white.opacity(0.35), radius: 10)
            )
        }
    }

    private static let talkingFrames: [NSImage] = {
        let names = (1...200).map { String(format: "orb%03d", $0) }
        var images: [NSImage] = []
        for name in names {
            if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "OrbTalk")
                ?? Bundle.main.url(forResource: name, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                images.append(image)
            } else if !images.isEmpty {
                break
            }
        }
        return images
    }()

    private func mascotImage(_ name: String) -> some View {
        Group {
            if let image = Self.sprite(named: name) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Circle()
                    .fill(Color.black)
                    .overlay(
                        Text("G")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    )
                    .padding(18)
            }
        }
    }

    /// Prefer a file in the app bundle so local (non-Xcode) builds still show art.
    /// SwiftUI `Image("name")` only hits the asset catalog, which we don't ship.
    private static func sprite(named name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(named: name)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                let mouse = NSEvent.mouseLocation
                guard let window = companionWindow() else { return }
                if dragOrigin == nil {
                    dragOrigin = window.frame.origin
                    dragMouse = mouse
                    didDrag = false
                    return
                }
                let dx = mouse.x - (dragMouse?.x ?? mouse.x)
                let dy = mouse.y - (dragMouse?.y ?? mouse.y)
                if hypot(dx, dy) > 4 { didDrag = true }
                window.setFrameOrigin(NSPoint(
                    x: (dragOrigin?.x ?? 0) + dx,
                    y: (dragOrigin?.y ?? 0) + dy
                ))
            }
            .onEnded { _ in
                if didDrag {
                    onMoved()
                } else {
                    state.toggleVoiceChat()
                }
                dragOrigin = nil
                dragMouse = nil
                didDrag = false
            }
    }

    private func companionWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "grok.companion" }
    }
}
