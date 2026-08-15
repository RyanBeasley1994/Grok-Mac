//
//  SystemVoice.swift
//  Grok-macOS
//
//  macOS voices for companion text-to-speech. AVSpeech omits Siri voices;
//  those are loaded from SiriTTSService and spoken with NSSpeechSynthesizer.
//

import AppKit
import AVFoundation
import Foundation

struct SystemVoice: Identifiable, Hashable {
    enum Kind: String {
        case system
        case siri
    }

    var id: String { identifier }
    let identifier: String
    let name: String
    let language: String
    let kind: Kind

    var menuLabel: String {
        if kind == .siri {
            return "\(displayLanguage) — \(name)"
        }
        return "\(name) — \(displayLanguage)"
    }

    var displayLanguage: String {
        Locale.current.localizedString(forIdentifier: language) ?? language
    }

    static let defaultsKey = "companionVoiceIdentifier"

    static var selectedIdentifier: String {
        get { UserDefaults.standard.string(forKey: defaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static var resolvedIdentifier: String {
        let stored = selectedIdentifier
        if stored.isEmpty { return systemDefaultIdentifier }
        return stored
    }

    static var usesAppleIntelligence: Bool {
        AppleIntelligenceTTS.parts(for: resolvedIdentifier) != nil
    }

    static var usesMacSpeechChannel: Bool {
        let id = resolvedIdentifier
        if usesAppleIntelligence { return false }
        if id.contains(".custom.siri.") || id.contains(".siri.") { return true }
        return AVSpeechSynthesisVoice(identifier: id) == nil
    }

    static var catalog: [SystemVoice] {
        var byID: [String: SystemVoice] = [:]

        for voice in AVSpeechSynthesisVoice.speechVoices() {
            byID[voice.identifier] = SystemVoice(
                identifier: voice.identifier,
                name: voice.name,
                language: voice.language,
                kind: .system
            )
        }

        for voiceName in NSSpeechSynthesizer.availableVoices {
            let identifier = voiceName.rawValue
            if byID[identifier] != nil { continue }
            let attrs = NSSpeechSynthesizer.attributes(forVoice: voiceName)
            let name = attrs[NSSpeechSynthesizer.VoiceAttributeKey.name] as? String ?? identifier
            let language = attrs[NSSpeechSynthesizer.VoiceAttributeKey.localeIdentifier] as? String ?? ""
            byID[identifier] = SystemVoice(
                identifier: identifier,
                name: name,
                language: language,
                kind: identifier.contains(".siri") ? .siri : .system
            )
        }

        for voice in SiriVoiceCatalog.voices {
            byID[voice.identifier] = voice
        }

        return byID.values.sorted { lhs, rhs in
            if lhs.language != rhs.language {
                return preferredLanguageSort(lhs.language, rhs.language)
            }
            if lhs.kind != rhs.kind {
                return lhs.kind == .siri
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static var grouped: [(language: String, voices: [SystemVoice])] {
        let groups = Dictionary(grouping: catalog, by: \.displayLanguage)
        return groups.keys.sorted { preferredLanguageNameSort($0, $1) }.compactMap { name in
            guard let voices = groups[name] else { return nil }
            return (name, voices)
        }
    }

    static var systemDefaultIdentifier: String {
        if let raw = SpokenContentVoice.identifier {
            return SiriVoiceCatalog.canonicalIdentifier(raw)
        }
        let prefix = String(Locale.autoupdatingCurrent.identifier.prefix(2))
        return catalog.first(where: { $0.kind == .siri && $0.language.hasPrefix(prefix) })?.identifier
            ?? catalog.first(where: { $0.kind == .siri })?.identifier
            ?? AVSpeechSynthesisVoice(language: Locale.autoupdatingCurrent.identifier)?.identifier
            ?? ""
    }

    private static func preferredLanguageSort(_ a: String, _ b: String) -> Bool {
        let preferred = Locale.autoupdatingCurrent.identifier
        let prefix = preferred.prefix(2)
        let aPref = a.hasPrefix(prefix)
        let bPref = b.hasPrefix(prefix)
        if aPref != bPref { return aPref }
        return a < b
    }

    private static func preferredLanguageNameSort(_ a: String, _ b: String) -> Bool {
        let current = Locale.current.localizedString(forIdentifier: Locale.autoupdatingCurrent.identifier) ?? ""
        if a == current { return true }
        if b == current { return false }
        return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }
}

private enum SpokenContentVoice {
    static var identifier: String? {
        let defaults = UserDefaults(suiteName: "com.apple.Accessibility")
        let selections = defaults?.array(forKey: "SpokenContentDefaultVoiceSelectionsByLanguage") ?? []
        let preferred = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
        var fallback: String?
        for entry in selections {
            guard let map = entry as? [String: Any] else { continue }
            let voiceId = map["voiceId"] as? String
            let bound = (map["boundLanguage"] as? String) ?? ""
            if fallback == nil { fallback = voiceId }
            if bound == preferred || bound.hasPrefix(preferred) {
                return voiceId
            }
        }
        return fallback
    }
}

private enum SiriVoiceCatalog {
    static let voices: [SystemVoice] = load()

    static func canonicalIdentifier(_ identifier: String) -> String {
        if identifier.hasPrefix("com.apple.siri.natural.") { return identifier }
        let prefixes = [
            "com.apple.siri.neural.",
            "com.apple.siri.gryphon.",
            "com.apple.speech.synthesis.voice.custom.siri.",
        ]
        for prefix in prefixes where identifier.hasPrefix(prefix) {
            return "com.apple.siri.natural." + identifier.dropFirst(prefix.count)
        }
        return identifier
    }

    private static func load() -> [SystemVoice] {
        let url = URL(fileURLWithPath:
            "/System/Library/PrivateFrameworks/SiriTTSService.framework/Versions/A/Resources/AssistantVoiceMap.plist"
        )
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let locales = root["Voices"] as? [String: Any] else {
            CompanionDebug.log("siri.catalog missing AssistantVoiceMap")
            return []
        }

        var voices: [SystemVoice] = []
        for (locale, value) in locales {
            guard let entries = value as? [[String: Any]] else { continue }
            let ordered = entries.sorted { lhs, rhs in
                (lhs["order"] as? Int ?? 99) < (rhs["order"] as? Int ?? 99)
            }
            for entry in ordered {
                let rawName = (entry["name"] as? String)
                    ?? ((entry["identifier"] as? String)?.split(separator: ".").last).map(String.init)
                    ?? ""
                guard !rawName.isEmpty else { continue }
                let order = entry["order"] as? Int ?? (voices.filter { $0.language == locale }.count + 1)
                voices.append(
                    SystemVoice(
                        identifier: "com.apple.siri.natural.\(rawName)",
                        name: "Voice \(order)",
                        language: locale,
                        kind: .siri
                    )
                )
            }
        }
        CompanionDebug.log("siri.catalog loaded \(voices.count) Apple Intelligence voices")
        return voices
    }
}

@MainActor
final class CompanionSpeaker: NSObject, AVSpeechSynthesizerDelegate, NSSpeechSynthesizerDelegate {

    private let av = AVSpeechSynthesizer()
    private let ns = NSSpeechSynthesizer()
    private var pending: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        av.delegate = self
        ns.delegate = self
    }

    func speak(_ text: String) async {
        stop()
        let cleaned = SpokenText.clean(text)
        let identifier = SystemVoice.resolvedIdentifier
        CompanionDebug.log("speak chars=\(cleaned.count) id=\(identifier) ns=\(SystemVoice.usesMacSpeechChannel)")
        guard !cleaned.isEmpty else {
            CompanionDebug.log("speak skipped empty")
            return
        }

        if let parts = AppleIntelligenceTTS.parts(for: identifier) {
            let spoke = await AppleIntelligenceTTS.shared.speak(cleaned, language: parts.language, name: parts.name)
            if !spoke, let custom = AppleIntelligenceTTS.customSiriIdentifier(for: identifier) {
                CompanionDebug.log("speak falling back to NSSpeech \(custom)")
                await speakMacSpeech(cleaned, identifier: custom)
            } else if !spoke {
                await speakAV(cleaned, identifier: identifier)
            }
        } else if SystemVoice.usesMacSpeechChannel {
            await speakMacSpeech(cleaned, identifier: identifier)
        } else {
            await speakAV(cleaned, identifier: identifier)
        }
        CompanionDebug.log("speak finished")
    }

    private static var retainedPreview: CompanionSpeaker?

    func preview(_ text: String = "Hi, I’m Grok.") {
        Task { await speak(text) }
    }

    static func preview(_ text: String = "Hi, I’m Grok.") {
        let speaker = CompanionSpeaker()
        retainedPreview = speaker
        speaker.preview(text)
    }

    func stop() {
        if av.isSpeaking {
            av.stopSpeaking(at: .immediate)
        }
        if ns.isSpeaking {
            ns.stopSpeaking()
        }
        AppleIntelligenceTTS.shared.stop()
        finish()
    }

    private func speakAV(_ text: String, identifier: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: identifier)
            ?? AVSpeechSynthesisVoice(language: Locale.autoupdatingCurrent.identifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.05
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pending = continuation
            av.speak(utterance)
            CompanionDebug.log("speak.av started speaking=\(av.isSpeaking) voice=\(utterance.voice?.name ?? "nil")")
        }
    }

    private func speakMacSpeech(_ text: String, identifier: String) async {
        let applied = ns.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: identifier))
        CompanionDebug.log("speak.ns setVoice=\(applied) id=\(identifier) current=\(ns.voice()?.rawValue ?? "nil")")
        if !applied {
            await speakAV(text, identifier: identifier)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pending = continuation
            if !ns.startSpeaking(text) {
                CompanionDebug.log("speak.ns startSpeaking failed")
                finish()
            } else {
                CompanionDebug.log("speak.ns started speaking=\(ns.isSpeaking)")
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        Task { @MainActor in
            CompanionDebug.log("speak.ns didFinish finished=\(finishedSpeaking)")
            self.finish()
        }
    }

    private func finish() {
        pending?.resume()
        pending = nil
    }
}
