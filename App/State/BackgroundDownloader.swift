import Foundation
import HarnessKit
import UIKit

/// A model download in flight, saved to disk so it survives the app being closed.
struct PendingInstall: Codable, Hashable, Identifiable {
    struct File: Codable, Hashable {
        var path: String
        var size: Int64
    }

    var repo: String
    var name: String
    var files: [File]
    var contextTokens: Int
    var capabilities: ModelCapabilities

    var id: String { repo }
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// Downloads model files, at full speed while the app is open and still
/// running after it is put away.
///
/// iOS can carry on a transfer in its own process while an app is in the
/// background or has been closed, and relaunch the app to hand over the file,
/// but it runs such transfers far slower than the connection allows (measured
/// on an iPhone: 0.2 MB a second where the same network gave 47). So transfers
/// run in an ordinary session while the app is on screen and are handed to the
/// background session, keeping what has arrived, when the app leaves it.
final class BackgroundDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundDownloader()
    static let sessionIdentifier = AppIdentity.bundleID + ".model-downloads"

    /// Called on the main actor as bytes arrive: repository and bytes received by its running transfers.
    var onProgress: (@MainActor (String, Int64) -> Void)?
    /// Called on the main actor when a repository has no transfers left. The error is the first one seen, if any.
    var onFinished: (@MainActor (String, String?) -> Void)?
    /// Given by the system when it relaunches the app for this session; called once events are delivered.
    var systemCompletionHandler: (() -> Void)?

    private let lock = NSLock()
    /// Bytes received so far by each running task, grouped by repository.
    private var received: [String: [String: Int64]] = [:]
    private var errors: [String: String] = [:]
    private var modelsDirectory: URL?
    /// Transfers being handed from one session to the other, whose ending is not a failure.
    private var moving: Set<String> = []
    /// Whether the app is on screen, which decides the session new transfers start in.
    private var isActive = false

    /// Used while the app is on screen.
    private lazy var foreground: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Used while the app is not on screen.
    private lazy var background: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        // The user asked for this download; do not wait for the system's idea of a good time.
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Connects to the session. Call at launch so transfers that finished while
    /// the app was not running are delivered.
    func start(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
        _ = background
    }

    private func allTasks() async -> [URLSessionTask] {
        let first = await foreground.allTasks
        let second = await background.allTasks
        return (first + second).filter { $0.state == .running || $0.state == .suspended }
    }

    /// Repositories that still have transfers running.
    func activeRepos() async -> Set<String> {
        Set(await allTasks().compactMap { Self.parse($0.taskDescription)?.repo })
    }

    /// Tells the downloader whether the app is on screen, and moves running
    /// transfers to the session that suits: fast while it is, lasting while it is not.
    func setActive(_ active: Bool) {
        lock.lock()
        let changed = isActive != active
        isActive = active
        lock.unlock()
        guard changed else { return }
        let source = active ? background : foreground
        let target = active ? foreground : background
        // The handover needs a moment after the app leaves the screen.
        let application = UIApplication.shared
        var permit = UIBackgroundTaskIdentifier.invalid
        permit = application.beginBackgroundTask {
            application.endBackgroundTask(permit)
            permit = .invalid
        }
        source.getAllTasks { [self] tasks in
            let group = DispatchGroup()
            for case let task as URLSessionDownloadTask in tasks where task.state == .running {
                guard let description = task.taskDescription, let original = task.originalRequest else { continue }
                let expected = task.countOfBytesClientExpectsToReceive
                lock.lock()
                moving.insert(key(source, task))
                lock.unlock()
                group.enter()
                task.cancel { data in
                    // Resume data carries on from the bytes already received.
                    let next = data.map { target.downloadTask(withResumeData: $0) } ?? target.downloadTask(with: original)
                    next.taskDescription = description
                    next.countOfBytesClientExpectsToReceive = expected
                    next.resume()
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                if permit != .invalid { application.endBackgroundTask(permit) }
            }
        }
    }

    private func key(_ session: URLSession, _ task: URLSessionTask) -> String {
        (session === background ? "b" : "f") + String(task.taskIdentifier)
    }

    /// Starts a transfer for every file of the install that is not already complete on disk.
    func download(_ install: PendingInstall, token: String? = nil) {
        guard let directory = directory(for: install.repo) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lock.lock()
        errors[install.repo] = nil
        lock.unlock()

        lock.lock()
        let session = isActive ? foreground : background
        lock.unlock()
        Task {
            // A file that already has a transfer running is not started a second time.
            let running = Set(await allTasks().compactMap(\.taskDescription))
            var waiting = 0
            for file in install.files where !Self.isPresent(file, in: directory) {
                let description = "\(install.repo)|\(file.path)"
                waiting += 1
                guard !running.contains(description),
                    let url = URL(string: "https://huggingface.co/\(install.repo)/resolve/main/\(file.path)")
                else { continue }
                var request = URLRequest(url: url)
                if let token, !token.isEmpty {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                let task = session.downloadTask(with: request)
                task.taskDescription = description
                task.countOfBytesClientExpectsToReceive = file.size
                task.resume()
            }
            if waiting == 0 {
                let handler = onFinished
                await MainActor.run { handler?(install.repo, nil) }
            }
        }
    }

    func cancel(repo: String) {
        for session in [foreground, background] {
            session.getAllTasks { tasks in
                for task in tasks where Self.parse(task.taskDescription)?.repo == repo { task.cancel() }
            }
        }
        lock.lock()
        received[repo] = nil
        lock.unlock()
    }

    /// Bytes of the install already complete on disk.
    func completedBytes(of install: PendingInstall) -> Int64 {
        guard let directory = directory(for: install.repo) else { return 0 }
        return install.files.filter { Self.isPresent($0, in: directory) }.reduce(0) { $0 + $1.size }
    }

    func isComplete(_ install: PendingInstall) -> Bool {
        guard let directory = directory(for: install.repo) else { return false }
        return install.files.allSatisfy { Self.isPresent($0, in: directory) }
    }

    // MARK: Helpers

    private func directory(for repo: String) -> URL? {
        modelsDirectory?.appendingPathComponent(ModelDownloader.folderName(for: repo), isDirectory: true)
    }

    static func isPresent(_ file: PendingInstall.File, in directory: URL) -> Bool {
        let path = directory.appendingPathComponent(file.path).path
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 else { return false }
        return file.size == 0 ? size > 0 : size == file.size
    }

    static func parse(_ description: String?) -> (repo: String, path: String)? {
        guard let parts = description?.split(separator: "|", maxSplits: 1), parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let item = Self.parse(downloadTask.taskDescription) else { return }
        lock.lock()
        received[item.repo, default: [:]][key(session, downloadTask)] = totalBytesWritten
        let total = received[item.repo]?.values.reduce(0, +) ?? 0
        lock.unlock()
        let handler = onProgress
        Task { @MainActor in handler?(item.repo, total) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is removed when this method returns, so move it now.
        guard let item = Self.parse(downloadTask.taskDescription), let directory = directory(for: item.repo) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            lock.lock()
            errors[item.repo] =
                status == 401 || status == 403
                ? "This model is gated. Accept its terms on Hugging Face first."
                : "Download of \(item.path) failed with status \(status)."
            lock.unlock()
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(item.path)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.lock()
            errors[item.repo] = "Could not save \(item.path): \(error.localizedDescription)"
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let item = Self.parse(task.taskDescription) else { return }
        lock.lock()
        received[item.repo]?[key(session, task)] = nil
        // A transfer handed to the other session carries on there.
        if moving.remove(key(session, task)) != nil {
            lock.unlock()
            return
        }
        if let error, (error as? URLError)?.code != .cancelled, errors[item.repo] == nil {
            errors[item.repo] = error.localizedDescription
        }
        lock.unlock()

        // Report once the repository's last transfer has ended.
        Task {
            let remaining = await allTasks().contains {
                $0 !== task && Self.parse($0.taskDescription)?.repo == item.repo && $0.state == .running
            }
            guard !remaining else { return }
            lock.withLock { received[item.repo] = nil }
            let message = lock.withLock { errors[item.repo] }
            let handler = onFinished
            await MainActor.run { handler?(item.repo, message) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.systemCompletionHandler?()
            self.systemCompletionHandler = nil
        }
    }
}

/// Receives the system's wake-up when background downloads finish while the app is not running.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundDownloader.sessionIdentifier else {
            completionHandler()
            return
        }
        BackgroundDownloader.shared.systemCompletionHandler = completionHandler
    }
}
