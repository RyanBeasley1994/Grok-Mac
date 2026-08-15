//
//  WebViewModel.swift
//  Grok-macOS
//
//  Owns the long-lived WKWebView and implements all WebKit delegates:
//  navigation policy, popups, uploads, downloads, and media capture.
//

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import WebKit

@MainActor
final class WebViewModel: NSObject, ObservableObject {

    static let homeURL = URL(string: "https://grok.com")!

    // Hosts that stay inside the app. Everything else opens in the default browser.
    // Auth providers must be in-app or sign-in flows break.
    private static let inAppHosts: [String] = [
        "grok.com",
        "x.ai",
        "x.com",
        "twitter.com",
        "accounts.google.com",
        "accounts.youtube.com",  // Google auth cookie-sync redirect
        "google.com",            // OAuth consent intermediate pages
        "gstatic.com",
        "appleid.apple.com",
        "apple.com",
        "recaptcha.net",
        "hcaptcha.com",
        "cloudflare.com",
        "challenges.cloudflare.com",
    ]

    // A real Safari UA (no app token) so Google OAuth doesn't reject the
    // embedded webview with "This browser or app may not be secure".
    private static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"

    private static let zoomDefaultsKey = "pageZoom"

    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var zoomPercent = 100
    @Published var sidebarCSSWidth: Double = 248
    @Published var pageTitle = "Grok"
    @Published var isVoiceActive = false

    let webView: WKWebView

    private var observations: [NSKeyValueObservation] = []
    private var popupWindows: [NSWindow] = []
    private var activeDownloads: [WKDownload: URL] = [:]
    private let scriptMessageProxy = ScriptMessageProxy()
    private var voiceStartToken = 0
    private var voiceHoldUntil = Date.distantPast

    // Watches grok.com's sidebar (the full-height container hugging the
    // left edge): reports its CSS-pixel width so native overlays can track
    // collapse/expand, and forces it dark (black background, white text)
    // when the page renders a light theme. Media elements are re-inverted
    // so avatars keep their true colors. Also tags the "New Chat" item so
    // it can be styled as the sidebar's primary action.
    private static let sidebarWatcherScript = """
    (function () {
        const STYLE_ID = 'native-sidebar-style';
        // Grok paints its dark theme in a viewport-sized container while the
        // root canvas stays white; any overflow or zoom rounding lets that
        // white peek out at the right/bottom edges. Pin the root dark
        // whenever the page renders dark (class toggled below).
        const CSS = 'html:not(.native-sidebar-invert) { background-color: #0a0a0a !important; }'
            + ' html.native-sidebar-invert [data-native-sidebar] { filter: invert(1) hue-rotate(180deg); }'
            + ' html.native-sidebar-invert [data-native-sidebar] :is(img, video, canvas) { filter: invert(1) hue-rotate(180deg); }'
            // Room for the macOS traffic lights sitting over the top-left.
            + ' [data-native-sidebar] { padding-top: 38px !important; box-sizing: border-box !important; }'
            + ' [data-native-sidebar] > :first-child { margin-top: 0 !important; }'
            + ' [data-native-newchat] {'
            + '   border-radius: 10px !important;'
            + '   font-weight: 500 !important;'
            + '   transition: background 0.15s ease, box-shadow 0.15s ease; }'
            // Two variants because the sidebar-invert filter flips colors:
            // when inverted (site in light mode), black paint displays white.
            + ' html:not(.native-sidebar-invert) [data-native-newchat] {'
            + '   background: linear-gradient(180deg, rgba(255,255,255,0.16), rgba(255,255,255,0.06)) !important;'
            + '   box-shadow: inset 0 0 0 1px rgba(255,255,255,0.35), 0 1px 6px rgba(0,0,0,0.35) !important; }'
            + ' html:not(.native-sidebar-invert) [data-native-newchat]:hover {'
            + '   background: linear-gradient(180deg, rgba(255,255,255,0.22), rgba(255,255,255,0.10)) !important;'
            + '   box-shadow: inset 0 0 0 1px rgba(255,255,255,0.5), 0 1px 8px rgba(0,0,0,0.4) !important; }'
            + ' html.native-sidebar-invert [data-native-newchat] {'
            + '   background: linear-gradient(180deg, rgba(0,0,0,0.16), rgba(0,0,0,0.06)) !important;'
            + '   box-shadow: inset 0 0 0 1px rgba(0,0,0,0.35), 0 1px 6px rgba(255,255,255,0.2) !important; }'
            + ' html.native-sidebar-invert [data-native-newchat]:hover {'
            + '   background: linear-gradient(180deg, rgba(0,0,0,0.22), rgba(0,0,0,0.10)) !important;'
            + '   box-shadow: inset 0 0 0 1px rgba(0,0,0,0.5), 0 1px 8px rgba(255,255,255,0.25) !important; }';

        function ensureStyle() {
            if (!document.getElementById(STYLE_ID)) {
                const style = document.createElement('style');
                style.id = STYLE_ID;
                style.textContent = CSS;
                document.head.appendChild(style);
            }
        }

        function findSidebar() {
            const probe = document.elementFromPoint(8, window.innerHeight / 2);
            if (!probe) { return null; }
            let node = probe;
            let found = null;
            while (node && node !== document.body) {
                const r = node.getBoundingClientRect();
                if (r.height >= window.innerHeight * 0.8 && r.width <= 500 && r.left <= 8) {
                    found = node;
                }
                node = node.parentElement;
            }
            return found;
        }

        // Grok's SPA rerenders the sidebar, dropping our attribute, so the
        // interval loop re-tags. Matched by visible text / aria-label since
        // the site's class names are hashed and unstable. Collapsed, the
        // item is icon-only with no accessible name, so fall back to the
        // one menu link to "/" that carries a sidebar icon (the logo also
        // links to "/" but renders its svg directly, without the icon div).
        function tagNewChat(sidebar) {
            if (sidebar.querySelector('[data-native-newchat]')) { return; }
            for (const el of sidebar.querySelectorAll('a, button')) {
                const text = (el.textContent || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                const label = (el.getAttribute('aria-label') || '').trim().toLowerCase();
                const title = (el.getAttribute('title') || '').trim().toLowerCase();
                if (text === 'new chat' || label.startsWith('new chat') || title.startsWith('new chat')
                    || (el.getAttribute('href') === '/' && el.querySelector('[data-sidebar="icon"]'))) {
                    el.setAttribute('data-native-newchat', '');
                    return;
                }
            }
        }

        function bgLuminance(el) {
            const parts = getComputedStyle(el).backgroundColor.match(/[\\d.]+/g);
            if (!parts || parts.length < 3) { return null; }
            if (parts.length === 4 && parseFloat(parts[3]) === 0) { return null; }
            return 0.299 * parts[0] + 0.587 * parts[1] + 0.114 * parts[2];
        }

        let last = -1;
        setInterval(function () {
            try {
                ensureStyle();
                const sidebar = findSidebar();
                if (!sidebar) { return; }
                sidebar.setAttribute('data-native-sidebar', '');
                tagNewChat(sidebar);
                const w = Math.round(sidebar.getBoundingClientRect().width);
                if (w > 0 && w !== last) {
                    last = w;
                    window.webkit.messageHandlers.sidebarWidth.postMessage(w);
                }
                const lum = bgLuminance(document.body) ?? bgLuminance(document.documentElement);
                const isLight = (lum === null) ? false : lum > 128;
                document.documentElement.classList.toggle('native-sidebar-invert', isLight);
            } catch (e) {}
        }, 400);
    })();
    """

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.customUserAgent = Self.safariUserAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = NSColor(white: 0.08, alpha: 1)
        // WKWebView paints a white backing that peeks out at the bottom and
        // right edges under fractional pageZoom; disable it so the dark
        // underPageBackgroundColor shows instead. (Long-standing WebKit KVC
        // key, in wide production use.)
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        webView.isInspectable = true
        #endif

        webView.navigationDelegate = self
        webView.uiDelegate = self

        scriptMessageProxy.model = self
        let contentController = webView.configuration.userContentController
        contentController.add(scriptMessageProxy, name: "sidebarWidth")
        contentController.addUserScript(WKUserScript(
            source: Self.sidebarWatcherScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        if UserDefaults.standard.object(forKey: Self.zoomDefaultsKey) != nil {
            let stored = UserDefaults.standard.double(forKey: Self.zoomDefaultsKey)
            webView.pageZoom = min(max(stored, 0.5), 3.0)
            zoomPercent = Int((webView.pageZoom * 100).rounded())
        }

        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    let title = view.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self?.pageTitle = title.isEmpty ? "Grok" : title
                }
            },
        ]

        webView.load(URLRequest(url: Self.homeURL))
        startVoicePolling()
    }

    // MARK: - Commands

    func newChat() {
        webView.load(URLRequest(url: Self.homeURL))
    }

    func reload() {
        webView.reload()
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func zoomIn() {
        setZoom(webView.pageZoom * 1.1)
    }

    func zoomOut() {
        setZoom(webView.pageZoom / 1.1)
    }

    func zoomReset() {
        setZoom(1.0)
    }

    /// Shows grok.com if needed, then clicks the site's Voice Mode control.
    /// grok.com has no public deep link, so this finds the labeled button the
    /// same way we tag "New Chat": visible text / aria-label, not hashed classes.
    func startVoiceChat() {
        MicPermission.request()
        voiceStartToken += 1
        let token = voiceStartToken
        if !isOnGrok {
            webView.load(URLRequest(url: Self.homeURL))
        }
        webView.window?.makeKey()
        webView.window?.makeFirstResponder(webView)
        Task { @MainActor [weak self] in
            await self?.attemptVoiceStart(token: token)
        }
    }

    func stopVoiceChat() {
        voiceStartToken += 1
        isVoiceActive = false
        pressEscape()
        Task { @MainActor [weak self] in
            await self?.clickEndVoiceButton()
        }
    }

    func toggleVoiceChat() {
        if isVoiceActive {
            stopVoiceChat()
        } else {
            startVoiceChat()
        }
    }

    private func setZoom(_ value: Double) {
        webView.pageZoom = min(max(value, 0.5), 3.0)
        zoomPercent = Int((webView.pageZoom * 100).rounded())
        UserDefaults.standard.set(webView.pageZoom, forKey: Self.zoomDefaultsKey)
    }

    // MARK: - Voice

    private var isOnGrok: Bool {
        guard let host = webView.url?.host()?.lowercased() else { return false }
        return host == "grok.com" || host.hasSuffix(".grok.com")
    }

    private enum VoiceProbe {
        case alreadyOpen
        case found(CGPoint)
        case missing
    }

    private func attemptVoiceStart(token: Int) async {
        if case .alreadyOpen = await probeVoiceUI() {
            isVoiceActive = true
            return
        }

        voiceHoldUntil = Date().addingTimeInterval(4)

        for _ in 0..<16 {
            guard token == voiceStartToken else { return }
            switch await probeVoiceUI() {
            case .alreadyOpen:
                isVoiceActive = true
                return
            case .found:
                await clickVoiceButtonInPage()
                isVoiceActive = true
                return
            case .missing:
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        await clickVoiceButtonInPage()
        isVoiceActive = true
    }

    private func probeVoiceUI() async -> VoiceProbe {
        guard let result = try? await webView.evaluateJavaScript(Self.voiceProbeScript) as? [String: Any],
              let status = result["status"] as? String else {
            return .missing
        }
        if status == "already" { return .alreadyOpen }
        if status == "found",
           let x = (result["x"] as? NSNumber)?.doubleValue,
           let y = (result["y"] as? NSNumber)?.doubleValue {
            return .found(CGPoint(x: x, y: y))
        }
        return .missing
    }

    private func clickVoiceButtonInPage() async {
        _ = try? await webView.evaluateJavaScript(Self.voiceClickScript)
    }

    /// grok.com binds Voice Mode to ⌘⇧O. Synthesize that so we don't depend
    /// on hashed classes or an accessible name that isn't in the DOM.
    private func pressSiteVoiceShortcut() {
        guard let window = webView.window else { return }
        window.makeKey()
        window.makeFirstResponder(webView)
        let now = ProcessInfo.processInfo.systemUptime
        func keyEvent(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: now,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "o",
                charactersIgnoringModifiers: "o",
                isARepeat: false,
                keyCode: UInt16(kVK_ANSI_O)
            )
        }
        if let down = keyEvent(.keyDown) {
            webView.keyDown(with: down)
        }
        if let up = keyEvent(.keyUp) {
            webView.keyUp(with: up)
        }
    }

    private func pressEscape() {
        guard let window = webView.window else { return }
        window.makeFirstResponder(webView)
        let now = ProcessInfo.processInfo.systemUptime
        func keyEvent(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: now,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: UInt16(kVK_Escape)
            )
        }
        if let down = keyEvent(.keyDown) { webView.keyDown(with: down) }
        if let up = keyEvent(.keyUp) { webView.keyUp(with: up) }
    }

    private func clickEndVoiceButton() async {
        _ = try? await webView.evaluateJavaScript(Self.voiceEndScript)
    }

    private func startVoicePolling() {
        Task { @MainActor [weak self] in
            while let self {
                try? await Task.sleep(nanoseconds: 700_000_000)
                if Date() < self.voiceHoldUntil { continue }
                switch await self.probeVoiceUI() {
                case .alreadyOpen:
                    if !self.isVoiceActive { self.isVoiceActive = true }
                case .found:
                    if self.isVoiceActive { self.isVoiceActive = false }
                case .missing:
                    break
                }
            }
        }
    }

    // Synthesized click in view coordinates so getUserMedia sees a real
    // mouse event. JS .click() is not a user gesture and can fail the first
    // time the site asks for the microphone.
    private func clickWebContent(atCSSPoint cssPoint: CGPoint) {
        guard let window = webView.window else { return }
        let zoom = webView.pageZoom
        let viewPoint = NSPoint(x: cssPoint.x * zoom, y: cssPoint.y * zoom)
        let locationInWindow = webView.convert(viewPoint, to: nil)
        let now = ProcessInfo.processInfo.systemUptime

        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: now,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: now + 0.03,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        )
        if let down { window.sendEvent(down) }
        if let up { window.sendEvent(up) }
    }

    // Status: "already" | "found" | "missing". Found includes CSS-pixel
    // center of the Voice Mode control (not the dictation microphone).
    private static let voiceProbeScript = """
    (function () {
        function labelledBy(el) {
            const ids = (el.getAttribute('aria-labelledby') || '').trim();
            if (!ids) { return ''; }
            return ids.split(/\\s+/).map(function (id) {
                const n = document.getElementById(id);
                return n ? (n.textContent || '') : '';
            }).join(' ');
        }
        function text(el) {
            return ((el.getAttribute('aria-label') || '') + ' '
                + labelledBy(el) + ' '
                + (el.getAttribute('title') || '') + ' '
                + (el.getAttribute('data-tooltip') || '') + ' '
                + (el.getAttribute('aria-keyshortcuts') || '') + ' '
                + (el.textContent || '')).replace(/\\s+/g, ' ').trim().toLowerCase();
        }
        function visible(el) {
            const r = el.getBoundingClientRect();
            if (r.width < 4 || r.height < 4) { return false; }
            const st = getComputedStyle(el);
            if (st.visibility === 'hidden' || st.display === 'none' || Number(st.opacity) === 0) {
                return false;
            }
            return true;
        }
        function isVoiceModeLabel(l) {
            if (!l) { return false; }
            if (/(dictat|speech.to.text|voice input|use microphone|voicemail)/.test(l)) { return false; }
            if (/enter voice|voice mode|start voice|start voice mode/.test(l)) { return true; }
            if (/meta\\+shift\\+o|cmd\\+shift\\+o|command\\+shift\\+o/.test(l)) { return true; }
            if (l === 'voice' || (/\\bvoice\\b/.test(l) && l.length < 28)) { return true; }
            return false;
        }
        function isEndVoiceLabel(l) {
            return /(end|stop|leave|exit|close)\\s+(voice|call|session)/.test(l)
                || /leave voice|exit voice|end voice|close voice/.test(l);
        }
        const nodes = Array.from(document.querySelectorAll('button, a, [role="button"], [aria-keyshortcuts]')).filter(visible);
        const labels = nodes.map(text);
        if (labels.some(isEndVoiceLabel) || (labels.some(l => l === 'mute' || l === 'unmute') && labels.some(l => /voice|end/.test(l)))) {
            return { status: 'already' };
        }
        let el = nodes.find(n => isVoiceModeLabel(text(n)));
        if (!el) {
            const input = document.querySelector('textarea, [contenteditable="true"]');
            let root = input && (input.closest('form') || input.parentElement);
            for (let i = 0; i < 8 && root && !el; i++) {
                el = Array.from(root.querySelectorAll('button, [role="button"]'))
                    .filter(visible)
                    .find(n => isVoiceModeLabel(text(n)));
                root = root.parentElement;
            }
        }
        if (!el) { return { status: 'missing' }; }
        const r = el.getBoundingClientRect();
        return { status: 'found', x: r.x + r.width / 2, y: r.y + r.height / 2 };
    })();
    """

    private static let voiceClickScript = """
    (function () {
        function labelledBy(el) {
            const ids = (el.getAttribute('aria-labelledby') || '').trim();
            if (!ids) { return ''; }
            return ids.split(/\\s+/).map(function (id) {
                const n = document.getElementById(id);
                return n ? (n.textContent || '') : '';
            }).join(' ');
        }
        function text(el) {
            return ((el.getAttribute('aria-label') || '') + ' '
                + labelledBy(el) + ' '
                + (el.getAttribute('title') || '') + ' '
                + (el.getAttribute('aria-keyshortcuts') || '') + ' '
                + (el.textContent || '')).replace(/\\s+/g, ' ').trim().toLowerCase();
        }
        function visible(el) {
            const r = el.getBoundingClientRect();
            return r.width >= 4 && r.height >= 4;
        }
        function isVoiceModeLabel(l) {
            if (!l) { return false; }
            if (/(dictat|speech.to.text|voice input|use microphone|voicemail)/.test(l)) { return false; }
            if (/enter voice|voice mode|start voice/.test(l)) { return true; }
            if (/meta\\+shift\\+o|cmd\\+shift\\+o/.test(l)) { return true; }
            if (l === 'voice' || (/\\bvoice\\b/.test(l) && l.length < 28)) { return true; }
            return false;
        }
        const nodes = Array.from(document.querySelectorAll('button, a, [role="button"], [aria-keyshortcuts]'));
        const allow = nodes.find(n => /^allow all$/i.test(text(n).trim()));
        if (allow) { allow.click(); }
        const el = nodes.find(n => visible(n) && isVoiceModeLabel(text(n)));
        if (el) { el.click(); return 'clicked:' + text(el).slice(0, 60); }
        return 'not-found';
    })();
    """

    private static let voiceEndScript = """
    (function () {
        function text(el) {
            return ((el.getAttribute('aria-label') || '') + ' '
                + (el.getAttribute('title') || '') + ' '
                + (el.textContent || '')).replace(/\\s+/g, ' ').trim().toLowerCase();
        }
        function visible(el) {
            const r = el.getBoundingClientRect();
            return r.width >= 4 && r.height >= 4;
        }
        function isEnd(l) {
            return /(end|stop|leave|exit|close)\\s+(voice|call|session)/.test(l)
                || l === 'end call' || l === 'end' || l === 'hang up';
        }
        const nodes = Array.from(document.querySelectorAll('button, a, [role="button"]')).filter(visible);
        const el = nodes.find(n => isEnd(text(n)));
        if (el) { el.click(); return true; }
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, which: 27, bubbles: true }));
        return false;
    })();
    """

    // MARK: - Script messages

    fileprivate func handleScriptMessage(_ message: WKScriptMessage) {
        switch message.name {
        case "sidebarWidth":
            guard let width = message.body as? Double,
                  width > 0, width <= 500 else { return }
            sidebarCSSWidth = width
        default:
            break
        }
    }

    // MARK: - Host policy

    private func isInAppURL(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return Self.inAppHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}

// Tab identity is the live instance itself (ObjectIdentifier id).
extension WebViewModel: Identifiable {}

// The user content controller retains its message handlers, and the model
// retains the webview — this proxy breaks what would otherwise be a cycle.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var model: WebViewModel?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        model?.handleScriptMessage(message)
    }
}

// MARK: - WKNavigationDelegate

extension WebViewModel: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // mailto:, facetime:, etc. go to the system handler.
        if let scheme = url.scheme?.lowercased(), scheme != "http", scheme != "https" {
            if scheme != "about" && scheme != "blob" && scheme != "data" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
        }

        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }

        // Only user-clicked main-frame links leave the app; redirects,
        // subframes, and form posts must stay or OAuth flows break.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame ?? true,
           !isInAppURL(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }
}

// MARK: - WKUIDelegate

extension WebViewModel: WKUIDelegate {

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, !isInAppURL(url) {
            NSWorkspace.shared.open(url)
            return nil
        }

        // Auth popups (window.open from Google/Apple sign-in) need a real
        // child webview built from the provided configuration so the
        // opener/postMessage relationship survives.
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 640), configuration: configuration)
        popup.customUserAgent = Self.safariUserAgent
        popup.navigationDelegate = self
        popup.uiDelegate = self

        let window = NSWindow(
            contentRect: popup.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = popup
        window.title = "Grok"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        popupWindows.append(window)

        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let index = popupWindows.firstIndex(where: { $0.contentView === webView }) {
            popupWindows[index].close()
            popupWindows.remove(at: index)
        }
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true

        let respond: (NSApplication.ModalResponse) -> Void = { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(panel.runModal())
        }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let host = origin.host.lowercased()
        let trusted = Self.inAppHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
        decisionHandler(trusted ? .grant : .deny)
    }
}

// MARK: - WKDownloadDelegate

extension WebViewModel: WKDownloadDelegate {

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true

        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else {
                completionHandler(nil)
                return
            }
            // WKDownload refuses to overwrite; the save panel already
            // confirmed replacement with the user.
            try? FileManager.default.removeItem(at: url)
            self?.activeDownloads[download] = url
            completionHandler(url)
        }
        if let window = download.webView?.window ?? webView.window {
            panel.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(panel.runModal())
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = activeDownloads.removeValue(forKey: download) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        activeDownloads.removeValue(forKey: download)
        NSSound.beep()
    }
}
