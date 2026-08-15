//
//  WakeWordListener.swift
//  Grok-macOS
//
//  Always-on, on-device listener for “Hey Grok”. Never falls back to
//  network recognition. Stops the audio tap while grok.com voice owns
//  the mic, then resumes.
//

import AppKit
import AVFoundation
import Foundation
import os
import Speech

private let wakeLog = Logger(subsystem: "com.nhershy.Grok-macOS", category: "WakeWord")

@MainActor
final class WakeWordListener {

    enum Status: Equatable {
        case off
        case starting
        case listening
        case paused
        case denied
        case unavailable
        case failed(String)

        var caption: String {
            switch self {
            case .off:
                return "Say “Hey Grok” to start voice without the keyboard. The microphone stays on while this is enabled."
            case .starting:
                return "Starting listener…"
            case .listening:
                return "Listening for “Hey Grok”. macOS will show the mic indicator while this is on."
            case .paused:
                return "Paused while voice chat is using the microphone."
            case .denied:
                return "Needs microphone and speech recognition access. Enable both in System Settings → Privacy & Security, then toggle this again."
            case .unavailable:
                return "On-device speech recognition isn’t available. Turn on Dictation in System Settings → Keyboard, then toggle this again."
            case .failed(let message):
                return message
            }
        }
    }

    var onTrigger: (() -> Void)?
    var onStatusChange: ((Status) -> Void)?

    private(set) var status: Status = .off {
        didSet {
            guard oldValue != status else { return }
            wakeLog.info("status \(String(describing: oldValue), privacy: .public) → \(String(describing: self.status), privacy: .public)")
            onStatusChange?(status)
        }
    }

    private var enabled = false
    private var voiceActive = false
    private var sessionID = UUID()
    private var holdOffUntil = Date.distantPast
    private var wasVoiceActive = false
    private var tapInstalled = false
    private var lastTranscript = ""

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private static let prefixes: Set<String> = ["hey", "ok", "okay", "hi", "yo"]
    private static let grokTokens: Set<String> = [
        "grok", "grock", "groc", "grog", "groq", "groke", "gronk",
    ]
    private static let fused: Set<String> = [
        "heygrok", "heygrock", "okgrok", "okaygrok", "higrok",
    ]

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEngineConfigChange() }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryIfNeeded() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEngineConfigChange() }
        })
    }

    func sync(enabled: Bool, voiceActive: Bool) {
        if wasVoiceActive && !voiceActive {
            holdOffUntil = max(holdOffUntil, Date().addingTimeInterval(0.8))
        }
        wasVoiceActive = voiceActive
        self.enabled = enabled
        self.voiceActive = voiceActive
        apply(forceRestart: false)
    }

    private func apply(forceRestart: Bool) {
        if !enabled {
            tearDown(status: .off)
            return
        }
        if voiceActive {
            holdOffUntil = Date.distantPast
            tearDown(status: .paused)
            return
        }
        if Date() < holdOffUntil {
            tearDown(status: .paused)
            scheduleRestart(after: holdOffUntil.timeIntervalSinceNow, forceRestart: false)
            return
        }
        if forceRestart {
            beginSession()
        } else {
            startListening()
        }
    }

    private func startListening() {
        guard enabled, !voiceActive else { return }
        if audioEngine.isRunning, status == .listening { return }
        if status == .starting { return }
        status = .starting
        Task { await self.prepareAndListen() }
    }

    private func prepareAndListen() async {
        guard enabled, !voiceActive else { return }

        let speech = await SpeechPermission.request()
        guard enabled, !voiceActive else { return }
        guard speech == .authorized else {
            wakeLog.error("speech auth \(speech.rawValue)")
            tearDown(status: .denied)
            return
        }

        let mic = await MicPermission.request()
        guard enabled, !voiceActive else { return }
        guard mic else {
            wakeLog.error("mic denied")
            tearDown(status: .denied)
            return
        }

        guard let recognizer = makeRecognizer() else {
            wakeLog.error("on-device recognizer unavailable")
            tearDown(status: .unavailable)
            return
        }
        self.recognizer = recognizer
        beginSession()
    }

    private func beginSession() {
        guard enabled, !voiceActive, Date() >= holdOffUntil else { return }
        stopSession()

        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            tearDown(status: .unavailable)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = false
        request.contextualStrings = ["hey grok", "hey Grok", "Grok", "ok grok"]
        if #available(macOS 14.0, *) {
            request.taskHint = .unspecified
        }
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            tearDown(status: .failed("No microphone is available."))
            return
        }

        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true

        sessionID = UUID()
        let id = sessionID
        lastTranscript = ""

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            wakeLog.error("engine start failed \(error.localizedDescription, privacy: .public)")
            tearDown(status: .failed("Couldn’t start the microphone: \(error.localizedDescription)"))
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handle(result: result, error: error, session: id)
            }
        }

        status = .listening
        wakeLog.info("listening locale=\(recognizer.locale.identifier, privacy: .public)")
        scheduleRestart(after: 45, forceRestart: true)
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, session: UUID) {
        guard session == sessionID, enabled, !voiceActive else { return }

        if let result {
            let text = result.bestTranscription.formattedString
            if text != lastTranscript {
                lastTranscript = text
                wakeLog.debug("heard \(text, privacy: .public)")
            }
            if Self.containsWakePhrase(text) {
                fire()
                return
            }
            if result.isFinal {
                scheduleRestart(after: 0.2, forceRestart: true)
                return
            }
        }

        if let error {
            let ns = error as NSError
            // 216/203/1110: cancelled, no speech, or the 1-minute cap. Restart.
            if ns.domain == "kAFAssistantErrorDomain", [203, 216, 1110, 1101].contains(ns.code) {
                scheduleRestart(after: 0.25, forceRestart: true)
                return
            }
            wakeLog.error("error \(ns.domain, privacy: .public) \(ns.code) \(error.localizedDescription, privacy: .public)")
            scheduleRestart(after: 0.6, forceRestart: true)
        }
    }

    private func fire() {
        wakeLog.info("trigger")
        holdOffUntil = Date().addingTimeInterval(8)
        tearDown(status: .paused)
        onTrigger?()
    }

    private func scheduleRestart(after delay: TimeInterval, forceRestart: Bool) {
        restartTask?.cancel()
        let id = sessionID
        restartTask = Task { [weak self] in
            let nanos = UInt64(max(delay, 0) * 1_000_000_000)
            if nanos > 0 {
                try? await Task.sleep(nanoseconds: nanos)
            }
            guard !Task.isCancelled, let self, self.sessionID == id else { return }
            self.apply(forceRestart: forceRestart)
        }
    }

    private func stopSession() {
        restartTask?.cancel()
        restartTask = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    private func tearDown(status: Status) {
        sessionID = UUID()
        stopSession()
        self.status = status
    }

    private func handleEngineConfigChange() {
        guard enabled, !voiceActive else { return }
        scheduleRestart(after: 0.4, forceRestart: true)
    }

    private func retryIfNeeded() {
        guard enabled, !voiceActive else { return }
        if status == .denied || status == .unavailable {
            startListening()
        }
    }

    private func makeRecognizer() -> SFSpeechRecognizer? {
        var candidates: [Locale] = [
            Locale.autoupdatingCurrent,
            Locale(identifier: "en-US"),
            Locale(identifier: "en-GB"),
        ]
        candidates.append(contentsOf: SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier })

        var seen = Set<String>()
        for locale in candidates {
            let key = locale.identifier
            guard seen.insert(key).inserted else { continue }
            guard let recognizer = SFSpeechRecognizer(locale: locale) else { continue }
            if recognizer.isAvailable && recognizer.supportsOnDeviceRecognition {
                return recognizer
            }
        }
        return nil
    }

    static func containsWakePhrase(_ text: String) -> Bool {
        let tokens = tokens(in: text)
        if tokens.contains(where: { fused.contains($0) }) { return true }
        guard tokens.count >= 2 else { return false }
        let window = tokens.suffix(8)
        var previous: String?
        for token in window {
            if let previous, prefixes.contains(previous), grokTokens.contains(token) {
                return true
            }
            previous = token
        }
        return false
    }

    private static func tokens(in text: String) -> [String] {
        let folded = text.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        var current = ""
        var tokens: [String] = []
        for character in folded {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
