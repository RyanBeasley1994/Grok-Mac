//
//  VoiceActivationMode.swift
//  Grok-macOS
//
//  Mutually exclusive ways to start voice: off, on-device “Hey Grok”,
//  or Siri (“Hey Siri, talk to Grok”).
//

enum VoiceActivationMode: String, CaseIterable, Identifiable {
    case off
    case heyGrok
    case heySiri

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .heyGrok: return "Hey Grok"
        case .heySiri: return "Hey Siri, talk to Grok"
        }
    }

    var menuTag: Int {
        switch self {
        case .off: return 0
        case .heyGrok: return 1
        case .heySiri: return 2
        }
    }

    init?(menuTag: Int) {
        switch menuTag {
        case 0: self = .off
        case 1: self = .heyGrok
        case 2: self = .heySiri
        default: return nil
        }
    }
}
