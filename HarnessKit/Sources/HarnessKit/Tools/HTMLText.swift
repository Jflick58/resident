import Foundation

/// Minimal HTML handling for the web tools: enough to turn a page into
/// readable text without a browser engine.
public enum HTMLText {
    /// Converts HTML to plain text, one paragraph per line.
    public static func plainText(from html: String) -> String {
        var text = html

        // Prefer the main content when the page marks it.
        for tag in ["article", "main"] {
            if let body = firstElement(tag, in: text), body.count > 500 {
                text = body
                break
            }
        }

        for tag in ["script", "style", "noscript", "svg", "nav", "header", "footer", "form", "aside", "iframe", "template"] {
            text = removeElements(tag, from: text)
        }
        text = replace(#"<!--[\s\S]*?-->"#, in: text, with: " ")
        // Block-level boundaries become line breaks.
        text = replace(#"(?i)<\s*(br|/p|/div|/li|/h[1-6]|/tr|/section|/article|/blockquote|/pre)\b[^>]*>"#, in: text, with: "\n")
        text = replace(#"(?i)<\s*li\b[^>]*>"#, in: text, with: "\n- ")
        text = replace(#"<[^>]+>"#, in: text, with: " ")
        text = decodeEntities(text)

        let lines = text.components(separatedBy: .newlines)
            .map { replace(#"[ \t\x{00A0}]+"#, in: $0, with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "-" }
        return joinFragments(lines).joined(separator: "\n")
    }

    /// Puts runs of short fragments back on one line.
    ///
    /// Scoreboards, price tickers and stat boxes are built from many small
    /// boxes, so a score arrives as a column of loose words and numbers with
    /// nothing tying a number to its team. Joined, they read as the row they
    /// were on screen, and take fewer tokens. Repeats next to each other are dropped.
    static func joinFragments(_ lines: [String], shortLimit: Int = 28, rowLimit: Int = 160) -> [String] {
        var result: [String] = []
        var row: [String] = []
        var rowLength = 0
        func flush() {
            if !row.isEmpty { result.append(row.joined(separator: " · ")) }
            row = []
            rowLength = 0
        }
        for line in lines {
            // List items and sentences stand on their own lines.
            let isFragment = line.count <= shortLimit && !line.hasPrefix("- ") && !line.hasPrefix("#")
                && !(line.count > 12 && (line.hasSuffix(".") || line.hasSuffix("?") || line.hasSuffix("!")))
            guard isFragment else {
                flush()
                if result.last != line { result.append(line) }
                continue
            }
            if row.last == line { continue }
            if rowLength + line.count > rowLimit { flush() }
            row.append(line)
            rowLength += line.count + 3
        }
        flush()
        return result
    }

    public static func title(from html: String) -> String? {
        guard let raw = firstElement("title", in: html) else { return nil }
        let title = decodeEntities(replace(#"\s+"#, in: raw, with: " ")).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    public static func stripTags(_ html: String) -> String {
        let text = decodeEntities(replace(#"<[^>]+>"#, in: html, with: ""))
        return replace(#"\s+"#, in: text, with: " ").trimmingCharacters(in: .whitespaces)
    }

    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
            ("&#39;", "'"), ("&#x27;", "'"), ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
            ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&rdquo;", "”"), ("&ldquo;", "“"), ("&copy;", "©"),
            ("&middot;", "·"), ("&bull;", "•"),
        ]
        for (entity, value) in named {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        // Numeric entities: &#123; and &#x1F;
        if let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
            let source = result as NSString
            var output = ""
            var last = 0
            for match in regex.matches(in: result, range: NSRange(location: 0, length: source.length)) {
                output += source.substring(with: NSRange(location: last, length: match.range.location - last))
                let isHex = match.range(at: 1).length > 0
                let digits = source.substring(with: match.range(at: 2))
                if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    output.unicodeScalars.append(scalar)
                }
                last = match.range.location + match.range.length
            }
            output += source.substring(from: last)
            result = output
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func firstElement(_ tag: String, in html: String) -> String? {
        let pattern = "(?is)<\(tag)\\b[^>]*>(.*?)</\(tag)\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
    }

    static func removeElements(_ tag: String, from html: String) -> String {
        replace("(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", in: html, with: " ")
    }

    static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
}

/// Picks the parts of a long text that matter for a question, so a page can be
/// handed to a small model in a few hundred tokens instead of thousands.
public enum PassageRanker {
    static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "is", "are", "was",
        "were", "be", "by", "at", "as", "it", "this", "that", "from", "what", "which", "who", "how",
        "when", "where", "why", "do", "does", "did", "can", "about", "into", "than", "then", "its",
    ]

    static func terms(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) }
    }

    /// Splits text into passages of roughly `size` characters on line boundaries.
    static func passages(_ text: String, size: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if current.count + line.count > size, !current.isEmpty {
                result.append(current)
                current = ""
            }
            if line.count > size {
                // A very long line: cut it on sentence-ish boundaries.
                var rest = Substring(line)
                while rest.count > size {
                    result.append(String(rest.prefix(size)))
                    rest = rest.dropFirst(size)
                }
                current = String(rest)
            } else {
                current += current.isEmpty ? line : "\n" + line
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Returns the passages most relevant to `query`, in page order, within
    /// `limit` characters. With no query, returns the start of the text.
    public static func excerpt(from text: String, query: String?, limit: Int, passageSize: Int = 600) -> String {
        guard text.count > limit else { return text }
        let queryTerms = Set(terms(query ?? ""))
        guard !queryTerms.isEmpty else {
            return String(text.prefix(limit)) + "\n[Page continues.]"
        }

        let all = passages(text, size: passageSize)
        // BM25-style scoring: rarer query terms count for more.
        let passageTerms = all.map { terms($0) }
        var documentFrequency: [String: Int] = [:]
        for list in passageTerms {
            for term in Set(list) where queryTerms.contains(term) {
                documentFrequency[term, default: 0] += 1
            }
        }
        let count = Double(all.count)
        let averageLength = max(1, Double(passageTerms.reduce(0) { $0 + $1.count }) / max(1, count))

        var scored: [(index: Int, score: Double)] = []
        for (index, list) in passageTerms.enumerated() {
            var frequency: [String: Int] = [:]
            for term in list where queryTerms.contains(term) { frequency[term, default: 0] += 1 }
            var score = 0.0
            for (term, tf) in frequency {
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                let norm = Double(tf) * 2.2 / (Double(tf) + 1.2 * (0.25 + 0.75 * Double(list.count) / averageLength))
                score += idf * norm
            }
            scored.append((index, score))
        }

        var chosen: [Int] = []
        var used = 0
        for item in scored.sorted(by: { $0.score > $1.score }) where item.score > 0 {
            let length = all[item.index].count
            if used + length > limit { continue }
            chosen.append(item.index)
            used += length
        }
        if chosen.isEmpty {
            return String(text.prefix(limit)) + "\n[Page continues.]"
        }
        return chosen.sorted().map { all[$0] }.joined(separator: "\n[…]\n")
    }
}
