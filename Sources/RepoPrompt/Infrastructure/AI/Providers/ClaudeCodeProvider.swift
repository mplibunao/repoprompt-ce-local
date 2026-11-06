import Foundation

struct ClaudeCodeCLIModelSelection: Equatable {
    let modelArgument: String?
    let effortLevel: ClaudeCodeEffortLevel?
}

struct ClaudeCLIOptions {
    var printMode: Bool = true
    var verbose: Bool = false
    var maxTurns: Int?
    var allowedTools: [String] = []
    var disallowedTools: [String] = []
    var permissionMode: String?
    var permissionPromptToolName: String?
    var model: String?
    var effortLevel: ClaudeCodeEffortLevel?
    var mcpConfigPath: String?
    var systemPromptOverride: String?
    var timeout: TimeInterval?
    var environmentOverrides: [String: String] = [:]
    var removedEnvironmentKeys: Set<String> = []

    var additionalEnvironment: [String: String] {
        var environment = environmentOverrides
        if let effortLevel {
            environment["CLAUDE_CODE_EFFORT_LEVEL"] = effortLevel.envValue
        }
        return environment
    }

    func toTokens() -> [String] {
        var tokens: [String] = []
        if printMode {
            tokens.append("-p")
        }
        if verbose {
            tokens.append("--verbose")
        }
        if let maxTurns {
            tokens.append(contentsOf: ["--max-turns", String(maxTurns)])
        }
        if !allowedTools.isEmpty {
            tokens.append(contentsOf: ["--allowedTools", allowedTools.joined(separator: ",")])
        }
        if !disallowedTools.isEmpty {
            tokens.append(contentsOf: ["--disallowedTools", disallowedTools.joined(separator: ",")])
        }
        if let permissionPromptToolName {
            tokens.append(contentsOf: ["--permission-prompt-tool", permissionPromptToolName])
        }
        if let permissionMode {
            tokens.append(contentsOf: ["--permission-mode", permissionMode])
        }
        if let model {
            tokens.append(contentsOf: ["--model", model])
        }
        if let systemPromptOverride {
            tokens.append(contentsOf: ["--system-prompt", systemPromptOverride])
        }
        if let mcpConfigPath {
            tokens.append(contentsOf: ["--mcp-config", mcpConfigPath])
            // Use strict mode to ignore project-level MCP configs from ~/.claude.json
            // This prevents the CLI from trying to start stale MCP servers based on working directory
            tokens.append("--strict-mcp-config")
        }
        return tokens
    }
}

final class ClaudeCodeProvider: AIProvider {
    private let runner: CLIProcessRunner
    private let decoder: JSONDecoder
    private let configService = MCPConfigExportService.shared
    private let disallowedTools: [String] = [
        "Bash",
        "BashOutput",
        "KillShell",
        "Monitor",
        "Read",
        "Write",
        "Edit",
        "Glob",
        "Grep",
        "Task",
        "TaskOutput",
        "TaskStop",
        "WebFetch",
        "WebSearch",
        "SlashCommand",
        "NotebookEdit",
        "TodoWrite",
        "EnterPlanMode",
        "ExitPlanMode",
        "EnterWorktree",
        "ExitWorktree",
        "Skill",
        "CronCreate",
        "CronDelete",
        "CronList",
        "RemoteTrigger",
        "AskUserQuestion",
        "ScheduleWakeup",
        "PushNotification"
    ]

    private let defaultRequestTimeout: TimeInterval
    private let testRequestTimeout: TimeInterval
    private let maxRetries: Int
    private let initialBackoff: TimeInterval = 1.0
    private let maxBackoff: TimeInterval = 8.0

    init(
        workingDirectory: String? = nil,
        enableDebugLogging: Bool = false,
        defaultRequestTimeout: TimeInterval? = nil,
        testRequestTimeout: TimeInterval? = nil,
        maxRetries: Int? = nil,
        logCollector: CLIProcessLogCollector? = nil
    ) {
        var config = CLIProcessConfiguration(
            workingDirectory: workingDirectory,
            captureStdoutTailBytes: 128 * 1024,
            captureStderrTailBytes: 256 * 1024
        )
        config.enableDebugLogging = enableDebugLogging
        config.logCollector = logCollector
        config.ensureAdditionalPaths(CLIPathHints.claudeCode)
        runner = CLIProcessRunner(config: config)
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let resolvedDefaultTimeout = defaultRequestTimeout ?? 6000
        let resolvedTestTimeout = testRequestTimeout ?? 30
        let resolvedRetries = maxRetries ?? 2

        self.defaultRequestTimeout = resolvedDefaultTimeout
        self.testRequestTimeout = resolvedTestTimeout
        self.maxRetries = resolvedRetries
    }

    func streamMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int? = nil) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let completion = try await completeMessage(aiMessage, model: model, maxTokens: maxTokens)
        return AsyncThrowingStream { continuation in
            continuation.yield(AIStreamResult(type: "content", text: completion.text))
            continuation.yield(
                AIStreamResult(
                    type: "message_stop",
                    text: nil,
                    reasoning: nil,
                    promptTokens: completion.promptTokens,
                    completionTokens: completion.completionTokens,
                    cost: completion.cost
                )
            )
            continuation.finish()
        }
    }

    func completeMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int? = nil) async throws -> AICompletionResult {
        let nativePromptMode = ClaudeAgentToolPreferences.agentModePromptDelivery()
        let basePrompt = buildPrompt(from: aiMessage)
        let prompt = nativePromptMode.sendsRepoPromptAsUserMessage
            ? ClaudeCodePromptDelivery.decoratedUserMessage(basePrompt, instructions: aiMessage.systemPrompt)
            : basePrompt
        let emptyConfigLease = try await configService.prepareEmptyLaunchConfig()
        defer { emptyConfigLease.release() }
        var options = try await makeOptions(for: aiMessage, model: model, emptyConfigURL: emptyConfigLease.url)
        options.systemPromptOverride = nativePromptMode.nativeSystemPromptOverride(instructions: aiMessage.systemPrompt)
        if options.timeout == nil {
            options.timeout = defaultRequestTimeout
        }
        // stream-json emits one event per content block; the single-JSON output keeps only the final
        // block's text, which drops the earlier blocks of a reply continued after max_tokens. The CLI
        // requires --verbose with -p and stream-json.
        options.verbose = true
        let args = options.toTokens()

        var attempt = 0
        var delay = initialBackoff

        while true {
            let result: CLIProcessRunner.Result
            do {
                result = try await runner.run(
                    args: args,
                    stdin: prompt,
                    outputMode: .auto(.streamJson),
                    timeout: options.timeout,
                    additionalEnvironment: options.additionalEnvironment,
                    additionalRemovedKeys: options.removedEnvironmentKeys
                )
            } catch {
                throw mapProcessError(error)
            }

            if result.status == 0 {
                guard !result.stdout.isEmpty else {
                    throw AIProviderError.invalidResponse(detail: "Claude CLI returned no output")
                }
                do {
                    return try Self.parseStreamJSONCompletionPayload(result.stdout)
                } catch {
                    throw AIProviderError.apiError(source: error)
                }
            }

            if let humanMessage = extractCLIErrorDetail(fromStdout: result.stdout, isStreamJSON: true) {
                // Check for credit balance error and provide helpful guidance
                let lowerMessage = humanMessage.lowercased()
                if lowerMessage.contains("credit balance") || lowerMessage.contains("balance too low") || lowerMessage.contains("api balance") {
                    throw AIProviderError.invalidConfiguration(detail: "Credit balance is too low. To use Claude Code with your Max plan via RepoPrompt, remove the ANTHROPIC_API_KEY from your environment variables and restart the app. The CLI will then use your Max plan subscription instead of the API key.")
                }
                throw AIProviderError.invalidConfiguration(detail: humanMessage)
            }

            let stderrString = String(data: result.stderr, encoding: .utf8) ?? ""
            let exitCode = result.status
            let canRetry = shouldRetry(exitCode: exitCode, stderr: stderrString, timedOut: result.timedOut, attempt: attempt)

            if canRetry, attempt < maxRetries {
                let jitter = Double.random(in: 0.8 ... 1.2)
                let sleepSeconds = min(delay, maxBackoff) * jitter
                try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                delay = min(delay * 2, maxBackoff)
                attempt += 1
                continue
            }

            throw mapProcessFailure(exitCode: exitCode, stderr: stderrString, timedOut: result.timedOut, timeoutValue: options.timeout)
        }
    }

    func dispose() async {
        await runner.cancelAll()
    }

    // MARK: - Private Helpers

    static func resolveCLIModelSelection(for model: AIModel) throws -> ClaudeCodeCLIModelSelection {
        guard model.providerType == .claudeCode else {
            throw AIProviderError.invalidModel
        }
        if case .claudeCodeModel = model,
           AIModel.fromModelName(model.rawValue) != model
        {
            throw AIProviderError.invalidModel
        }
        guard let rawSpecifier = model.claudeCodeRuntimeSpecifierRaw else {
            return ClaudeCodeCLIModelSelection(modelArgument: nil, effortLevel: nil)
        }
        let specifier = ClaudeModelSpecifier(raw: rawSpecifier)
        guard let runtimeModel = specifier.runtimeModelParam else {
            throw AIProviderError.invalidModel
        }
        return ClaudeCodeCLIModelSelection(
            modelArgument: runtimeModel,
            effortLevel: specifier.explicitEffortLevel
        )
    }

    private func makeOptions(for aiMessage: AIMessage, model: AIModel, emptyConfigURL: URL) async throws -> ClaudeCLIOptions {
        var options = ClaudeCLIOptions()
        options.disallowedTools = disallowedTools
        // Use empty MCP config to prevent CLI from loading user's default config (which may include RepoPrompt)
        options.mcpConfigPath = emptyConfigURL.path
        if let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model) {
            let resolver = ClaudeCodeLaunchEnvironmentResolver()
            let launchEnvironment = try await resolver.resolve(
                variant: Self.runtimeVariant(for: descriptor.backendID),
                requestedModel: descriptor.requestedModelRaw
            )
            options.model = launchEnvironment.effectiveModel
            options.environmentOverrides = launchEnvironment.environmentOverrides
            options.removedEnvironmentKeys = launchEnvironment.removedEnvironmentKeys
            options.timeout = defaultRequestTimeout
            return options
        }
        let selection = try Self.resolveCLIModelSelection(for: model)
        options.model = selection.modelArgument
        options.effortLevel = selection.effortLevel
        options.timeout = defaultRequestTimeout
        return options
    }

    private func mapProcessError(_ error: Error) -> Error {
        if let runnerError = error as? CLIProcessRunnerError {
            switch runnerError {
            case let .commandNotFound(command):
                return AIProviderError.invalidConfiguration(detail: "Command not found: \(command)")
            case let .spawnFailed(message):
                return AIProviderError.apiError(source: NSError(domain: "ClaudeCLI", code: -1, userInfo: [NSLocalizedDescriptionKey: message]))
            case .inputEncodingFailed:
                return AIProviderError.apiError(source: NSError(domain: "ClaudeCLI", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unable to encode prompt for Claude CLI"]))
            case let .inputWriteFailed(message):
                return AIProviderError.apiError(source: NSError(domain: "ClaudeCLI", code: -3, userInfo: [NSLocalizedDescriptionKey: message]))
            case let .waitFailed(message):
                return AIProviderError.apiError(source: NSError(domain: "ClaudeCLI", code: -4, userInfo: [NSLocalizedDescriptionKey: message]))
            }
        }
        return AIProviderError.apiError(source: error)
    }

    private func shouldRetry(exitCode: Int32, stderr: String, timedOut: Bool, attempt _: Int) -> Bool {
        if timedOut {
            return true
        }
        let lower = stderr.lowercased()
        if lower.contains("429") || lower.contains("rate limit") || lower.contains("too many requests") {
            return true
        }
        if lower.contains("overload") || lower.contains("overloaded") || lower.contains("busy") {
            return true
        }
        if lower.contains("502") || lower.contains("503") || lower.contains("504") || lower.contains("gateway") {
            return true
        }
        if lower.contains("timeout") || lower.contains("timed out") || lower.contains("context deadline exceeded") {
            return true
        }
        if lower.contains("econnreset") || lower.contains("connection reset") {
            return true
        }
        if lower.contains("network") || lower.contains("unreachable") {
            return true
        }
        if exitCode == 1 {
            return true
        }
        return false
    }

    private func mapProcessFailure(exitCode: Int32, stderr: String, timedOut: Bool, timeoutValue: TimeInterval?) -> Error {
        if timedOut {
            let seconds = Int(timeoutValue ?? defaultRequestTimeout)
            return AIProviderError.invalidConfiguration(detail: "Claude Code timed out after \(seconds)s. Servers may be busy—please try again.")
        }
        let lower = stderr.lowercased()
        if lower.contains("no such file or directory") || lower.contains("command not found") {
            return AIProviderError.invalidConfiguration(detail: "Claude CLI is not installed or not in PATH. Install it and run `claude login`.")
        }
        if lower.contains("unauthorized") || lower.contains("not authenticated") || lower.contains("authentication") {
            return AIProviderError.invalidConfiguration(detail: "Claude Code is not authenticated. Please run `claude login` in your terminal.")
        }
        if lower.contains("rate limit") || lower.contains("too many requests") || lower.contains("429") {
            return AIProviderError.invalidConfiguration(detail: "Rate limited by Anthropic. We tried retries—please wait a moment and try again.")
        }
        if lower.contains("overload") || lower.contains("overloaded") || lower.contains("busy") || lower.contains("503") {
            return AIProviderError.invalidConfiguration(detail: "Anthropic servers look overloaded. We attempted automatic retries; please try again shortly.")
        }
        if stderr.isEmpty {
            return AIProviderError.apiError(source: NSError(domain: "ClaudeCLI", code: Int(exitCode), userInfo: [NSLocalizedDescriptionKey: "Claude Code failed (exit \(exitCode))."]))
        }
        return AIProviderError.apiError(source: NSError(domain: "ClaudeCLI", code: Int(exitCode), userInfo: [NSLocalizedDescriptionKey: stderr]))
    }

    private func buildPrompt(from aiMessage: AIMessage) -> String {
        let tail = aiMessage.buildTail(embedSystemPrompt: false)
        var prompt = ""
        let lastUserIndex = aiMessage.conversationMessages.lastIndex { $0.role == .user }
        for (index, message) in aiMessage.conversationMessages.enumerated() {
            if !prompt.isEmpty {
                prompt += "\n\n"
            }
            if message.role == .user {
                if index == lastUserIndex, !tail.isEmpty {
                    prompt += "User: \(tail)\n\n\(message.content)"
                } else {
                    prompt += "User: \(message.content)"
                }
            } else {
                prompt += "Assistant: \(message.content)"
            }
        }
        if aiMessage.conversationMessages.isEmpty, !tail.isEmpty {
            prompt = "User: \(tail)"
        }
        return prompt
    }

    private func parseCompletionPayload(_ data: Data) throws -> AICompletionResult {
        if let message = try? decoder.decode(ClaudeResultMessage.self, from: data) {
            return AICompletionResult(
                text: message.result ?? "",
                promptTokens: message.usage?.inputTokens,
                completionTokens: message.usage?.outputTokens,
                cost: message.totalCostUsd
            )
        }
        let json = try JSONSerialization.jsonObject(with: data)
        if let dict = json as? [String: Any] {
            return Self.parseCompletionDictionary(dict)
        } else if let array = json as? [Any] {
            for element in array.reversed() {
                if let dict = element as? [String: Any] {
                    let completion = Self.parseCompletionDictionary(dict)
                    if !completion.text.isEmpty {
                        return completion
                    }
                }
            }
            throw AIProviderError.invalidResponse(detail: "Claude CLI returned JSON array without completion payload")
        } else {
            throw AIProviderError.invalidResponse(detail: "Claude CLI returned unsupported JSON payload")
        }
    }

    private static func parseCompletionDictionary(_ dict: [String: Any]) -> AICompletionResult {
        let usageDict = dict["usage"] as? [String: Any]
        let usage = parseUsage(usageDict)
        let text = extractString(dict["result"]) ?? extractString(dict["content"]) ?? ""
        let cost = dict["total_cost_usd"] as? Double
        return AICompletionResult(
            text: text,
            promptTokens: usage?.inputTokens,
            completionTokens: usage?.outputTokens,
            cost: cost
        )
    }

    private static func extractString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let dict as [String: Any]:
            if let text = dict["text"] as? String {
                return text
            }
            return nil
        case let array as [Any]:
            return array.compactMap { extractString($0) }.joined(separator: "")
        default:
            return nil
        }
    }

    private static func parseUsage(_ value: [String: Any]?) -> TokenUsage? {
        guard let value else { return nil }
        let input = numberToInt(value["input_tokens"]) ?? numberToInt(value["inputTokens"])
        let output = numberToInt(value["output_tokens"]) ?? numberToInt(value["outputTokens"])
        if let input, let output {
            return TokenUsage(inputTokens: input, outputTokens: output)
        }
        return nil
    }

    private static func numberToInt(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            int
        case let double as Double:
            Int(double)
        case let string as String:
            Int(string)
        default:
            nil
        }
    }

    // MARK: - Stream-json completion codec

    private enum StreamJSONScanMode {
        /// Completion parsing: the first malformed line ends the scan.
        case strict
        /// Failure-detail extraction: malformed lines are skipped and the last plain-text line is kept.
        case lenient
    }

    private struct StreamJSONScan {
        var answerText = ""
        var terminal: [String: Any]?
        var sawEvent = false
        var malformedLine: Int?
        var lastPlainLine: String?
    }

    /// Parses the stdout of a `-p --verbose --output-format stream-json` run into one completion.
    ///
    /// The answer is the text of every top-level `assistant` event, in order. The terminal event supplies
    /// usage and cost, and its `result` text only when no assistant text arrived. Output that cannot be
    /// certified complete (a malformed or truncated JSON line, no terminal event, an error terminal)
    /// throws instead of returning a partial answer.
    static func parseStreamJSONCompletionPayload(_ data: Data) throws -> AICompletionResult {
        let scan = scanStreamJSON(data, mode: .strict)
        if let line = scan.malformedLine {
            throw AIProviderError.invalidResponse(detail: "Claude CLI returned malformed stream JSON (line \(line))")
        }
        guard let terminal = scan.terminal else {
            throw AIProviderError.invalidResponse(
                detail: scan.sawEvent
                    ? "Claude CLI returned stream JSON without completion payload"
                    : "Claude CLI returned no stream JSON events"
            )
        }
        if indicatesStreamJSONError(terminal) {
            throw AIProviderError.invalidResponse(
                detail: streamJSONErrorText(in: terminal) ?? "Claude CLI returned an error"
            )
        }
        let completion = parseCompletionDictionary(terminal)
        return AICompletionResult(
            text: scan.answerText.isEmpty ? completion.text : scan.answerText,
            promptTokens: completion.promptTokens,
            completionTokens: completion.completionTokens,
            cost: completion.cost
        )
    }

    /// The error text of a failed stream-json run: the terminal event's error, or the last plain-text
    /// line when the CLI exited before emitting a terminal event (a launch diagnostic, a crash message).
    /// Returns nil when neither exists, so the caller falls back to stderr and exit-status handling.
    static func extractStreamJSONErrorDetail(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let scan = scanStreamJSON(data, mode: .lenient)
        if let terminal = scan.terminal {
            return indicatesStreamJSONError(terminal) ? streamJSONErrorText(in: terminal) : nil
        }
        return scan.lastPlainLine
    }

    private static func scanStreamJSON(_ data: Data, mode: StreamJSONScanMode) -> StreamJSONScan {
        var scan = StreamJSONScan()
        for (index, rawLine) in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
            guard let first = line.first else { continue }
            // Anything that doesn't open a JSON object is a CLI diagnostic such as `[SandboxDebug] ...`.
            guard first == 0x7B else {
                if mode == .lenient,
                   let text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty, !text.hasPrefix("{"), !text.hasPrefix("[")
                {
                    scan.lastPlainLine = text
                }
                continue
            }
            // Token-delta lines are decoded too, so a truncated final line fails the run instead of
            // being skipped.
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                if mode == .strict {
                    scan.malformedLine = index + 1
                    return scan
                }
                continue
            }
            scan.sawEvent = true
            switch (event["type"] as? String)?.lowercased() {
            case "result", "error":
                scan.terminal = event
            case "assistant":
                scan.answerText += topLevelAssistantText(in: event)
            default:
                break
            }
        }
        return scan
    }

    /// Text blocks of an assistant event. Subagent events (a non-null `parent_tool_use_id`) are not part
    /// of the reply, and thinking and tool-use blocks are not answer text.
    private static func topLevelAssistantText(in event: [String: Any]) -> String {
        if let parent = event["parent_tool_use_id"], !(parent is NSNull) {
            return ""
        }
        guard let message = event["message"] as? [String: Any],
              let content = message["content"] as? [Any]
        else { return "" }
        var text = ""
        for case let block as [String: Any] in content where (block["type"] as? String) == "text" {
            if let blockText = block["text"] as? String {
                text += blockText
            }
        }
        return text
    }

    private static func indicatesStreamJSONError(_ event: [String: Any]) -> Bool {
        let type = (event["type"] as? String)?.lowercased()
        let subtype = (event["subtype"] as? String)?.lowercased()
        let isError = (event["is_error"] as? Bool) == true
        let hasErrors = (event["errors"] as? [Any])?.isEmpty == false
        return type == "error" || isError || subtype?.contains("error") == true || hasErrors
    }

    private static func streamJSONErrorText(in event: [String: Any]) -> String? {
        for entry in event["errors"] as? [Any] ?? [] {
            let object = entry as? [String: Any]
            if let text = usableText(object?["message"]) ?? usableText(object?["error"]) ?? usableText(entry) {
                return text
            }
        }
        for key in ["error", "message", "result"] {
            if let text = usableText(event[key]) {
                return text
            }
        }
        return nil
    }

    private static func usableText(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    func testCompatibleBackendConnection(
        _ backendID: ClaudeCodeCompatibleBackendID,
        timeout: TimeInterval? = nil
    ) async throws -> Bool {
        let resolver = ClaudeCodeLaunchEnvironmentResolver()
        let launchEnvironment = try await resolver.resolve(
            variant: Self.runtimeVariant(for: backendID),
            requestedModel: Self.compatibleBackendTestRequestedModel(for: backendID)
        )
        let emptyConfigLease = try await configService.prepareEmptyLaunchConfig()
        defer { emptyConfigLease.release() }
        var options = ClaudeCLIOptions()
        options.disallowedTools = disallowedTools
        options.mcpConfigPath = emptyConfigLease.url.path
        options.model = launchEnvironment.effectiveModel
        options.systemPromptOverride = ClaudeAgentToolPreferences.agentModePromptDelivery().nativeSystemPromptOverride(instructions: "")
        options.timeout = timeout ?? testRequestTimeout
        let args = options.toTokens()
        let additionalEnvironment = options.additionalEnvironment.merging(
            launchEnvironment.environmentOverrides
        ) { _, resolverValue in resolverValue }

        let result: CLIProcessRunner.Result
        do {
            result = try await runner.run(
                args: args,
                stdin: "User: Say OK\n",
                outputMode: .auto(.json),
                timeout: options.timeout,
                additionalEnvironment: additionalEnvironment,
                additionalRemovedKeys: launchEnvironment.removedEnvironmentKeys
            )
        } catch {
            throw mapProcessError(error)
        }
        if result.status != 0 {
            if let humanMessage = extractCLIErrorDetail(fromStdout: result.stdout) {
                throw AIProviderError.invalidConfiguration(detail: humanMessage)
            }
            let stderrString = String(data: result.stderr, encoding: .utf8) ?? ""
            throw mapProcessFailure(exitCode: result.status, stderr: stderrString, timedOut: result.timedOut, timeoutValue: options.timeout)
        }
        guard !result.stdout.isEmpty else {
            let stderrPreview = String(data: result.stderr.prefix(500), encoding: .utf8) ?? "<non-UTF8>"
            throw AIProviderError.invalidResponse(detail: "Claude Code CLI returned empty output. STDERR: \(stderrPreview)")
        }
        do {
            let completion = try parseCompletionPayload(result.stdout)
            return !completion.text.isEmpty
        } catch let error as AIProviderError {
            throw error
        } catch {
            let stdoutPreview = String(data: result.stdout.prefix(500), encoding: .utf8) ?? "<non-UTF8>"
            let stderrPreview = String(data: result.stderr.prefix(500), encoding: .utf8) ?? "<non-UTF8>"
            throw AIProviderError.invalidResponse(detail: "Failed to decode Claude Code CLI response: \(error.localizedDescription). STDOUT (first 500 bytes): \(stdoutPreview). STDERR: \(stderrPreview)")
        }
    }

    private static func runtimeVariant(for backendID: ClaudeCodeCompatibleBackendID) -> ClaudeCodeRuntimeVariant {
        switch backendID {
        case .glmZAI:
            .glm
        case .kimi:
            .kimi
        case .custom:
            .customCompatible
        }
    }

    private static func compatibleBackendTestRequestedModel(for backendID: ClaudeCodeCompatibleBackendID) -> String? {
        let config = ClaudeCodeCompatibleBackendStore.shared.config(for: backendID).normalized
        switch config.modelBehavior {
        case .noModel:
            return nil
        case .claudeSlotMapping:
            return AgentModel.claudeSonnet.rawValue
        }
    }

    func testConnection(timeout: TimeInterval? = nil) async throws -> Bool {
        // First try with a specific model (haiku - fast and cheap)
        do {
            return try await testConnectionWithModel(.claudeCodeHaiku, timeout: timeout)
        } catch {
            // If the first attempt fails, retry without specifying a model
            // This supports users with custom CLI configurations that may not have
            // the standard models available
            return try await testConnectionWithModel(.claudeCode, timeout: timeout)
        }
    }

    private func testConnectionWithModel(_ model: AIModel, timeout: TimeInterval?) async throws -> Bool {
        let emptyConfigLease = try await configService.prepareEmptyLaunchConfig()
        defer { emptyConfigLease.release() }
        var options = try await makeOptions(
            for: AIMessage(systemPrompt: "", userMessage: ""),
            model: model,
            emptyConfigURL: emptyConfigLease.url
        )
        options.systemPromptOverride = ClaudeAgentToolPreferences.agentModePromptDelivery().nativeSystemPromptOverride(instructions: "")
        options.timeout = timeout ?? testRequestTimeout
        let args = options.toTokens()
        let result: CLIProcessRunner.Result
        do {
            result = try await runner.run(
                args: args,
                stdin: "User: Say OK\n",
                outputMode: .auto(.json),
                timeout: options.timeout,
                additionalEnvironment: options.additionalEnvironment
            )
        } catch {
            throw mapProcessError(error)
        }
        if result.status != 0 {
            if let humanMessage = extractCLIErrorDetail(fromStdout: result.stdout) {
                // Check for credit balance error and provide helpful guidance
                let lowerMessage = humanMessage.lowercased()
                if lowerMessage.contains("credit balance") || lowerMessage.contains("balance too low") || lowerMessage.contains("api balance") {
                    throw AIProviderError.invalidConfiguration(detail: "Credit balance is too low. To use Claude Code with your Max plan via RepoPrompt, remove the ANTHROPIC_API_KEY from your environment variables and restart the app. The CLI will then use your Max plan subscription instead of the API key.")
                }
                throw AIProviderError.invalidConfiguration(detail: humanMessage)
            }
            let stderrString = String(data: result.stderr, encoding: .utf8) ?? ""
            throw mapProcessFailure(exitCode: result.status, stderr: stderrString, timedOut: result.timedOut, timeoutValue: options.timeout)
        }
        guard !result.stdout.isEmpty else {
            let stderrPreview = String(data: result.stderr.prefix(500), encoding: .utf8) ?? "<non-UTF8>"
            throw AIProviderError.invalidResponse(detail: "Claude Code CLI returned empty output. STDERR: \(stderrPreview)")
        }
        do {
            // Use parseCompletionPayload to handle both single objects and arrays
            let completion = try parseCompletionPayload(result.stdout)
            return !completion.text.isEmpty
        } catch let error as AIProviderError {
            throw error
        } catch {
            let stdoutPreview = String(data: result.stdout.prefix(500), encoding: .utf8) ?? "<non-UTF8>"
            let stderrPreview = String(data: result.stderr.prefix(500), encoding: .utf8) ?? "<non-UTF8>"
            throw AIProviderError.invalidResponse(detail: "Failed to decode Claude Code CLI response: \(error.localizedDescription). STDOUT (first 500 bytes): \(stdoutPreview). STDERR: \(stderrPreview)")
        }
    }

    /// Attempts to decode a human-readable error exposed by the Claude CLI when it exits non-zero.
    /// Returns nil if stdout is empty or decoding fails. `isStreamJSON` selects the stream-json scanner
    /// for runs that used `--output-format stream-json`.
    private func extractCLIErrorDetail(fromStdout data: Data, isStreamJSON: Bool = false) -> String? {
        guard !data.isEmpty else { return nil }
        if isStreamJSON {
            return Self.extractStreamJSONErrorDetail(from: data)
        }

        // First pass: look for structured JSON errors
        if let message = try? decoder.decode(ClaudeResultMessage.self, from: data),
           let text = message.result?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty
        {
            return text
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = (json["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
            if let text = (json["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
            if let text = (json["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }

        // Second pass: if no JSON found, return plain-text diagnostics (common when CLI fails before JSON mode)
        if let plainText = String(data: data, encoding: .utf8) {
            let cleaned = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip empty strings and JSON noise
            if !cleaned.isEmpty, !cleaned.hasPrefix("{"), !cleaned.hasPrefix("[") {
                return cleaned
            }
        }
        return nil
    }
}
