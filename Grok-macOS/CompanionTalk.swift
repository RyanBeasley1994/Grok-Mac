//
//  CompanionTalk.swift
//  Grok-macOS
//
//  Experimental companion voice: Mac dictation → Grok CLI session →
//  Mac text-to-speech. The CLI keeps full computer access; only the
//  spoken reply is constrained to conversation.
//

import AVFoundation
import Foundation
import Speech

@MainActor
final class CompanionTalk: ObservableObject {

    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking

        var label: String {
            switch self {
            case .idle: return "idle"
            case .listening: return "listening"
            case .thinking: return "asking Grok CLI"
            case .speaking: return "speaking"
            }
        }
    }

    @Published private(set) var isActive = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var lastHeard: String?
    @Published private(set) var debugLine = "idle"

    private let speaker = CompanionSpeaker()
    private let cli = GrokCLIClient()
    private var loop: Task<Void, Never>?
    private var listenSession: DictationSession?
    private var conversationID: String?

    func start() {
        CompanionDebug.log("talk.start alreadyActive=\(isActive)")
        if isActive { stop() }
        lastError = nil
        lastHeard = nil
        conversationID = nil
        isActive = true
        setPhase(.listening, "starting")
        MicPermission.request()
        Task { [weak self] in
            await self?.cli.prepare()
        }
        loop = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func prewarm() {
        Task { [weak self] in
            CompanionDebug.log("talk.prewarm")
            await self?.cli.prepare()
        }
    }

    func shutdownWarm() {
        cli.reset()
    }

    func stop() {
        CompanionDebug.log("talk.stop phase=\(phase.label)")
        loop?.cancel()
        loop = nil
        listenSession?.cancel()
        listenSession = nil
        conversationID = nil
        speaker.stop()
        isActive = false
        setPhase(.idle, "stopped")
        Task { [weak self] in
            await self?.cli.recycleConversation()
        }
    }

    private func setPhase(_ next: Phase, _ detail: String) {
        phase = next
        debugLine = "\(next.label) — \(detail)"
        CompanionDebug.log("talk.phase \(debugLine)")
    }

    private func runLoop() async {
        CompanionDebug.log("talk.loop begin")
        CompanionDebug.log("talk.binary \(GrokCLI.resolveBinary()?.path ?? "MISSING")")
        CompanionDebug.log("talk.customPath \(GrokCLI.customPath.isEmpty ? "(default)" : GrokCLI.customPath)")

        let speech = await SpeechPermission.request()
        CompanionDebug.log("talk.speech status=\(speech.rawValue) label=\(SpeechPermission.label)")
        guard !Task.isCancelled, isActive else {
            CompanionDebug.log("talk.loop cancelled after speech auth")
            return
        }
        guard speech == .authorized else {
            lastError = "Speech recognition isn’t allowed."
            CompanionDebug.log("talk.speech DENIED")
            failAndStop("I need speech recognition to hear you. Allow it in Settings.")
            return
        }

        let mic = await MicPermission.request()
        CompanionDebug.log("talk.mic granted=\(mic) status=\(MicPermission.status.rawValue) label=\(MicPermission.label)")
        guard !Task.isCancelled, isActive else {
            CompanionDebug.log("talk.loop cancelled after mic auth")
            return
        }
        guard mic else {
            lastError = "Microphone isn’t allowed."
            CompanionDebug.log("talk.mic DENIED")
            failAndStop("I need the microphone to hear you. Allow it in Settings.")
            return
        }

        if GrokCLI.resolveBinary() == nil {
            lastError = GrokCLI.CLIError.notFound.localizedDescription
            CompanionDebug.log("talk.binary missing — will not start listen loop")
            failAndStop(GrokCLI.CLIError.notFound.localizedDescription)
            return
        }

        // Brief gap so the wake-word tap can drop the mic.
        CompanionDebug.log("talk.wait for wake-word mic release")
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard !Task.isCancelled, isActive else {
            CompanionDebug.log("talk.loop cancelled during mic wait")
            return
        }

        var turn = 0
        while !Task.isCancelled, isActive {
            turn += 1
            setPhase(.listening, "turn \(turn)")
            let heard: String
            do {
                heard = try await listenOnce()
            } catch is CancellationError {
                CompanionDebug.log("talk.listen cancelled turn=\(turn)")
                break
            } catch {
                CompanionDebug.log("talk.listen ERROR turn=\(turn) \(error.localizedDescription)")
                lastError = error.localizedDescription
                try? await Task.sleep(nanoseconds: 400_000_000)
                continue
            }

            guard !Task.isCancelled, isActive else { break }
            if heard.isEmpty {
                CompanionDebug.log("talk.listen empty turn=\(turn) — listening again")
                continue
            }

            lastHeard = heard
            CompanionDebug.log("talk.heard turn=\(turn) “\(heard)”")
            setPhase(.thinking, "replying to “\(heard)”")
            let spokenSoFar = SpokenAccumulator()
            let filler = Task { [speaker] in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                guard !Task.isCancelled else { return }
                let line = WorkingLine.next()
                CompanionDebug.log("talk.working “\(line)”")
                await speaker.speak(line)
            }
            do {
                let spoken = try await cli.askSpoken(transcript: heard, sessionID: conversationID) { [speaker] partial in
                    Task { @MainActor in
                        guard spokenSoFar.text.isEmpty, let sentence = SpokenText.firstSentence(partial) else { return }
                        spokenSoFar.text = sentence
                        filler.cancel()
                        CompanionDebug.log("talk.partial “\(sentence)”")
                        speaker.stop()
                        await speaker.speak(sentence)
                    }
                }
                CompanionDebug.log("talk.spoken session=\(spoken.sessionID ?? "none") chars=\(spoken.text.count) “\(spoken.text.prefix(160))”")
                if let id = spoken.sessionID { conversationID = id }
                filler.cancel()
                guard !Task.isCancelled, isActive else { break }
                let firstRaw = spoken.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let first = firstRaw.isEmpty ? "Okay." : SpokenText.clean(spoken.text)
                let leftover = SpokenText.leftover(full: first, alreadySaid: spokenSoFar.text)
                setPhase(.speaking, "reply \(leftover.count) chars")
                speaker.stop()
                if leftover.isEmpty, spokenSoFar.text.isEmpty {
                    await speaker.speak(first)
                } else if !leftover.isEmpty {
                    await speaker.speak(leftover)
                }
                CompanionDebug.log("talk.spoke turn=\(turn)")
            } catch is CancellationError {
                filler.cancel()
                speaker.stop()
                CompanionDebug.log("talk.cli cancelled turn=\(turn)")
                break
            } catch {
                filler.cancel()
                speaker.stop()
                CompanionDebug.log("talk.cli ERROR turn=\(turn) \(error.localizedDescription)")
                lastError = error.localizedDescription
                guard !Task.isCancelled, isActive else { break }
                setPhase(.speaking, "error")
                await speaker.speak(spokenError(error))
            }
        }
        CompanionDebug.log("talk.loop end active=\(isActive) cancelled=\(Task.isCancelled)")
    }

    private func listenOnce() async throws -> String {
        CompanionDebug.log("talk.listenOnce begin")
        let session = DictationSession()
        listenSession = session
        defer {
            if listenSession === session { listenSession = nil }
        }
        let text = try await session.capture()
        CompanionDebug.log("talk.listenOnce end “\(text)”")
        return text
    }

    private func failAndStop(_ spoken: String) {
        CompanionDebug.log("talk.failAndStop “\(spoken)”")
        Task { [weak self] in
            guard let self, self.isActive else { return }
            self.setPhase(.speaking, "startup error")
            await self.speaker.speak(spoken)
            self.stop()
        }
    }

    private func spokenError(_ error: Error) -> String {
        if error is CancellationError { return "" }
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("login") || text.localizedCaseInsensitiveContains("auth") {
            return "I need you to sign in to the Grok CLI first."
        }
        if text.localizedCaseInsensitiveContains("wasn’t found") || text.localizedCaseInsensitiveContains("not found") {
            return "I can’t find the Grok command. Install the Grok CLI, or set its path in Settings."
        }
        if text.localizedCaseInsensitiveContains("scheduler") || text.localizedCaseInsensitiveContains("requirements") {
            return "I couldn’t start a Grok session. Try again in a moment."
        }
        return "Sorry, I hit a problem talking to Grok."
    }
}

private final class SpokenAccumulator {
    var text = ""
}

/// Short lines spoken immediately so the user hears something while the CLI works.
private enum WorkingLine {
    private static let lines = [
        "On it.",
        "Give me a second.",
        "Let me look into that.",
        "Working on it.",
        "One moment.",
        "Yeah, hang on.",
        "I’ll get that for you.",
        "Just a sec.",
        "Let me sort that.",
        "I’m on it now.",
        "Checking that.",
        "Leave it with me.",
        "Right, I’m looking.",
        "Give me a tick.",
        "I’m on the case.",
        "Let me see.",
        "Coming right up.",
        "Hold on.",
        "I’ll take care of that.",
        "Looking that up.",
    ]
    private static var last = -1

    static func next() -> String {
        var index = Int.random(in: 0..<lines.count)
        if index == last, lines.count > 1 {
            index = (index + 1) % lines.count
        }
        last = index
        return lines[index]
    }
}

// MARK: - Dictation

@MainActor
private final class DictationSession {

    enum ListenError: LocalizedError {
        case unavailable
        case noMicrophone

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Speech recognition isn’t available."
            case .noMicrophone:
                return "No microphone is available."
            }
        }
    }

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var continuation: CheckedContinuation<String, Error>?
    private var lastText = ""
    private var lastChange = Date()
    private var silenceTask: Task<Void, Never>?
    private var settled = false

    private var heartbeat: Task<Void, Never>?
    private static let fillers: Set<String> = ["um", "uh", "hmm", "hm", "ah", "er", "eh", "mm"]
    private static let silence: TimeInterval = 0.45

    func cancel() {
        CompanionDebug.log("dictation.cancel lastText=\(lastText.isEmpty ? "(empty)" : lastText)")
        finish(with: .success(""))
    }

    func capture() async throws -> String {
        CompanionDebug.log("dictation.capture")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.begin()
            }
        } onCancel: {
            Task { @MainActor in
                CompanionDebug.log("dictation.capture cancelled")
                self.finish(with: .failure(CancellationError()))
            }
        }
    }

    private func begin() {
        guard let recognizer = makeRecognizer() else {
            CompanionDebug.log("dictation.recognizer unavailable")
            finish(with: .failure(ListenError.unavailable))
            return
        }
        self.recognizer = recognizer
        CompanionDebug.log("dictation.recognizer locale=\(recognizer.locale.identifier) available=\(recognizer.isAvailable) onDevice=\(recognizer.supportsOnDeviceRecognition)")

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = ["Grok", "xAI"]
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        CompanionDebug.log("dictation.request onDevice=\(request.requiresOnDeviceRecognition)")
        if #available(macOS 14.0, *) {
            request.taskHint = .dictation
        }
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        CompanionDebug.log("dictation.mic rate=\(format.sampleRate) channels=\(format.channelCount)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            CompanionDebug.log("dictation.mic invalid format")
            finish(with: .failure(ListenError.noMicrophone))
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
            CompanionDebug.log("dictation.engine running=\(audioEngine.isRunning)")
        } catch {
            CompanionDebug.log("dictation.engine START FAILED \(error.localizedDescription)")
            finish(with: .failure(error))
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handle(result: result, error: error)
            }
        }
        armHeartbeat()
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        guard !settled else { return }

        if let result {
            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            CompanionDebug.log("dictation.partial final=\(result.isFinal) “\(text)”")
            if text != lastText {
                lastText = text
                lastChange = Date()
                armSilenceTimer()
            }
            if result.isFinal {
                CompanionDebug.log("dictation.final “\(text)”")
                finish(with: .success(usable(text)))
                return
            }
        }

        if let error {
            let ns = error as NSError
            CompanionDebug.log("dictation.error domain=\(ns.domain) code=\(ns.code) \(error.localizedDescription)")
            if ns.domain == "kAFAssistantErrorDomain", [203, 216, 1110, 1101].contains(ns.code) {
                finish(with: .success(usable(lastText)))
                return
            }
            if lastText.isEmpty {
                finish(with: .failure(error))
            } else {
                finish(with: .success(usable(lastText)))
            }
        }
    }

    private func armSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            let nanos = UInt64(Self.silence * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            if Date().timeIntervalSince(self.lastChange) >= Self.silence - 0.05 {
                CompanionDebug.log("dictation.silence “\(self.lastText)”")
                self.finish(with: .success(self.usable(self.lastText)))
            }
        }
    }

    private func armHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self, !self.settled else { return }
                ticks += 5
                CompanionDebug.log("dictation.waiting \(ticks)s lastText=\(self.lastText.isEmpty ? "(none)" : self.lastText) engine=\(self.audioEngine.isRunning)")
            }
        }
    }

    private func usable(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let folded = trimmed.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        let tokens = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if tokens.isEmpty { return "" }
        if tokens.allSatisfy({ Self.fillers.contains($0) }) { return "" }
        return trimmed
    }

    private func finish(with result: Result<String, Error>) {
        guard !settled else { return }
        settled = true
        switch result {
        case .success(let text):
            CompanionDebug.log("dictation.finish success “\(text)”")
        case .failure(let error):
            CompanionDebug.log("dictation.finish failure \(error.localizedDescription)")
        }
        heartbeat?.cancel()
        heartbeat = nil
        silenceTask?.cancel()
        silenceTask = nil
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
        continuation?.resume(with: result)
        continuation = nil
    }

    private func makeRecognizer() -> SFSpeechRecognizer? {
        var candidates: [Locale] = [
            Locale.autoupdatingCurrent,
            Locale(identifier: "en-US"),
            Locale(identifier: "en-GB"),
        ]
        candidates.append(contentsOf: SFSpeechRecognizer.supportedLocales())
        var seen = Set<String>()
        for locale in candidates {
            guard seen.insert(locale.identifier).inserted else { continue }
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { continue }
            return recognizer
        }
        return nil
    }
}
