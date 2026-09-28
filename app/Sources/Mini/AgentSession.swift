import Foundation

/// The agent CLIs Mini can run. Both speak the same stream-json protocol over
/// stdio in print mode, and both are limited to Mini's MCP tools.
enum AgentKind: String, CaseIterable {
    case qodercli
    case claude

    var displayName: String {
        switch self {
        case .qodercli: "Qoder CLI"
        case .claude: "Claude Code"
        }
    }

    /// The path set in Settings, which overrides the lookup.
    var pathDefaultsKey: String { "agentPath.\(rawValue)" }

    /// The agent new chats start with.
    static var current: AgentKind {
        get { UserDefaults.standard.string(forKey: "agent").flatMap(AgentKind.init) ?? .qodercli }
        set {
            guard newValue != current else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: "agent")
            NotificationCenter.default.post(name: .agentKindDidChange, object: nil)
        }
    }

    /// Print mode with stream-json both ways, no built-in tools, only the
    /// `mini` MCP server, and its tools allowed without asking.
    func arguments(mcpConfig: String, systemPrompt: String) -> [String] {
        let common = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--tools", "",
            "--mcp-config", mcpConfig,
            "--strict-mcp-config",
            "--no-session-persistence",
            "--append-system-prompt", systemPrompt,
        ]
        switch self {
        case .claude:
            return common + [
                "--verbose",
                "--include-partial-messages",
                "--allowedTools", "mcp__mini",
                "--permission-mode", "dontAsk",
            ]
        case .qodercli:
            // --tools "" leaves qodercli's agent-team tools in place.
            return common + [
                "--disallowed-tools", "ListAgents,SendMessage",
                "--allowed-tools", "mcp__mini",
                "--permission-mode", "dont_ask",
            ]
        }
    }
}

enum AgentEvent {
    case ready(model: String?)
    /// A streamed text block started (Claude Code only).
    case textStarted
    case textDelta(String)
    /// A complete text block. Replaces the streamed one if there was one.
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
    case toolResult(id: String, isError: Bool, summary: String)
    case retrying
    /// `stopped` means the user interrupted the turn.
    case turnFinished(error: String?, stopped: Bool)
    case exited(message: String?)
}

/// One running agent CLI. The process stays alive across turns and keeps the
/// conversation; stopping it ends the conversation.
@MainActor
final class AgentSession {
    let kind: AgentKind
    var onEvent: ((AgentEvent) -> Void)?

    private(set) var isBusy = false
    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrTail = ""
    /// Bumped for every process, so output and exit events from a stopped one are ignored.
    private var generation = 0
    private var interruptTimer: Timer?
    private var interrupted = false

    init(kind: AgentKind) {
        self.kind = kind
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func start() throws {
        guard process == nil else { return }
        guard let executable = AgentEnvironment.executable(for: kind) else {
            if let path = Settings.agentPath(for: kind) {
                throw ControlError("\(path) is not an executable file. Fix the \(kind.displayName) path in Settings (Cmd+,).")
            }
            throw ControlError("\(kind.rawValue) not found. Install it, or set its path in Settings (Cmd+,).")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = kind.arguments(
            mcpConfig: try AgentEnvironment.writeMCPConfig(),
            systemPrompt: AgentEnvironment.systemPrompt
        )
        process.currentDirectoryURL = try AgentEnvironment.workingDirectory()
        process.environment = AgentEnvironment.environment()

        // Writing to an agent that has exited should fail, not kill Mini.
        signal(SIGPIPE, SIG_IGN)
        generation += 1
        let generation = generation

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // Pipe handlers run on a background queue. Hop to the main actor with
        // the raw bytes and parse there.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(stdout: data, generation: generation) } }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(stderr: data, generation: generation) } }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.terminated(status: status, generation: generation) } }
        }

        try process.run()
        self.process = process
        stdin = input.fileHandleForWriting
    }

    /// Sends one user turn. `context` goes before the text, for the agent only.
    func send(_ text: String, context: String) throws {
        try start()
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": context + "\n\n" + text],
        ]
        try write(message)
        isBusy = true
    }

    /// Asks the agent to stop the current turn. If it hasn't finished within a
    /// few seconds, the process is ended, which also ends the conversation.
    func interrupt() {
        guard isBusy else { return }
        interrupted = true
        try? write([
            "type": "control_request",
            "request_id": UUID().uuidString,
            "request": ["subtype": "interrupt"],
        ])
        interruptTimer?.invalidate()
        interruptTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isBusy else { return }
                self.stop()
                self.onEvent?(.exited(message: "\(self.kind.displayName) didn't stop in time, so Mini ended it. The next message starts a new conversation."))
            }
        }
    }

    /// Ends the process and the conversation. Sends no event.
    func stop() {
        guard let process else { return }
        generation += 1
        // stream-json input ends the agent when stdin closes. Terminate in
        // case it is in the middle of a request.
        try? stdin?.close()
        if process.isRunning { process.terminate() }
        reset()
    }

    private func reset() {
        process = nil
        stdin = nil
        stdoutBuffer.removeAll()
        stderrTail = ""
        isBusy = false
        interrupted = false
        interruptTimer?.invalidate()
    }

    private func write(_ object: [String: Any]) throws {
        guard let stdin else { throw ControlError("the agent is not running") }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    // MARK: Output

    private func received(stdout data: Data, generation: Int) {
        guard generation == self.generation, !data.isEmpty else { return }
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer[stdoutBuffer.startIndex..<newline]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            // Not every line is JSON: qodercli prints some notices to stdout.
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(message)
        }
    }

    private func received(stderr data: Data, generation: Int) {
        guard generation == self.generation, !data.isEmpty else { return }
        stderrTail = String((stderrTail + String(decoding: data, as: UTF8.self)).suffix(2000))
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "system":
            switch message["subtype"] as? String {
            case "init": onEvent?(.ready(model: message["model"] as? String))
            case "api_retry": onEvent?(.retrying)
            default: break
            }
        case "stream_event":
            guard let event = message["event"] as? [String: Any] else { return }
            switch event["type"] as? String {
            case "content_block_start":
                if (event["content_block"] as? [String: Any])?["type"] as? String == "text" { onEvent?(.textStarted) }
            case "content_block_delta":
                let delta = event["delta"] as? [String: Any]
                if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String { onEvent?(.textDelta(text)) }
            default: break
            }
        case "assistant":
            let content = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty { onEvent?(.text(text)) }
                case "tool_use":
                    onEvent?(.toolUse(
                        id: block["id"] as? String ?? "",
                        name: block["name"] as? String ?? "tool",
                        input: block["input"] as? [String: Any] ?? [:]
                    ))
                default: break
                }
            }
        case "user":
            let content = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_result" {
                onEvent?(.toolResult(
                    id: block["tool_use_id"] as? String ?? "",
                    isError: block["is_error"] as? Bool ?? false,
                    summary: Self.summary(of: block["content"])
                ))
            }
        case "result":
            isBusy = false
            interruptTimer?.invalidate()
            let failed = message["is_error"] as? Bool ?? false
            let subtype = message["subtype"] as? String ?? "success"
            var error: String?
            // Claude Code reports an interrupted turn as error_during_execution.
            if (failed || subtype != "success") && !interrupted {
                error = (message["result"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? subtype
            }
            let stopped = interrupted
            interrupted = false
            onEvent?(.turnFinished(error: error, stopped: stopped))
        default:
            break
        }
    }

    /// First line of a tool result's text. Images are just noted.
    private static func summary(of content: Any?) -> String {
        var text = ""
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { block in
                block["type"] as? String == "image" ? "[image]" : block["text"] as? String
            }.joined(separator: " ")
        }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }

    private func terminated(status: Int32, generation: Int) {
        guard generation == self.generation, process != nil else { return }
        let tail = stderrTail.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
        reset()
        onEvent?(.exited(message: "\(kind.displayName) exited with status \(status)." + (tail.isEmpty ? "" : "\n" + tail)))
    }
}

/// Where the agent CLIs are, and what they run with.
@MainActor
enum AgentEnvironment {
    private static let basePrompt = """
        You are running inside Mini, a web browser for macOS. The user talks to you in a narrow \
        side panel next to the page. You act on the browser only through the mini tools \
        (list_tabs, new_tab, select_tab, close_tab, navigate, read_page, click, type, screenshot, \
        eval_js). Each user message starts with the selected tab's id, title and URL, which is \
        usually the page the user means. Call read_page before clicking or typing and use the \
        refs it returns. Keep replies short.
        """

    /// Mini's prompt, then the extra instructions from Settings.
    static var systemPrompt: String {
        let extra = Settings.agentInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return extra.isEmpty ? basePrompt : basePrompt + "\n\n" + extra
    }

    private static let supportDirectory = NSHomeDirectory() + "/Library/Application Support/Mini"

    /// Browsers launched from Finder get a minimal PATH, so look in the usual
    /// install locations too.
    nonisolated private static var searchDirectories: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.npm-global/bin",
        ]
    }

    static func executable(for kind: AgentKind) -> String? {
        if let path = Settings.agentPath(for: kind) {
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        return detectedExecutable(for: kind)
    }

    /// Where the CLI is when Settings has no path for it. Can start a login
    /// shell, so Settings calls it off the main thread.
    nonisolated static func detectedExecutable(for kind: AgentKind) -> String? {
        for directory in searchDirectories {
            let path = "\(directory)/\(kind.rawValue)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return loginShellLookup(kind.rawValue)
    }

    /// `command -v` in a login shell. zsh functions and aliases don't count,
    /// only files on PATH.
    nonisolated private static func loginShellLookup(_ name: String) -> String? {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "whence -p \(name)"]
        let output = Pipe()
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return shell.terminationStatus == 0 && !path.isEmpty ? path : nil
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (searchDirectories + [path]).joined(separator: ":")
        // Set when Mini itself was started from a Claude Code session.
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { env[key] = nil }
        return env
    }

    /// An empty directory, so the agent doesn't pick up a project's files or instructions.
    static func workingDirectory() throws -> URL {
        let url = URL(fileURLWithPath: supportDirectory + "/agent")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Points the agent at the mini_mcp next to Mini's own executable.
    static func writeMCPConfig() throws -> String {
        let server = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mini_mcp").path
        let config: [String: Any] = [
            "mcpServers": ["mini": ["type": "stdio", "command": server, "args": [String]()]],
        ]
        try FileManager.default.createDirectory(atPath: supportDirectory, withIntermediateDirectories: true)
        let path = supportDirectory + "/agent-mcp.json"
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
            .write(to: URL(fileURLWithPath: path))
        return path
    }
}
