import Foundation
import JavaScriptCore

/// Runs JavaScript in a fresh JavaScriptCore context. The context has no
/// network, file or DOM access, so the code can only compute.
public struct JavaScriptTool: Tool {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: BuiltInTool.runJavaScript.rawValue,
            description:
                "Run JavaScript and get the output. This is the only language you can run. Use it for arithmetic, dates and data work instead of working them out yourself. When asked to write code and no language is named, write JavaScript and run it here to check that it works. A date written as YYYY-MM-DD is read as UTC: use getUTCDay, getUTCDate and the other getUTC methods on it. Use console.log to print; the value of the last expression is also returned. No network, files or DOM.",
            parameters: [
                "type": "object",
                "properties": [
                    "code": ["type": "string", "description": "JavaScript source to run"]
                ],
                "required": ["code"],
            ])
    }

    public func summary(for arguments: JSONValue) -> String { "Ran code" }

    public func call(_ arguments: JSONValue) async -> ToolResult {
        guard let code = arguments["code"]?.stringValue, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .error("Missing required argument: code.") }
        let timeout = timeout

        return await withCheckedContinuation { continuation in
            let gate = ResumeGate(continuation)
            // A dedicated thread: JavaScriptCore has no public way to interrupt a
            // running script, so a runaway loop must not block a shared pool thread.
            let thread = Thread {
                gate.resume(Self.evaluate(code))
            }
            thread.stackSize = 4 << 20
            thread.qualityOfService = .userInitiated
            thread.start()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                gate.resume(.error("The code ran longer than \(Int(timeout)) seconds and was stopped. Check for an infinite loop."))
            }
        }
    }

    static func evaluate(_ code: String) -> ToolResult {
        guard let context = JSContext() else { return .error("Could not start the JavaScript engine.") }
        var output: [String] = []
        var thrown: String?

        let log: @convention(block) () -> Void = {
            let arguments = JSContext.currentArguments() ?? []
            let line = arguments.compactMap { ($0 as? JSValue).map(describe) }.joined(separator: " ")
            output.append(line)
        }
        let console = JSValue(newObjectIn: context)
        for name in ["log", "info", "warn", "error", "debug"] {
            console?.setObject(log, forKeyedSubscript: name as NSString)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSString)
        context.exceptionHandler = { _, exception in
            thrown = exception?.toString() ?? "Unknown error"
        }

        let value = context.evaluateScript(code)
        if let thrown {
            let printed = output.isEmpty ? "" : output.joined(separator: "\n") + "\n"
            return .error(printed + thrown)
        }
        if let value, !value.isUndefined {
            output.append("=> " + describe(value))
        }
        return ToolResult(output.isEmpty ? "(no output)" : output.joined(separator: "\n"))
    }

    /// Renders a value the way a console would: JSON for objects and arrays.
    static func describe(_ value: JSValue) -> String {
        if value.isString { return value.toString() }
        if value.isObject, !value.isDate,
            let stringify = value.context.objectForKeyedSubscript("JSON")?.objectForKeyedSubscript("stringify"),
            let json = stringify.call(withArguments: [value]), json.isString
        {
            return json.toString()
        }
        return value.toString() ?? "undefined"
    }

    /// Ensures the continuation resumes once, whichever of the script and the timeout finishes first.
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ToolResult, Never>?

        init(_ continuation: CheckedContinuation<ToolResult, Never>) {
            self.continuation = continuation
        }

        func resume(_ result: ToolResult) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: result)
        }
    }
}
