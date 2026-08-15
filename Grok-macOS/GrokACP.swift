//
//  GrokACP.swift
//  Grok-macOS
//
//  Long-lived `grok agent stdio` process. One conversation stays open
//  for the whole talking session so later turns skip process startup.
//

import Foundation

@MainActor
final class GrokACPSession {

    private var process: Process?
    private var stdin: FileHandle?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var sessionID: String?
    private var chunks = ""
    private var authenticated = false
    var isReady: Bool { process?.isRunning == true && sessionID != nil }

    func start() async throws {
        if isReady { return }
        reset()
        guard let binary = GrokCLI.resolveBinary() else {
            throw GrokCLI.CLIError.notFound
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--always-approve",
            "--sandbox", "off",
            "--no-alt-screen",
            "--no-plan",
            "--no-subagents",
            "--reasoning-effort", "low",
            "--rules", GrokCLI.spokenRules,
            "--disallowed-tools", GrokCLI.disallowedTools(allowTools: true),
            "agent", "stdio",
        ]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = GrokCLIClient.environment()

        let input = Pipe()
        let output = Pipe()
        let err = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = err
        stdin = input.fileHandleForWriting
        self.process = process

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.ingest(data)
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            CompanionDebug.log("acp.stderr \(text.prefix(400))")
        }

        try process.run()
        CompanionDebug.log("acp.start pid=\(process.processIdentifier)")

        let initResult = try await request("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": [
                "fs": ["readTextFile": true, "writeTextFile": true],
                "terminal": true,
            ],
        ])
        let methods = ((initResult["authMethods"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        let methodID: String?
        if ProcessInfo.processInfo.environment["XAI_API_KEY"] != nil, methods.contains("xai.api_key") {
            methodID = "xai.api_key"
        } else if methods.contains("cached_token") {
            methodID = "cached_token"
        } else {
            methodID = methods.first
        }
        if let methodID {
            _ = try await request("authenticate", [
                "methodId": methodID,
                "_meta": ["headless": true],
            ])
        }
        authenticated = true
        try await openNewConversation()
    }

    func openNewConversation() async throws {
        guard process?.isRunning == true else {
            try await start()
            return
        }
        let created = try await request("session/new", [
            "cwd": FileManager.default.homeDirectoryForCurrentUser.path,
            "mcpServers": [],
        ])
        guard let id = created["sessionId"] as? String, !id.isEmpty else {
            throw GrokCLI.CLIError.failed("ACP session did not start.")
        }
        sessionID = id
        chunks = ""
        CompanionDebug.log("acp.ready session=\(id)")
    }

    func prompt(_ text: String) async throws -> GrokCLI.Reply {
        guard isReady, let sessionID else {
            throw GrokCLI.CLIError.failed("ACP session is not ready.")
        }
        chunks = ""
        CompanionDebug.log("acp.prompt session=\(sessionID) chars=\(text.count)")
        let result = try await request("session/prompt", [
            "sessionId": sessionID,
            "prompt": [["type": "text", "text": text]],
        ], timeout: 180)
        let spoken = chunks.trimmingCharacters(in: .whitespacesAndNewlines)
        if spoken.isEmpty {
            throw GrokCLI.CLIError.emptyReply
        }
        CompanionDebug.log("acp.reply chars=\(spoken.count) stop=\(result["stopReason"] ?? "")")
        return GrokCLI.Reply(text: spoken, sessionID: sessionID)
    }

    func reset() {
        authenticated = false
        sessionID = nil
        chunks = ""
        for (_, continuation) in pending {
            continuation.resume(throwing: CancellationError())
        }
        pending.removeAll()
        process?.terminate()
        process = nil
        try? stdin?.close()
        stdin = nil
        CompanionDebug.log("acp.reset")
    }

    private var leftover = Data()

    private func ingest(_ data: Data) {
        leftover.append(data)
        while let newline = leftover.firstIndex(of: 0x0A) {
            let lineData = leftover[..<newline]
            leftover.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] else {
                continue
            }
            handle(object)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            if method == "session/update" {
                appendChunk(from: message["params"] as? [String: Any])
                return
            }
            if method == "session/request_permission", let id = message["id"] {
                autoAllow(id: id, params: message["params"] as? [String: Any])
                return
            }
        }
        guard let id = jsonID(message["id"]), let continuation = pending.removeValue(forKey: id) else {
            return
        }
        if let error = message["error"] as? [String: Any] {
            let text = (error["message"] as? String) ?? "ACP error"
            continuation.resume(throwing: GrokCLI.CLIError.failed(text))
        } else {
            continuation.resume(returning: (message["result"] as? [String: Any]) ?? [:])
        }
    }

    private func appendChunk(from params: [String: Any]?) {
        guard let update = params?["update"] as? [String: Any] else { return }
        let kind = update["sessionUpdate"] as? String
        guard kind == "agent_message_chunk" || kind == "agent_message" else { return }
        if let text = (update["content"] as? [String: Any])?["text"] as? String {
            chunks += text
        } else if let text = update["text"] as? String {
            chunks += text
        }
    }

    private func autoAllow(id: Any, params: [String: Any]?) {
        let options = (params?["options"] as? [[String: Any]]) ?? []
        let optionID = options.first(where: {
            let kind = ($0["kind"] as? String ?? "").lowercased()
            let oid = ($0["optionId"] as? String ?? "").lowercased()
            return kind.contains("allow") || oid.contains("allow")
        })?["optionId"] as? String ?? (options.first?["optionId"] as? String)
        let result: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "outcome": [
                    "outcome": "selected",
                    "optionId": optionID ?? "allow-always",
                ],
            ],
        ]
        write(result)
        CompanionDebug.log("acp.allow \(optionID ?? "allow-always")")
    }

    private func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        write([
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, let leftover = self.pending.removeValue(forKey: id) else { return }
                leftover.resume(throwing: GrokCLI.CLIError.failed("\(method) timed out"))
            }
        }
    }

    private func jsonID(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let stdin else { return }
        var line = data
        line.append(0x0A)
        stdin.write(line)
    }
}
