import Foundation
import MLX

/// Catches what MLX reports as an error, where it would otherwise end the app.
///
/// MLX's default on any error is `fatalError`. The error that matters on a
/// phone is not a bug: iOS lets an app that has left the screen use the
/// graphics processor for a while (about a minute, in a Shortcuts action on iOS
/// 27.2) and then refuses, and the next evaluation fails. The handler here
/// records the message; the engine checks for one as it generates and ends the
/// turn with an error the app can show, or pick up from later.
enum MLXFailure {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var message: String?

    /// Installs the handler, once.
    static let install: Void = {
        // The setter is marked deprecated in favour of handlers scoped to a task,
        // but generation runs in the library's own tasks, which a scoped handler does not reach.
        setErrorHandler({ text, _ in MLXFailure.record(text.map { String(cString: $0) } ?? "MLX reported an error.") })
    }()

    private static func record(_ text: String) {
        lock.withLock { if message == nil { message = text } }
    }

    /// The first error since the last call, if there was one.
    static func take() -> String? {
        lock.withLock {
            defer { message = nil }
            return message
        }
    }
}
