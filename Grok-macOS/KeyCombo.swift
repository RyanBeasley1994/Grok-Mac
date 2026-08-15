//
//  KeyCombo.swift
//  Grok-macOS
//
//  Persisted global shortcut (Carbon key code + modifiers).
//

import AppKit
import Carbon.HIToolbox

struct KeyCombo: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let defaultToggle = KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))
    static let defaultVoice = KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey | shiftKey))

    enum Slot: String {
        case toggle
        case voice

        var defaultsKey: String { "hotkey.\(rawValue)" }
        var defaultValue: KeyCombo {
            switch self {
            case .toggle: return .defaultToggle
            case .voice: return .defaultVoice
            }
        }
    }

    static func stored(_ slot: Slot) -> KeyCombo {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: slot.defaultsKey + ".key") != nil else {
            return slot.defaultValue
        }
        return KeyCombo(
            keyCode: UInt32(defaults.integer(forKey: slot.defaultsKey + ".key")),
            carbonModifiers: UInt32(defaults.integer(forKey: slot.defaultsKey + ".mods"))
        )
    }

    func save(_ slot: Slot) {
        UserDefaults.standard.set(Int(keyCode), forKey: slot.defaultsKey + ".key")
        UserDefaults.standard.set(Int(carbonModifiers), forKey: slot.defaultsKey + ".mods")
    }

    static func reset(_ slot: Slot) {
        slot.defaultValue.save(slot)
    }

    var display: String {
        var parts = ""
        if carbonModifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        parts += Self.keyName(keyCode)
        return parts
    }

    static func from(event: NSEvent) -> KeyCombo? {
        // Modifier-only presses are not a shortcut.
        let ignored: [UInt16] = [
            UInt16(kVK_Command), UInt16(kVK_Shift), UInt16(kVK_Option), UInt16(kVK_Control),
            UInt16(kVK_RightCommand), UInt16(kVK_RightShift), UInt16(kVK_RightOption), UInt16(kVK_RightControl),
            UInt16(kVK_Function),
        ]
        if ignored.contains(event.keyCode) { return nil }

        var mods: UInt32 = 0
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        // Global hotkeys need a modifier so they don't eat typing.
        if mods == 0 { return nil }
        return KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
    }

    private static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Fwd Del"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            break
        }
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return "Key \(keyCode)"
            }
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &dead,
                4,
                &length,
                &chars
            )
            if status == noErr, length > 0 {
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
            return "Key \(keyCode)"
        }
    }
}
