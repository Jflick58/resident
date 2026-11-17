import Foundation

/// Where repositories come from and pull requests go to. GitHub in the app, a made-up one in tests.
public protocol RepositoryHost: Sendable {
    /// Puts the repository's files in `directory` and says which branch and commit they are.
    func download(owner: String, repo: String, into directory: URL) async throws -> RepositoryVersion
    /// Commits the files to a new branch made from `draft.commit` and opens a pull request for it.
    func openPullRequest(_ draft: PullRequestDraft) async throws -> OpenedPullRequest
}

public struct RepositoryVersion: Codable, Hashable, Sendable {
    public var branch: String
    public var commit: String
    public init(branch: String, commit: String) {
        self.branch = branch
        self.commit = commit
    }
}

public struct PullRequestDraft: Sendable {
    public var owner: String
    public var repo: String
    /// The branch the pull request asks to merge into.
    public var base: String
    /// The commit the files were downloaded at.
    public var commit: String
    public var branch: String
    public var title: String
    public var body: String
    public var files: [(path: String, text: String)]
}

public struct OpenedPullRequest: Sendable {
    public var number: Int
    public var url: String
    public var branch: String
    /// The commit the pull request holds.
    public var commit: String
    public init(number: Int, url: String, branch: String, commit: String) {
        self.number = number
        self.url = url
        self.branch = branch
        self.commit = commit
    }
}

public struct RepositoryError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// GitHub, through its REST API, with the sign-in of the GitHub connector.
public struct GitHubHost: RepositoryHost {
    /// Repositories larger than this are not downloaded. GitHub reports the size in kilobytes.
    public static let largestRepository = 300 * 1024

    private let api: URL
    private let session: URLSession
    private let token: @Sendable () async -> String?

    public init(api: URL = URL(string: "https://api.github.com")!, session: URLSession = .shared, token: @escaping @Sendable () async -> String?) {
        self.api = api
        self.session = session
        self.token = token
    }

    private func request(_ path: String, method: String = "GET", body: JSONValue? = nil, accept: String = "application/vnd.github+json") async -> URLRequest {
        var request = URLRequest(url: URL(string: api.absoluteString + path)!)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = await token(), !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try? JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// GitHub's own words for a failure, or the status code.
    private static func failure(_ data: Data, _ response: URLResponse, doing what: String) -> RepositoryError {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        var said = json?["message"]?.stringValue ?? "status \(status)"
        if let first = json?["errors"]?.arrayValue?.first, let more = first["message"]?.stringValue ?? first.stringValue { said += ": " + more }
        switch status {
        case 401: return RepositoryError("GitHub did not accept the sign-in. The user needs to sign in again under Settings > Connectors > GitHub.")
        case 403 where what.hasPrefix("save"), 404 where what.hasPrefix("save"):
            return RepositoryError("GitHub would not let this account change the repository (\(said)). The user may not have write access to it.")
        case 404: return RepositoryError("GitHub has no such repository, or this account cannot see it.")
        default: return RepositoryError("GitHub could not \(what): \(said)")
        }
    }

    private func json(_ path: String, method: String = "GET", body: JSONValue? = nil, doing what: String) async throws -> JSONValue {
        let (data, response) = try await session.data(for: await request(path, method: method, body: body))
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { throw Self.failure(data, response, doing: what) }
        return value
    }

    public func download(owner: String, repo: String, into directory: URL) async throws -> RepositoryVersion {
        let base = "/repos/\(owner)/\(repo)"
        let about = try await json(base, doing: "find the repository")
        guard let branch = about["default_branch"]?.stringValue else { throw RepositoryError("GitHub did not name the repository's main branch.") }
        if let size = about["size"]?.intValue, size > Self.largestRepository {
            throw RepositoryError("\(owner)/\(repo) is \(size / 1024) MB, too large to work on here.")
        }
        let head = try await json("\(base)/commits/\(branch)", doing: "read the latest commit")
        guard let commit = head["sha"]?.stringValue else { throw RepositoryError("GitHub did not give the latest commit.") }

        let (archive, response) = try await session.download(for: await request("\(base)/tarball/\(commit)"))
        defer { try? FileManager.default.removeItem(at: archive) }
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw Self.failure(Data(), response, doing: "download the repository")
        }
        do {
            try Tarball.unpack(archive, into: directory)
        } catch {
            throw RepositoryError("The download of \(owner)/\(repo) could not be unpacked.")
        }
        return RepositoryVersion(branch: branch, commit: commit)
    }

    public func openPullRequest(_ draft: PullRequestDraft) async throws -> OpenedPullRequest {
        let base = "/repos/\(draft.owner)/\(draft.repo)"
        let parent = try await json("\(base)/git/commits/\(draft.commit)", doing: "read the commit")
        guard let parentTree = parent["tree"]?["sha"]?.stringValue else { throw RepositoryError("GitHub did not give the commit's files.") }
        let entries = draft.files.map { file -> JSONValue in
            ["path": .string(file.path), "mode": "100644", "type": "blob", "content": .string(file.text)]
        }
        let tree = try await json("\(base)/git/trees", method: "POST", body: ["base_tree": .string(parentTree), "tree": .array(entries)], doing: "save the files")
        guard let treeSHA = tree["sha"]?.stringValue else { throw RepositoryError("GitHub did not save the files.") }
        let made = try await json(
            "\(base)/git/commits", method: "POST",
            body: ["message": .string(draft.title), "tree": .string(treeSHA), "parents": [.string(draft.commit)]], doing: "save the commit")
        guard let commit = made["sha"]?.stringValue else { throw RepositoryError("GitHub did not save the commit.") }

        // A branch of that name may be there from an earlier try: the next free name is used.
        var branch = draft.branch
        for attempt in 2...6 {
            do {
                _ = try await json("\(base)/git/refs", method: "POST", body: ["ref": .string("refs/heads/\(branch)"), "sha": .string(commit)], doing: "save the branch")
                break
            } catch let error as RepositoryError where error.message.contains("already exists") && attempt < 6 {
                branch = "\(draft.branch)-\(attempt)"
            }
        }
        let pull = try await json(
            "\(base)/pulls", method: "POST",
            body: ["title": .string(draft.title), "body": .string(draft.body), "head": .string(branch), "base": .string(draft.base)],
            doing: "open the pull request")
        guard let number = pull["number"]?.intValue, let url = pull["html_url"]?.stringValue else {
            throw RepositoryError("GitHub saved branch \(branch) but did not confirm the pull request.")
        }
        return OpenedPullRequest(number: number, url: url, branch: branch, commit: commit)
    }
}

/// A host with one made-up repository, for tests and the test bed. It keeps the pull requests it is given.
public final class FixedRepositoryHost: RepositoryHost, @unchecked Sendable {
    public let owner: String
    public let repo: String
    public let files: [String: String]
    private let lock = NSLock()
    private var opened: [PullRequestDraft] = []

    public init(owner: String, repo: String, files: [String: String]) {
        self.owner = owner
        self.repo = repo
        self.files = files
    }

    public var pullRequests: [PullRequestDraft] { lock.withLock { opened } }
    public func reset() { lock.withLock { opened = [] } }

    public func download(owner: String, repo: String, into directory: URL) async throws -> RepositoryVersion {
        guard owner.lowercased() == self.owner.lowercased(), repo.lowercased() == self.repo.lowercased() else {
            throw RepositoryError("GitHub has no such repository, or this account cannot see it.")
        }
        for (path, text) in files {
            let target = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: target)
        }
        return RepositoryVersion(branch: "main", commit: "c0ffee0")
    }

    public func openPullRequest(_ draft: PullRequestDraft) async throws -> OpenedPullRequest {
        let number = lock.withLock {
            opened.append(draft)
            return 41 + opened.count
        }
        return OpenedPullRequest(number: number, url: "https://github.com/\(owner)/\(repo)/pull/\(number)", branch: draft.branch, commit: "c0ffee\(number)")
    }
}
