//
//  AppleIntelligenceTTS.swift
//  Grok-macOS
//
//  Speaks Apple Intelligence / Siri voices (Voice 1, Voice 2, …).
//  AVSpeech cannot open these; SiriTTSSynthesisVoice must be created
//  with init(language:name:), not a bare init().
//

import Foundation
import ObjectiveC

@MainActor
final class AppleIntelligenceTTS: NSObject {

    static let shared = AppleIntelligenceTTS()

    private var session: NSObject?
    private var voice: NSObject?
    private var request: NSObject?
    private var pending: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var generation = 0
    private var loadedSiri = false

    @discardableResult
    func speak(_ text: String, language: String, name: String) async -> Bool {
        stop()
        let ok = await speakSiriDaemon(text: text, language: language, name: name)
        if !ok {
            CompanionDebug.log("siriTTS speak failed language=\(language) name=\(name)")
        }
        return ok
    }

    func stop() {
        generation += 1
        timeoutTask?.cancel()
        timeoutTask = nil
        if let session {
            session.perform(NSSelectorFromString("cancelWithRequest:"), with: request)
        }
        finish(false)
        session = nil
        request = nil
        voice = nil
    }

    private func finish(_ didSpeak: Bool) {
        timeoutTask?.cancel()
        timeoutTask = nil
        pending?.resume(returning: didSpeak)
        pending = nil
    }

    // MARK: - SiriTTSDaemonSession

    private func speakSiriDaemon(text: String, language: String, name: String) async -> Bool {
        guard loadSiri() else { return false }
        guard let request = makeSpeechRequest(text: text, language: language, name: name) else {
            CompanionDebug.log("siriTTS request nil language=\(language) name=\(name)")
            return false
        }
        guard let sessionClass = NSClassFromString("SiriTTSDaemonSession") as? NSObject.Type else {
            return false
        }
        let session = sessionClass.init()
        session.setValue(true, forKey: "keepActive")
        self.session = session
        self.request = request
        CompanionDebug.log("siriTTS daemon speak language=\(language) name=\(name)")

        generation += 1
        let token = generation
        let seconds = min(90, max(12, Double(text.count) / 11.0 + 6))
        CompanionDebug.log("siriTTS timeout budget \(Int(seconds))s for \(text.count) chars")

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pending = continuation
            let sel = NSSelectorFromString("speakWithSpeechRequest:didFinish:")
            guard let imp = class_getMethodImplementation(object_getClass(session), sel) else {
                CompanionDebug.log("siriTTS no speak selector")
                finish(false)
                return
            }
            let block: @convention(block) (NSError?) -> Void = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if let error {
                        CompanionDebug.log("siriTTS daemon error \(error.localizedDescription)")
                        self.finish(false)
                    } else {
                        CompanionDebug.log("siriTTS daemon ok")
                        self.finish(true)
                    }
                }
            }
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
            unsafeBitCast(imp, to: Fn.self)(session, sel, request, unsafeBitCast(block, to: AnyObject.self))
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled, let self, self.generation == token, self.pending != nil else { return }
                CompanionDebug.log("siriTTS daemon timeout after \(Int(seconds))s")
                self.finish(true)
            }
        }
    }

    private func makeSpeechRequest(text: String, language: String, name: String) -> NSObject? {
        guard
            let voice = allocInit(
                "SiriTTSSynthesisVoice",
                selector: "initWithLanguage:name:",
                language,
                name
            )
        else { return nil }
        self.voice = voice
        CompanionDebug.log("siriTTS voice \(voice) language=\(voice.value(forKey: "language") ?? "?") name=\(voice.value(forKey: "name") ?? "?")")

        guard
            let request = allocInit(
                "SiriTTSSpeechRequest",
                selector: "initWithText:voice:",
                text,
                voice
            )
        else { return nil }
        request.setValue(true, forKey: "disableCompactVoice")
        request.setValue(1.0, forKey: "volume")
        return request
    }

    // MARK: - Runtime

    private func allocInit(_ className: String, selector: String, _ a: Any, _ b: Any) -> NSObject? {
        guard let cls = NSClassFromString(className) else {
            CompanionDebug.log("siriTTS missing class \(className)")
            return nil
        }
        guard let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject else {
            CompanionDebug.log("siriTTS alloc failed \(className)")
            return nil
        }
        guard let initialized = allocated.perform(NSSelectorFromString(selector), with: a, with: b)?.takeRetainedValue() as? NSObject else {
            CompanionDebug.log("siriTTS \(selector) failed \(className)")
            return nil
        }
        return initialized
    }

    private func loadSiri() -> Bool {
        if loadedSiri { return NSClassFromString("SiriTTSDaemonSession") != nil }
        loadedSiri = loadFramework("/System/Library/PrivateFrameworks/SiriTTSService.framework")
        return loadedSiri && NSClassFromString("SiriTTSDaemonSession") != nil
    }

    private func loadFramework(_ path: String) -> Bool {
        var error: Unmanaged<CFError>?
        let ok = CFBundleLoadExecutableAndReturnError(
            CFBundleCreate(kCFAllocatorDefault, URL(fileURLWithPath: path) as CFURL),
            &error
        )
        if !ok {
            CompanionDebug.log("siriTTS load \(path) failed \(String(describing: error))")
        }
        return ok
    }

    static func parts(for identifier: String) -> (language: String, name: String)? {
        let prefixes = [
            "com.apple.siri.natural.",
            "com.apple.siri.neural.",
            "com.apple.siri.gryphon.",
            "com.apple.speech.synthesis.voice.custom.siri.",
        ]
        for prefix in prefixes where identifier.hasPrefix(prefix) {
            let name = String(identifier.dropFirst(prefix.count))
            return (language(fromName: name), name)
        }
        return nil
    }

    static func language(fromName name: String) -> String {
        let pieces = name.split(separator: "-")
        if pieces.count >= 2, pieces[0].count == 2, pieces[1].count == 2 {
            return "\(pieces[0])-\(pieces[1])"
        }
        return SystemVoice.catalog.first(where: { $0.identifier.hasSuffix(".\(name)") })?.language
            ?? Locale.autoupdatingCurrent.identifier
    }

    static func customSiriIdentifier(for identifier: String) -> String? {
        guard let parts = parts(for: identifier) else { return nil }
        return "com.apple.speech.synthesis.voice.custom.siri.\(parts.name)"
    }
}
