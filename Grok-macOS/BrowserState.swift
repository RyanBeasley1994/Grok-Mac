//
//  BrowserState.swift
//  Grok-macOS
//
//  Owns the open tabs (each a WebViewModel) and the split layout: the active
//  tab fills the window (left pane when split) and follows tab-bar clicks,
//  while an optional pinned tab sits in the right pane until the split is
//  closed. Menu commands route to the pane the user last clicked.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class BrowserState: ObservableObject {

    @Published private(set) var tabs: [WebViewModel]
    @Published private(set) var activeTab: WebViewModel
    @Published private(set) var pinnedTab: WebViewModel?

    var isSplit: Bool { pinnedTab != nil }

    // Menu-command target: the displayed webview the user last clicked.
    // Falls back to the active tab whenever the layout changes.
    @Published private(set) var focusedTab: WebViewModel
    @Published private(set) var companionVisible: Bool
    @Published private(set) var hideInDock: Bool
    @Published private(set) var chatLayout: ChatLayout
    @Published private(set) var chatSidebarEdge: ChatSidebarEdge
    @Published private(set) var companionScale: Double
    @Published private(set) var voiceActivationMode: VoiceActivationMode
    @Published private(set) var experimentalCompanion: Bool
    @Published private(set) var wakeWordStatus: WakeWordListener.Status = .off
    /// Dedicated grok.com session that lives inside the Grokling window.
    let mascotBrowser = WebViewModel()
    /// Experimental companion: Mac dictation → Grok CLI → Mac speech.
    let companionTalk = CompanionTalk()
    var prepareMascotBrowser: (() -> Void)?
    static weak var shared: BrowserState?

    var isVoiceActive: Bool {
        companionTalk.isActive
            || mascotBrowser.isVoiceActive
            || activeTab.isVoiceActive
            || pinnedTab?.isVoiceActive == true
    }

    var wakeWordEnabled: Bool { voiceActivationMode == .heyGrok }

    var isWakeWordListening: Bool { wakeWordStatus == .listening }

    private var mouseMonitor: Any?
    private var tabChangeForwarder: AnyCancellable?
    private var voiceActiveWatcher: AnyCancellable?
    private let wakeWord = WakeWordListener()
    private static let companionVisibleKey = "companionVisible"
    private static let hideInDockKey = "hideInDock"
    private static let chatLayoutKey = "chatLayout"
    private static let chatSidebarEdgeKey = "chatSidebarEdge"
    private static let companionScaleKey = "companionScale"
    private static let wakeWordEnabledKey = "wakeWordEnabled"
    private static let voiceActivationModeKey = "voiceActivationMode"
    private static let experimentalCompanionKey = "experimentalCompanion"

    init() {
        let tab = WebViewModel()
        tabs = [tab]
        activeTab = tab
        focusedTab = tab
        if UserDefaults.standard.object(forKey: Self.companionVisibleKey) == nil {
            companionVisible = true
        } else {
            companionVisible = UserDefaults.standard.bool(forKey: Self.companionVisibleKey)
        }
        hideInDock = UserDefaults.standard.bool(forKey: Self.hideInDockKey)
        if let raw = UserDefaults.standard.string(forKey: Self.chatLayoutKey),
           let layout = ChatLayout(rawValue: raw) {
            chatLayout = layout
        } else {
            chatLayout = .sidebar
        }
        if let raw = UserDefaults.standard.string(forKey: Self.chatSidebarEdgeKey),
           let edge = ChatSidebarEdge(rawValue: raw) {
            chatSidebarEdge = edge
        } else {
            chatSidebarEdge = .right
        }
        let storedScale = UserDefaults.standard.object(forKey: Self.companionScaleKey) == nil
            ? 1.0
            : UserDefaults.standard.double(forKey: Self.companionScaleKey)
        companionScale = min(max(storedScale, 0.6), 2.0)
        experimentalCompanion = UserDefaults.standard.bool(forKey: Self.experimentalCompanionKey)
        if let raw = UserDefaults.standard.string(forKey: Self.voiceActivationModeKey),
           let mode = VoiceActivationMode(rawValue: raw) {
            voiceActivationMode = mode
        } else if UserDefaults.standard.bool(forKey: Self.wakeWordEnabledKey) {
            voiceActivationMode = .heyGrok
        } else {
            voiceActivationMode = .off
        }
        wakeWord.onTrigger = { [weak self] in
            self?.startVoiceChat()
        }
        wakeWord.onStatusChange = { [weak self] status in
            self?.wakeWordStatus = status
        }
        rewireForwarding()
        wakeWord.sync(enabled: voiceActivationMode == .heyGrok, voiceActive: false)

        // WKWebView swallows clicks before SwiftUI gestures see them, so the
        // last-clicked pane is tracked by peeking at mouse-downs here and
        // passing the event through untouched.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.updateFocus(for: event) }
            return event
        }

        HotKeyManager.shared.onVoiceHotKey = { [weak self] in
            self?.toggleVoiceChat()
        }
        HotKeyManager.shared.onStopVoice = { [weak self] in
            self?.stopVoiceChat()
        }
        BrowserState.shared = self
        if experimentalCompanion {
            companionTalk.prewarm()
        }
    }

    func startVoiceChat() {
        CompanionDebug.log("voice.start experimental=\(experimentalCompanion) companionVisible=\(companionVisible) wake=\(wakeWordStatus) talkActive=\(companionTalk.isActive) mascotVoice=\(mascotBrowser.isVoiceActive)")
        MicPermission.request()
        if !companionVisible { setCompanionVisible(true) }
        HotKeyManager.shared.suppressChatReveal = true
        HotKeyManager.shared.hideChatWindow()
        HotKeyManager.shared.setEscapeStopsVoice(true)
        if experimentalCompanion {
            wakeWord.sync(enabled: voiceActivationMode == .heyGrok, voiceActive: true)
            mascotBrowser.stopVoiceChat()
            companionTalk.start()
        } else {
            companionTalk.stop()
            prepareMascotBrowser?()
            mascotBrowser.startVoiceChat()
        }
    }

    func stopVoiceChat() {
        CompanionDebug.log("voice.stop experimental=\(experimentalCompanion) talk=\(companionTalk.isActive) mascot=\(mascotBrowser.isVoiceActive)")
        HotKeyManager.shared.setEscapeStopsVoice(false)
        companionTalk.stop()
        mascotBrowser.stopVoiceChat()
        if activeTab.isVoiceActive { activeTab.stopVoiceChat() }
        if pinnedTab?.isVoiceActive == true { pinnedTab?.stopVoiceChat() }
        AppPresentation.sync()
    }

    func toggleVoiceChat() {
        if isVoiceActive {
            stopVoiceChat()
        } else {
            startVoiceChat()
        }
    }

    func setCompanionVisible(_ visible: Bool) {
        companionVisible = visible
        UserDefaults.standard.set(visible, forKey: Self.companionVisibleKey)
    }

    func setHideInDock(_ hidden: Bool) {
        hideInDock = hidden
        UserDefaults.standard.set(hidden, forKey: Self.hideInDockKey)
    }

    func setChatLayout(_ layout: ChatLayout) {
        guard chatLayout != layout else { return }
        chatLayout = layout
        UserDefaults.standard.set(layout.rawValue, forKey: Self.chatLayoutKey)
        ChatWindowController.shared.applyLayout()
    }

    func setChatSidebarEdge(_ edge: ChatSidebarEdge) {
        guard chatSidebarEdge != edge else { return }
        chatSidebarEdge = edge
        UserDefaults.standard.set(edge.rawValue, forKey: Self.chatSidebarEdgeKey)
        ChatWindowController.shared.applyLayout()
    }

    func setCompanionScale(_ scale: Double) {
        companionScale = min(max(scale, 0.6), 2.0)
        UserDefaults.standard.set(companionScale, forKey: Self.companionScaleKey)
    }

    func setExperimentalCompanion(_ enabled: Bool) {
        CompanionDebug.log("voice.experimental \(experimentalCompanion) → \(enabled)")
        guard experimentalCompanion != enabled else { return }
        if isVoiceActive { stopVoiceChat() }
        experimentalCompanion = enabled
        UserDefaults.standard.set(enabled, forKey: Self.experimentalCompanionKey)
        if enabled {
            companionTalk.prewarm()
        } else {
            companionTalk.shutdownWarm()
        }
    }

    func setVoiceActivationMode(_ mode: VoiceActivationMode) {
        voiceActivationMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.voiceActivationModeKey)
        UserDefaults.standard.set(mode == .heyGrok, forKey: Self.wakeWordEnabledKey)
        wakeWord.sync(enabled: mode == .heyGrok, voiceActive: isVoiceActive)
    }

    func setWakeWordEnabled(_ enabled: Bool) {
        setVoiceActivationMode(enabled ? .heyGrok : .off)
    }

    // MARK: - Tabs

    func newTab() {
        let tab = WebViewModel()
        tabs.append(tab)
        rewireForwarding()
        activate(tab)
    }

    func select(_ tab: WebViewModel) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        if tab === pinnedTab {
            // Already visible in the right pane; a tab can't be in both
            // panes, so just hand it keyboard focus.
            focusedTab = tab
            makeFirstResponder(tab)
            return
        }
        activate(tab)
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    func closeTab(_ tab: WebViewModel) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }

        // Last tab: keep it (and the session) alive, just hide the window,
        // matching the pre-tabs ⌘W behavior with Option+Space re-summon.
        if tabs.count == 1 {
            let window = tab.webView.window ?? HotKeyManager.shared.mainWindow
            window?.performClose(nil)
            return
        }

        tabs.remove(at: index)
        rewireForwarding()

        if tab === pinnedTab {
            closeSplit()
        } else if tab === activeTab {
            if let replacement = nearestTab(to: index, excluding: pinnedTab) {
                activate(replacement)
            } else if let pinned = pinnedTab {
                // Only the pinned tab is left; it becomes the active tab.
                pinnedTab = nil
                activate(pinned)
            }
        } else if tab === focusedTab {
            focusedTab = activeTab
        }
    }

    func nextTab() {
        cycleActiveTab(by: 1)
    }

    func previousTab() {
        cycleActiveTab(by: -1)
    }

    // MARK: - Split

    func openSplit(with tab: WebViewModel) {
        guard !isSplit, tab !== activeTab, tabs.contains(where: { $0 === tab }) else { return }
        pinnedTab = tab
        focusedTab = activeTab
        makeFirstResponder(activeTab)
    }

    func closeSplit() {
        guard isSplit else { return }
        pinnedTab = nil
        focusedTab = activeTab
        makeFirstResponder(activeTab)
    }

    // MARK: - Helpers

    private func activate(_ tab: WebViewModel) {
        activeTab = tab
        focusedTab = tab
        makeFirstResponder(tab)
    }

    private func cycleActiveTab(by step: Int) {
        guard let current = tabs.firstIndex(where: { $0 === activeTab }) else { return }
        var index = current
        for _ in 1..<tabs.count {
            index = (index + step + tabs.count) % tabs.count
            let candidate = tabs[index]
            if candidate !== pinnedTab {
                activate(candidate)
                return
            }
        }
    }

    private func nearestTab(to removedIndex: Int, excluding excluded: WebViewModel?) -> WebViewModel? {
        let candidates = tabs.enumerated()
            .filter { $0.element !== excluded }
            .sorted { abs($0.offset - removedIndex) < abs($1.offset - removedIndex) }
        return candidates.first?.element
    }

    // Deferred so SwiftUI has re-parented the webview before it takes focus.
    private func makeFirstResponder(_ tab: WebViewModel) {
        let webView = tab.webView
        DispatchQueue.main.async {
            webView.window?.makeFirstResponder(webView)
        }
    }

    private func updateFocus(for event: NSEvent) {
        guard isSplit, let window = event.window else { return }
        func hit(_ model: WebViewModel?) -> Bool {
            guard let webView = model?.webView, webView.window === window else { return false }
            return webView.bounds.contains(webView.convert(event.locationInWindow, from: nil))
        }
        if hit(pinnedTab), let pinned = pinnedTab {
            if focusedTab !== pinned { focusedTab = pinned }
        } else if hit(activeTab) {
            if focusedTab !== activeTab { focusedTab = activeTab }
        }
    }

    // Nested ObservableObjects don't propagate: menu items disabled off the
    // focused tab's canGoBack/canGoForward would go stale without this.
    private func rewireForwarding() {
        var publishers = tabs.map(\.objectWillChange)
        publishers.append(mascotBrowser.objectWillChange)
        publishers.append(companionTalk.objectWillChange)
        tabChangeForwarder = Publishers.MergeMany(publishers)
            .sink { [weak self] _ in self?.objectWillChange.send() }
        rewireVoiceWatcher()
    }

    private func rewireVoiceWatcher() {
        var flags = [companionTalk.$isActive.eraseToAnyPublisher()]
        flags.append(mascotBrowser.$isVoiceActive.eraseToAnyPublisher())
        flags.append(activeTab.$isVoiceActive.eraseToAnyPublisher())
        if let pinnedTab {
            flags.append(pinnedTab.$isVoiceActive.eraseToAnyPublisher())
        }
        voiceActiveWatcher = Publishers.MergeMany(flags)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.wakeWord.sync(enabled: self.voiceActivationMode == .heyGrok, voiceActive: self.isVoiceActive)
                HotKeyManager.shared.setEscapeStopsVoice(self.isVoiceActive)
                AppPresentation.sync()
            }
    }
}
