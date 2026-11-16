import Foundation

/// Fetches bytes for the web tools. A protocol so tests can run offline.
public protocol HTTPFetching: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionFetcher: HTTPFetching {
    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration)
    }

    public func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError("The server did not return an HTTP response.")
        }
        return (data, http)
    }
}

enum WebRequest {
    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func make(_ url: URL, method: String = "GET", form: [String: String]? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let form {
            var components = URLComponents()
            components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

public struct SearchResult: Hashable, Sendable {
    public var title: String
    public var url: String
    public var snippet: String
}

/// Web search straight from the device against DuckDuckGo's HTML endpoint. No
/// account or key; only the query leaves the device.
public struct WebSearchTool: Tool {
    private let fetcher: any HTTPFetching
    private let maxResults: Int

    public init(fetcher: any HTTPFetching = URLSessionFetcher(), maxResults: Int = 5) {
        self.fetcher = fetcher
        self.maxResults = maxResults
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: BuiltInTool.webSearch.rawValue,
            description: "Search the public web for news, prices, versions and anything recent, which you do not know from memory. Returns titles, URLs and snippets. Follow up with fetch_page to read a result.",
            parameters: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Search terms, a few keywords"]
                ],
                "required": ["query"],
            ])
    }

    public func summary(for arguments: JSONValue) -> String {
        "Searched the web for “\(arguments["query"]?.stringValue ?? "")”"
    }

    public func call(_ arguments: JSONValue) async -> ToolResult {
        guard let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespaces),
            !query.isEmpty
        else { return .error("Missing required argument: query.") }

        do {
            let results = try await search(query)
            guard !results.isEmpty else {
                return ToolResult("No results for “\(query)”. Try different keywords.")
            }
            let lines = results.prefix(maxResults).enumerated().map { index, result in
                "\(index + 1). \(result.title)\n   \(result.url)\n   \(result.snippet)"
            }
            return ToolResult(lines.joined(separator: "\n"))
        } catch {
            return .error("Search failed: \(error.localizedDescription)")
        }
    }

    func search(_ query: String) async throws -> [SearchResult] {
        let url = URL(string: "https://html.duckduckgo.com/html/")!
        let (data, response) = try await fetcher.fetch(
            WebRequest.make(url, method: "POST", form: ["q": query, "kl": "us-en"]))
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError("The search engine returned status \(response.statusCode).")
        }
        return Self.parseResults(WebRequest.decode(data))
    }

    /// Extracts results from DuckDuckGo's HTML results page.
    static func parseResults(_ html: String) -> [SearchResult] {
        let linkPattern = #"(?is)<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"(?is)<a[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>"#
        guard let linkRegex = try? NSRegularExpression(pattern: linkPattern),
            let snippetRegex = try? NSRegularExpression(pattern: snippetPattern)
        else { return [] }

        let source = html as NSString
        let full = NSRange(location: 0, length: source.length)
        let links = linkRegex.matches(in: html, range: full)
        let snippets = snippetRegex.matches(in: html, range: full)

        var results: [SearchResult] = []
        for (index, match) in links.enumerated() {
            let href = HTMLText.decodeEntities(source.substring(with: match.range(at: 1)))
            let title = HTMLText.stripTags(source.substring(with: match.range(at: 2)))
            guard let url = resolveRedirect(href), !title.isEmpty else { continue }
            // Skip sponsored results, which route through DuckDuckGo's ad redirect.
            if url.contains("duckduckgo.com/y.js") { continue }

            // The snippet for a result is the first one that appears after its link
            // and before the next result's link.
            let nextStart = index + 1 < links.count ? links[index + 1].range.location : source.length
            let snippet = snippets.first {
                $0.range.location > match.range.location && $0.range.location < nextStart
            }.map { HTMLText.stripTags(source.substring(with: $0.range(at: 1))) } ?? ""
            results.append(SearchResult(title: title, url: url, snippet: snippet))
        }
        return results
    }

    /// DuckDuckGo wraps result links as `//duckduckgo.com/l/?uddg=<encoded target>`.
    static func resolveRedirect(_ href: String) -> String? {
        var link = href
        if link.hasPrefix("//") { link = "https:" + link }
        guard let components = URLComponents(string: link) else { return nil }
        if components.host?.hasSuffix("duckduckgo.com") == true, components.path == "/l/",
            let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value
        {
            return target
        }
        return link.hasPrefix("http") ? link : nil
    }
}

/// Reads a web page and returns the parts relevant to a question.
public struct FetchPageTool: Tool {
    private let fetcher: any HTTPFetching
    private let maxCharacters: Int

    public init(fetcher: any HTTPFetching = URLSessionFetcher(), maxCharacters: Int = 4000) {
        self.fetcher = fetcher
        self.maxCharacters = maxCharacters
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: BuiltInTool.fetchPage.rawValue,
            description: "Read a web page as text. Give `question` to get only the parts of a long page that matter.",
            parameters: [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "Full URL starting with https://"],
                    "question": ["type": "string", "description": "What you want to learn from the page"],
                ],
                "required": ["url"],
            ])
    }

    public func summary(for arguments: JSONValue) -> String {
        let raw = arguments["url"]?.stringValue ?? ""
        let host = URL(string: raw)?.host?.replacingOccurrences(of: "www.", with: "") ?? raw
        return "Read \(host)"
    }

    public func call(_ arguments: JSONValue) async -> ToolResult {
        guard var raw = arguments["url"]?.stringValue?.trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return .error("Missing required argument: url.") }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), let scheme = url.scheme, ["http", "https"].contains(scheme),
            url.host != nil
        else { return .error("That is not a valid web address: \(raw)") }

        do {
            let (data, response) = try await fetcher.fetch(WebRequest.make(url))
            guard (200..<300).contains(response.statusCode) else {
                return .error("The page returned status \(response.statusCode).")
            }
            let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if !contentType.isEmpty, !contentType.contains("text"), !contentType.contains("json"),
                !contentType.contains("xml")
            {
                return .error("That address is not a text page (\(contentType)).")
            }

            let body = WebRequest.decode(data)
            let isHTML = contentType.contains("html") || body.range(of: "<html", options: .caseInsensitive) != nil
            let text = isHTML ? HTMLText.plainText(from: body) : body
            guard text.count > 40 else {
                return .error("The page had no readable text. It may need JavaScript to load.")
            }
            let title = isHTML ? HTMLText.title(from: body) : nil
            let excerpt = PassageRanker.excerpt(
                from: text, query: arguments["question"]?.stringValue, limit: maxCharacters)
            return ToolResult((title.map { "# \($0)\n" } ?? "") + excerpt)
        } catch {
            return .error("Could not load the page: \(error.localizedDescription)")
        }
    }
}
