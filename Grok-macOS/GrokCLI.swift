//
//  GrokCLI.swift
//  Grok-macOS
//
//  Headless grok CLI turns for the desktop companion. Each spoken utterance
//  is a `-p` prompt in one resumed session. Tools stay on so Grok can work
//  on this Mac; the spoken-style rules only constrain how it talks back.
//

import Foundation

enum GrokCLI {

    struct Reply {
        var text: String
        var sessionID: String?
    }

    enum CLIError: LocalizedError {
        case notFound
        case emptyReply
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "Grok CLI wasn’t found. Install it, or set the path in Settings."
            case .emptyReply:
                return "Grok didn’t say anything back."
            case .failed(let message):
                return message
            }
        }
    }

    static let spokenRules = """
        You are talking out loud to the user. Reply as if this is a spoken conversation.
        Keep it natural, brief, and easy to hear. Do not mention file paths, folder names, \
        code, commands, URLs, JSON, markdown, or how you used tools. You may use web search \
        for current facts. You may use tools and work on this computer. Then summarize what \
        you did or found in plain speech. If you need more, ask a short spoken question.
        """

    static let noWorkToken = "NO_WORK"

    /// Scheduler tools currently fail CLI session init on this Mac.
    fileprivate static let brokenTools = [
        "scheduler_create",
        "scheduler_delete",
        "scheduler_list",
        "GrokBuild:scheduler_create",
        "GrokBuild:scheduler_delete",
        "GrokBuild:scheduler_list",
    ]

    /// Extra tools stripped from the speak-first turn so Grok cannot act
    /// before the user hears a reply.
    fileprivate static let speakFirstOnlyTools = [
        "bash",
        "read_file",
        "list_dir",
        "grep",
        "grep_search",
        "search_replace",
        "run_terminal_command",
        "run_terminal_cmd",
        "spawn_subagent",
        "image_gen",
        "image_edit",
        "image_to_video",
        "deploy_app",
        "workflow",
        "todo_write",
        "ask_user_question",
        "enter_plan_mode",
        "exit_plan_mode",
        "monitor",
    ]

    static func disallowedTools(allowTools: Bool) -> String {
        let names = allowTools ? brokenTools : brokenTools + speakFirstOnlyTools
        return names.joined(separator: ",")
    }

    static let customPathKey = "grokCLIPath"

    static var customPath: String {
        get { UserDefaults.standard.string(forKey: customPathKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: customPathKey) }
    }

    static func resolveBinary() -> URL? {
        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [String] = {
            var list: [String] = []
            if !trimmed.isEmpty { list.append(trimmed) }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            list.append(contentsOf: [
                "\(home)/.grok/bin/grok",
                "/opt/homebrew/bin/grok",
                "/usr/local/bin/grok",
                "/usr/bin/grok",
            ])
            return list
        }()
        for path in candidates {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            let exec = exists && !isDir.boolValue && FileManager.default.isExecutableFile(atPath: path)
            CompanionDebug.log("cli.candidate \(path) exists=\(exists) dir=\(isDir.boolValue) exec=\(exec)")
            if exec {
                return URL(fileURLWithPath: path)
            }
        }
        CompanionDebug.log("cli.binary not found")
        return nil
    }

    static func speakFirstPrompt(forSpoken transcript: String) -> String {
        """
        [Spoken conversation]
        \(spokenRules)

        Give a spoken reply. Use web search when you need current information. \
        If they asked you to do something on this Mac, do it, then say what you did.

        The user said:
        \(transcript)
        """
    }

    static func workPrompt() -> String {
        """
        [Do any needed work now]
        If the user's last request needs computer work, do it now.
        If they asked something that needs current information, news, weather, \
        or a fact you are not sure about, use web search and then give a spoken answer.
        If you already fully answered them and nothing else is needed, reply with exactly: \(noWorkToken)
        When you finish real work, give a short spoken update. No paths, code, or URLs.
        """
    }

    static func isNoWork(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'."))
            .caseInsensitiveCompare(noWorkToken) == .orderedSame
    }
}

@MainActor
final class GrokCLIClient {

    private var process: Process?
    private let acp = GrokACPSession()
    private var warmID: String?

    func prepare() async {
        if acp.isReady {
            CompanionDebug.log("cli.prepare already warm")
            return
        }
        do {
            try await acp.start()
            CompanionDebug.log("cli.prepare acp ready")
        } catch {
            CompanionDebug.log("cli.prepare acp failed \(error.localizedDescription) — will use --single")
            acp.reset()
        }
    }

    func recycleConversation() async {
        CompanionDebug.log("cli.recycle")
        warmID = nil
        cancel()
        do {
            if acp.isReady {
                try await acp.openNewConversation()
            } else {
                try await acp.start()
            }
            CompanionDebug.log("cli.recycle ready")
        } catch {
            CompanionDebug.log("cli.recycle failed \(error.localizedDescription)")
            acp.reset()
            Task { await prepare() }
        }
    }

    func reset() {
        CompanionDebug.log("cli.reset")
        acp.reset()
        warmID = nil
        cancel()
    }

    func cancel() {
        if let process {
            CompanionDebug.log("cli.cancel pid=\(process.processIdentifier)")
            process.terminate()
        }
        process = nil
    }

    func askSpoken(transcript: String, sessionID: String?) async throws -> GrokCLI.Reply {
        CompanionDebug.log("cli.askSpoken acp=\(acp.isReady) session=\(sessionID ?? warmID ?? "new") transcript=\(transcript)")
        if acp.isReady {
            return try await acp.prompt(GrokCLI.speakFirstPrompt(forSpoken: transcript))
        }
        let reply = try await ask(
            prompt: GrokCLI.speakFirstPrompt(forSpoken: transcript),
            sessionID: sessionID ?? warmID,
            allowTools: true
        )
        if let id = reply.sessionID { warmID = id }
        return reply
    }

    private func ask(prompt: String, sessionID: String?, allowTools: Bool) async throws -> GrokCLI.Reply {
        guard let binary = GrokCLI.resolveBinary() else {
            CompanionDebug.log("cli.ask binary missing")
            throw GrokCLI.CLIError.notFound
        }

        var lastError: Error = GrokCLI.CLIError.emptyReply
        var resume = sessionID

        for attempt in 0..<2 {
            CompanionDebug.log("cli.ask attempt=\(attempt + 1) tools=\(allowTools) resume=\(resume ?? "none")")
            do {
                return try await run(binary: binary, prompt: prompt, resume: resume, allowTools: allowTools)
            } catch {
                lastError = error
                let message = error.localizedDescription
                let empty = (error as? GrokCLI.CLIError).map { if case .emptyReply = $0 { return true }; return false } ?? false
                if attempt == 0, resume != nil || empty || message.localizedCaseInsensitiveContains("max turns") {
                    CompanionDebug.log("cli.retry fresh: \(message)")
                    resume = nil
                    continue
                }
                throw error
            }
        }
        throw lastError
    }

    private func run(binary: URL, prompt: String, resume: String?, allowTools: Bool) async throws -> GrokCLI.Reply {
        cancel()

        let process = Process()
        process.executableURL = binary
        let args = Self.arguments(prompt: prompt, resume: resume, allowTools: allowTools)
        process.arguments = args
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = Self.environment()
        process.standardInput = FileHandle.nullDevice
        CompanionDebug.log("cli.exec \(binary.path) \(args.enumerated().map { $0.offset == 1 ? "<prompt \(prompt.count) chars>" : $0.element }.joined(separator: " "))")

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process

        let reply: GrokCLI.Reply
        do {
            reply = try await Self.execute(process: process, stdout: stdout, stderr: stderr)
        } catch {
            CompanionDebug.log("cli.run error \(error.localizedDescription)")
            if self.process === process { self.process = nil }
            throw error
        }
        if self.process === process { self.process = nil }
        CompanionDebug.log("cli.run ok session=\(reply.sessionID ?? "none") chars=\(reply.text.count)")
        return reply
    }

    private static func arguments(prompt: String, resume: String?, allowTools: Bool) -> [String] {
        var args = [
            "--single", prompt,
            "--output-format", "json",
            "--cwd", FileManager.default.homeDirectoryForCurrentUser.path,
            "--always-approve",
            "--sandbox", "off",
            "--no-alt-screen",
            "--no-plan",
            "--max-turns", "16",
            "--reasoning-effort", "low",
            "--rules", GrokCLI.spokenRules,
            "--verbatim",
            "--no-subagents",
        ]
        args += ["--disallowed-tools", GrokCLI.disallowedTools(allowTools: allowTools)]
        if let resume, !resume.isEmpty {
            args += ["--resume", resume]
        }
        return args
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = [
            "\(home)/.grok/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let existing = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        var path: [String] = []
        var seen = Set<String>()
        for item in extras + existing where seen.insert(item).inserted {
            path.append(item)
        }
        env["PATH"] = path.joined(separator: ":")
        env["HOME"] = home
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        env["GROK_DISABLE_AUTOUPDATER"] = "1"
        return env
    }

    private static func execute(process: Process, stdout: Pipe, stderr: Pipe) async throws -> GrokCLI.Reply {
        try process.run()
        CompanionDebug.log("cli.pid \(process.processIdentifier) running=\(process.isRunning)")
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) { [weak process] in
            guard let process, process.isRunning else { return }
            CompanionDebug.log("cli.timeout 180s — terminating pid=\(process.processIdentifier)")
            process.terminate()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let lock = NSLock()
                var settled = false
                func finish(_ result: Result<GrokCLI.Reply, Error>) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !settled else { return }
                    settled = true
                    continuation.resume(with: result)
                }

                let outHandle = stdout.fileHandleForReading
                let errHandle = stderr.fileHandleForReading
                DispatchQueue.global(qos: .userInitiated).async {
                    let group = DispatchGroup()
                    var outData = Data()
                    var errData = Data()
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        outData = outHandle.readDataToEndOfFile()
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        errData = errHandle.readDataToEndOfFile()
                        group.leave()
                    }
                    process.waitUntilExit()
                    group.wait()

                    let out = String(data: outData, encoding: .utf8) ?? ""
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    CompanionDebug.log("cli.exit status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue) stdout=\(outData.count)b stderr=\(errData.count)b")
                    if !err.isEmpty {
                        CompanionDebug.log("cli.stderr \(err.prefix(800))")
                    }
                    CompanionDebug.log("cli.stdout \(out.prefix(800))")

                    if process.terminationStatus == 15 || process.terminationStatus == 9
                        || process.terminationReason == .uncaughtSignal {
                        finish(.failure(CancellationError()))
                        return
                    }

                    do {
                        finish(.success(try decode(stdout: out, stderr: err, status: process.terminationStatus)))
                    } catch {
                        finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            CompanionDebug.log("cli.execute cancelled — terminate pid=\(process.processIdentifier)")
            process.terminate()
        }
    }

    nonisolated private static func decode(stdout: String, stderr: String, status: Int32) throws -> GrokCLI.Reply {
        let trimmed = firstJSONObject(in: stdout) ?? stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let type = object["type"] as? String, type == "error" {
                let message = (object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw GrokCLI.CLIError.failed(message ?? "Grok CLI returned an error.")
            }
            let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let session = object["sessionId"] as? String
            if !text.isEmpty {
                return GrokCLI.Reply(text: text, sessionID: session)
            }
            let err = cleanError(stderr, fallback: "")
            if err.localizedCaseInsensitiveContains("max turns") {
                throw GrokCLI.CLIError.emptyReply
            }
            if status != 0 {
                throw GrokCLI.CLIError.failed(err.isEmpty ? "Grok CLI failed." : err)
            }
            throw GrokCLI.CLIError.emptyReply
        }

        if status != 0 {
            throw GrokCLI.CLIError.failed(cleanError(stderr.isEmpty ? stdout : stderr, fallback: "Grok CLI failed."))
        }
        let plain = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if plain.isEmpty {
            throw GrokCLI.CLIError.emptyReply
        }
        return GrokCLI.Reply(text: plain, sessionID: nil)
    }

    nonisolated private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        return String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func cleanError(_ raw: String, fallback: String) -> String {
        let line = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("debug") }
        let text = line.map { String($0) } ?? fallback
        if text.count > 180 {
            return String(text.prefix(180))
        }
        return text
    }
}

enum SpokenText {
    static func clean(_ raw: String) -> String {
        var text = raw
        if let fences = try? NSRegularExpression(pattern: "```[\\s\\S]*?```") {
            text = fences.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: " "
            )
        }
        if let links = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\([^)]+\\)") {
            text = links.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "$1"
            )
        }
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        if let headings = try? NSRegularExpression(pattern: "(?m)^#+\\s*") {
            text = headings.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }
        if let bullets = try? NSRegularExpression(pattern: "(?m)^\\s*[-*]\\s+") {
            text = bullets.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }
        let collapsed = text
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let spaced = collapsed.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return spaced.isEmpty ? "Done." : spaced
    }
}
