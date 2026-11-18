import Foundation

/// Downloads a model repository's files into a local folder.
///
/// Files that are already complete are skipped, so an interrupted download
/// picks up where it left off at file granularity.
public struct ModelDownloader: Sendable {
    public struct Progress: Sendable {
        public var completedBytes: Int64
        public var totalBytes: Int64
        public var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
    }

    private let token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    /// The files a runtime needs: top-level weights, configs, tokenizer files and the chat template.
    public static func neededFiles(in info: HubModelInfo) -> [HubModelInfo.File] {
        let extensions = [".safetensors", ".json", ".jinja", ".txt", ".model"]
        return info.files.filter { file in
            !file.path.contains("/") && extensions.contains { file.path.hasSuffix($0) }
        }
    }

    /// Folder name for a repository, safe for the file system.
    public static func folderName(for repo: String) -> String {
        repo.replacingOccurrences(of: "/", with: "__")
    }

    /// Whether every needed file is present at its full size.
    public static func isComplete(_ info: HubModelInfo, in directory: URL) -> Bool {
        neededFiles(in: info).allSatisfy { Self.isPresent($0, in: directory) }
    }

    static func isPresent(_ file: HubModelInfo.File, in directory: URL) -> Bool {
        isWhole(directory.appendingPathComponent(file.path), size: file.size)
    }

    /// Whether the file at `url` is the whole of one that is `size` bytes where it comes from.
    ///
    /// A weights file used straight from storage has been rearranged for that (its large
    /// tensors moved to page boundaries) and is a little longer than what was downloaded. Its
    /// header says what size it was, in the first few hundred bytes.
    public static func isWhole(_ url: URL, size expected: Int64) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? Int64
        else { return false }
        if expected == 0 { return size > 0 }
        if size == expected { return true }
        guard size > expected, url.pathExtension == "safetensors", let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let start = String(decoding: ((try? handle.read(upToCount: 512)) ?? Data()).dropFirst(8), as: UTF8.self)
        return start.contains("\"\(rearrangedSizeKey)\":\"\(expected)\"")
    }

    /// Removes the second copy of each model's weights that an earlier version of the app kept
    /// beside them (`<name>.paged`): it doubled what a model took on the device, and the weights
    /// file is now used as it is. Returns how many bytes that freed.
    @discardableResult
    public static func removeLeftoverCopies(in modelsDirectory: URL) -> Int64 {
        let manager = FileManager.default
        var freed: Int64 = 0
        for folder in (try? manager.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            where file.pathExtension == "paged" || file.pathExtension == "paged-partial" {
                let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if (try? manager.removeItem(at: file)) != nil { freed += size }
            }
        }
        return freed
    }

    /// The name the engine records a rearranged weights file's first size under. The same
    /// words as `AlignedWeights.sizeKey` in the vendored model library, which writes it.
    static let rearrangedSizeKey = "resident.original_size"

    public func download(
        _ info: HubModelInfo, to directory: URL, progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        let files = Self.neededFiles(in: info)
        guard !files.isEmpty else { throw ProviderError("The repository has no files to download.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var finished: Int64 = 0
        progress(Progress(completedBytes: 0, totalBytes: total))

        for file in files {
            try Task.checkCancellation()
            if Self.isPresent(file, in: directory) {
                finished += file.size
                progress(Progress(completedBytes: finished, totalBytes: total))
                continue
            }
            guard let url = URL(string: "https://huggingface.co/\(info.repo)/resolve/main/\(file.path)") else {
                throw ProviderError("Invalid file path in repository: \(file.path)")
            }
            var request = URLRequest(url: url)
            if let token, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let base = finished
            let delegate = DownloadDelegate { written in
                progress(Progress(completedBytes: base + written, totalBytes: total))
            }
            let (temporary, response) = try await URLSession.shared.download(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: temporary)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 {
                    throw ProviderError("This model is gated. Accept its terms on Hugging Face and add an access token in Settings.")
                }
                throw ProviderError("Download of \(file.path) failed with status \(status).")
            }
            let destination = directory.appendingPathComponent(file.path)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            finished += file.size
            progress(Progress(completedBytes: finished, totalBytes: total))
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onProgress: @Sendable (Int64) -> Void

        init(onProgress: @escaping @Sendable (Int64) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            onProgress(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
