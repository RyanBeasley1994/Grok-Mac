//
//  GrokServices.swift
//  Grok-macOS
//
//  System Services provider: selected text or Finder files → “Ask Grok”.
//  Appears in the Services submenu and, for selected text, many apps’
//  right-click menus after the first launch.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
enum SelectionCapture {
    static func askGrok() {
        if let text = axSelectedText() {
            ChatWindowController.shared.openWithPrompt(text)
            return
        }
        Task { @MainActor in
            let (text, files) = await copyFrontSelection()
            if !files.isEmpty {
                ChatWindowController.shared.openWithFiles(files)
            } else if let text, !text.isEmpty {
                ChatWindowController.shared.openWithPrompt(text)
            } else {
                ChatWindowController.shared.show()
            }
        }
    }

    private static func axSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            (element as! AXUIElement),
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success, let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func copyFrontSelection() async -> (String?, [URL]) {
        let pb = NSPasteboard.general
        let snapshot = pb.pasteboardItems?.map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
        postCommandC()
        try? await Task.sleep(nanoseconds: 180_000_000)
        let files = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        let text = pb.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        restorePasteboard(pb, snapshot)
        return (text?.isEmpty == false ? text : nil, existing)
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func restorePasteboard(
        _ pb: NSPasteboard,
        _ snapshot: [[(NSPasteboard.PasteboardType, Data)]]?
    ) {
        guard let snapshot else { return }
        pb.clearContents()
        for types in snapshot {
            let item = NSPasteboardItem()
            for (type, data) in types {
                item.setData(data, forType: type)
            }
            pb.writeObjects([item])
        }
    }
}

final class GrokServices: NSObject {
    static let shared = GrokServices()

    @objc func askGrokService(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let files = pboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        let text = pboard.string(forType: .string)
            ?? pboard.string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))

        Task { @MainActor in
            if !existing.isEmpty {
                ChatWindowController.shared.openWithFiles(existing)
            } else if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ChatWindowController.shared.openWithPrompt(text)
            }
        }
    }
}
