import Foundation
import HarnessKit

// The "one shell tool" setup: every capability is a command in a sandboxed
// bash, and the model learns a command by running it with --help.
//
// The interpreter is just-bash running under Node (see shell-bridge/bridge.mjs).
// That is a stand-in for the spike: on a phone the same interpreter would have
// to run inside JavaScriptCore, which this does not test.

/// A command installed in the shell: either a single tool (`search <query>`)
/// or a connector with actions (`calendar list tomorrow`).
struct ShellCommand {
    var name: String
    var summary: String
    /// Action name to tool; a single-tool command uses the empty action.
    var actions: [(action: String, tool: ConnectorTool)]

    var isSingle: Bool { actions.count == 1 && actions[0].action.isEmpty }

    static func usage(_ prefix: String, _ tool: ConnectorTool) -> String {
        let required = tool.params.filter(\.required).map { "<\($0.name)>" }
        let optional = tool.params.filter { !$0.required }.map { "[--\($0.name) <\($0.type)>]" }
        return ([prefix] + required + optional).joined(separator: " ")
    }

    func help(action: String? = nil) -> String {
        func describe(_ prefix: String, _ tool: ConnectorTool) -> String {
            var lines = [Self.usage(prefix, tool), "    " + tool.detail]
            for param in tool.params { lines.append("    \(param.name): \(param.description)") }
            return lines.joined(separator: "\n")
        }
        if isSingle { return describe(name, actions[0].tool) }
        let chosen = actions.filter { action == nil || $0.action == action }
        return "\(name): \(summary)\n\n" + chosen.map { describe("\(name) \($0.action)", $0.tool) }.joined(separator: "\n\n")
    }

    /// Runs the command the way a shell user would type it.
    func run(_ arguments: [String], stdin: String) async -> (stdout: String, stderr: String, exitCode: Int) {
        var arguments = arguments
        if arguments.isEmpty && !isSingle || arguments.first == "--help" || arguments.first == "-h" || arguments.first == "help" {
            return (help() + "\n", "", 0)
        }
        let tool: ConnectorTool
        let prefix: String
        if isSingle {
            tool = actions[0].tool
            prefix = name
        } else {
            let first = arguments.removeFirst()
            let wanted = first.hasPrefix("-") ? first : first.replacingOccurrences(of: "-", with: "_")
            guard let match = actions.first(where: { $0.action == wanted }) else {
                let usages = actions.map { "  " + Self.usage("\(name) \($0.action)", $0.tool) }.joined(separator: "\n")
                return ("", "\(name): the first word after `\(name)` must be an action, not '\(wanted)'. Usage:\n\(usages)\n", 2)
            }
            tool = match.tool
            prefix = "\(name) \(match.action)"
        }
        if arguments.contains("--help") || arguments.contains("-h") {
            return (help(action: isSingle ? nil : tool.action) + "\n", "", 0)
        }

        // Flags fill named parameters; bare words fill the required ones in order.
        var values: [String: String] = [:]
        var positional: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--"), argument.count > 2 {
                var key = String(argument.dropFirst(2)).replacingOccurrences(of: "-", with: "_")
                var value: String?
                if let equals = key.firstIndex(of: "=") {
                    value = String(key[key.index(after: equals)...])
                    key = String(key[..<equals])
                } else if index + 1 < arguments.count {
                    index += 1
                    value = arguments[index]
                }
                guard tool.params.contains(where: { $0.name == key }) else {
                    return ("", "\(prefix): unknown option --\(key).\nUsage: \(Self.usage(prefix, tool))\n", 2)
                }
                values[key] = value ?? "true"
            } else {
                positional.append(argument)
            }
            index += 1
        }
        if positional.isEmpty, !stdin.isEmpty { positional = [stdin.trimmingCharacters(in: .whitespacesAndNewlines)] }
        // Bare words fill the required parameters in order; words left over belong
        // to the last one, so `search swift latest version` works unquoted.
        let slots = tool.params.filter { $0.required && values[$0.name] == nil }
        for (slot, param) in slots.enumerated() where slot < positional.count {
            values[param.name] = slot == slots.count - 1 ? positional[slot...].joined(separator: " ") : positional[slot]
        }
        if let missing = tool.params.first(where: { $0.required && values[$0.name] == nil }) {
            return ("", "\(prefix): missing <\(missing.name)>.\nUsage: \(Self.usage(prefix, tool))\n", 2)
        }

        var object: [String: JSONValue] = [:]
        for param in tool.params {
            guard let value = values[param.name] else { continue }
            switch param.type {
            case "integer": object[param.name] = Int(value).map { .int($0) } ?? .string(value)
            case "boolean": object[param.name] = .bool(["true", "on", "yes", "1"].contains(value.lowercased()))
            default: object[param.name] = .string(value)
            }
        }
        let result = await tool.call(.object(object))
        return result.isError ? ("", result.text + "\n", 1) : (result.text + "\n", "", 0)
    }
}

/// Wraps an ordinary tool as a single shell command, keeping its own schema.
func shellCommand(_ name: String, summary: String, wrapping base: any Tool, recorder: CallRecorder) -> ShellCommand {
    let spec = base.spec
    let required = Set((spec.parameters["required"]?.arrayValue ?? []).compactMap(\.stringValue))
    let properties = spec.parameters["properties"]?.objectValue ?? [:]
    let params = properties.keys.sorted { (required.contains($0) ? 0 : 1, $0) < (required.contains($1) ? 0 : 1, $1) }.map { key in
        Param(
            key, properties[key]?["description"]?.stringValue ?? "",
            type: properties[key]?["type"]?.stringValue ?? "string", required: required.contains(key))
    }
    let recorded = RecordedTool(base: base, recorder: recorder)
    let tool = ConnectorTool(
        group: name, action: "", brief: spec.description, more: "", params: params,
        handler: { values in await recorded.call(.object(values)) })
    return ShellCommand(name: name, summary: summary, actions: [("", tool)])
}

/// The Node process running the interpreter.
final class ShellBridge: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private let commands: [String: ShellCommand]

    init(directory: URL, commands: [ShellCommand]) throws {
        self.commands = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", directory.appendingPathComponent("bridge.mjs").path] + commands.map(\.name)
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
    }

    deinit { process.terminate() }

    private func send(_ message: JSONValue) {
        input.fileHandleForWriting.write((message.jsonString + "\n").data(using: .utf8)!)
    }

    private func readLine() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(data: line, encoding: .utf8)
            }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }

    /// Runs a script and returns what a terminal would show.
    func exec(_ command: String) async -> ToolResult {
        send(["type": "exec", "command": .string(command)])
        while let line = readLine() {
            guard let message = JSONValue(jsonString: line) else { continue }
            switch message["type"]?.stringValue {
            case "call":
                let name = message["name"]?.stringValue ?? ""
                let arguments = (message["args"]?.arrayValue ?? []).compactMap(\.stringValue)
                let result: (stdout: String, stderr: String, exitCode: Int) =
                    await commands[name]?.run(arguments, stdin: message["stdin"]?.stringValue ?? "")
                    ?? (stdout: "", stderr: "\(name): not installed\n", exitCode: 127)
                send([
                    "type": "result", "id": message["id"] ?? 0, "stdout": .string(result.stdout),
                    "stderr": .string(result.stderr), "exitCode": .int(result.exitCode),
                ])
            case "done":
                let stdout = message["stdout"]?.stringValue ?? ""
                let stderr = message["stderr"]?.stringValue ?? ""
                let code = message["exitCode"]?.intValue ?? 0
                var text = stdout
                if !stderr.isEmpty { text += (text.isEmpty ? "" : "\n") + stderr }
                text = text.trimmingCharacters(in: .newlines)
                if text.isEmpty { text = code == 0 ? "(no output)" : "" }
                if code != 0 { text += "\n[exit code \(code)]" }
                return ToolResult(text, isError: code != 0)
            default:
                continue
            }
        }
        return .error("The shell stopped responding.")
    }
}

struct BashTool: Tool {
    var bridge: ShellBridge
    /// Characters of output shown to the model; the rest is cut with a hint.
    var outputLimit = 3000

    var spec: ToolSpec {
        ToolSpec(
            name: "bash",
            description:
                "Run a command in the sandboxed shell and get its output. Pipes, redirection and files work. Each call starts in /home/user; files persist between calls.",
            parameters: [
                "type": "object",
                "properties": ["command": ["type": "string", "description": "The shell command line to run"]],
                "required": ["command"],
            ])
    }

    func summary(for arguments: JSONValue) -> String { "Ran a command" }

    func call(_ arguments: JSONValue) async -> ToolResult {
        guard let command = arguments["command"]?.stringValue, !command.isEmpty else {
            return .error("Give a command to run.")
        }
        var result = await bridge.exec(command)
        if result.text.count > outputLimit {
            result.text =
                String(result.text.prefix(outputLimit))
                + "\n[Output cut at \(outputLimit) characters. Redirect to a file and use grep or head to see specific parts.]"
        }
        return result
    }
}
