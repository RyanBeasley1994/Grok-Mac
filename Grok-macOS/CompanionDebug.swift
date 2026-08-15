//
//  CompanionDebug.swift
//  Grok-macOS
//
//  Always-on companion diagnostics. Writes to Console (subsystem
//  com.nhershy.Grok-macOS) and ~/Library/Logs/Grok-companion.log.
//

import AppKit
import Foundation
import os

enum CompanionDebug {
    static let subsystem = "com.nhershy.Grok-macOS"
    static let logURL: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("Grok-companion.log")
    }()

    private static let logger = Logger(subsystem: subsystem, category: "Companion")
    private static let queue = DispatchQueue(label: "grok.companion.debug")
    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        NSLog("[GrokCompanion] %@", message)
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    static func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }
}
