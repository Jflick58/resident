import Foundation
import HarnessKit
import NaturalLanguage

// Picks the tools most likely to matter for a request, so only those need to be
// described to the model. Two signals are fused: the system's sentence
// embeddings (meaning) and keyword overlap (exact names such as "GitHub").

struct ToolIndex {
    struct Entry {
        var spec: ToolSpec
        var text: String
        var vector: [Double]?
        var terms: [String: Int]
    }

    enum Method: String { case embedding, keyword, fused }

    private(set) var entries: [Entry] = []
    let embedderName: String
    private let embed: (String) -> [Double]?

    init(tools: [ToolSpec]) {
        let (name, embed) = Self.makeEmbedder()
        embedderName = name
        self.embed = embed
        entries = tools.map { spec in
            // Underscores split so "travel_time" matches "time".
            let text = spec.name.replacingOccurrences(of: "_", with: " ") + ". " + spec.description
            return Entry(spec: spec, text: text, vector: embed(text), terms: Self.termCounts(text))
        }
    }

    /// Tools ranked for a request, best first.
    func rank(_ query: String, method: Method = .fused) -> [ToolSpec] {
        let byEmbedding = embeddingOrder(query)
        let byKeyword = keywordOrder(query)
        switch method {
        case .embedding: return byEmbedding.map { entries[$0].spec }
        case .keyword: return byKeyword.map { entries[$0].spec }
        case .fused:
            // Reciprocal rank fusion: a tool high on either list rises.
            var score = [Double](repeating: 0, count: entries.count)
            for (rank, index) in byEmbedding.enumerated() { score[index] += 1 / Double(20 + rank) }
            for (rank, index) in byKeyword.enumerated() { score[index] += 1 / Double(20 + rank) }
            return entries.indices.sorted { score[$0] > score[$1] }.map { entries[$0].spec }
        }
    }

    private func embeddingOrder(_ query: String) -> [Int] {
        guard let vector = embed(query) else { return Array(entries.indices) }
        let scores = entries.map { entry in entry.vector.map { Self.cosine($0, vector) } ?? -1 }
        return entries.indices.sorted { scores[$0] > scores[$1] }
    }

    private func keywordOrder(_ query: String) -> [Int] {
        let queryTerms = Set(Self.termCounts(query).keys)
        let count = Double(entries.count)
        let averageLength = entries.reduce(0.0) { $0 + Double($1.terms.values.reduce(0, +)) } / max(1, count)
        var documentFrequency: [String: Double] = [:]
        for term in queryTerms {
            documentFrequency[term] = Double(entries.filter { $0.terms[term] != nil }.count)
        }
        let scores = entries.map { entry -> Double in
            let length = Double(entry.terms.values.reduce(0, +))
            return queryTerms.reduce(0.0) { total, term in
                guard let frequency = entry.terms[term].map(Double.init), let df = documentFrequency[term] else { return total }
                let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                return total + idf * frequency * 2.2 / (frequency + 1.2 * (0.25 + 0.75 * length / averageLength))
            }
        }
        return entries.indices.sorted { scores[$0] > scores[$1] }
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "of", "to", "in", "on", "for", "and", "or", "is", "are", "my", "me", "i", "it", "do", "does",
        "what", "how", "any", "at", "from", "with", "that", "this", "have", "has", "will", "be", "use", "user", "s",
    ]

    static func termCounts(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var term = String(word)
            if term.count > 3, term.hasSuffix("s") { term.removeLast() }
            if stopWords.contains(term) { continue }
            counts[term, default: 0] += 1
        }
        return counts
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        return normA > 0 && normB > 0 ? dot / (normA.squareRoot() * normB.squareRoot()) : -1
    }

    /// The system's contextual embedding model when its assets are present,
    /// otherwise the older static sentence embedding.
    private static func makeEmbedder() -> (String, (String) -> [Double]?) {
        if let model = NLContextualEmbedding(language: .english), model.hasAvailableAssets, (try? model.load()) != nil {
            return (
                "NLContextualEmbedding",
                { text in
                    guard let result = try? model.embeddingResult(for: text, language: .english) else { return nil }
                    var sum = [Double](repeating: 0, count: model.dimension)
                    var count = 0.0
                    result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                        for index in 0..<min(sum.count, vector.count) { sum[index] += vector[index] }
                        count += 1
                        return true
                    }
                    return count > 0 ? sum.map { $0 / count } : nil
                }
            )
        }
        if let model = NLEmbedding.sentenceEmbedding(for: .english) {
            return ("NLEmbedding.sentence", { model.vector(for: $0) })
        }
        return ("none", { _ in nil })
    }
}

/// Lets the model ask for tools by describing what it needs.
struct FindToolsTool: Tool {
    var index: ToolIndex
    var count = 4

    var spec: ToolSpec {
        ToolSpec(
            name: "find_tools",
            description:
                "Find tools for a job you have no listed tool for. Describe what you need in a few words. Returns tools you can then call directly.",
            parameters: [
                "type": "object",
                "properties": ["need": ["type": "string", "description": "What you need to do, e.g. \"check the calendar\""]],
                "required": ["need"],
            ])
    }

    func summary(for arguments: JSONValue) -> String { "Looked for tools" }

    func call(_ arguments: JSONValue) async -> ToolResult {
        let need = arguments["need"]?.stringValue ?? ""
        let found = Array(index.rank(need).prefix(count))
        return ToolResult("You can now call these tools:\n" + ToolDisclosure.block(found))
    }
}

enum ToolDisclosure {
    /// Tool definitions as text, in the form chat templates use for declared tools.
    static func block(_ tools: [ToolSpec]) -> String {
        "<tools>\n" + tools.map(\.functionDeclaration.jsonString).joined(separator: "\n") + "\n</tools>"
    }

    /// The user's request with the tools picked for it attached.
    static func attach(_ tools: [ToolSpec], to prompt: String) -> String {
        guard !tools.isEmpty else { return prompt }
        return prompt + "\n\n[These tools may help with this request. Call them like any other tool.]\n" + block(tools)
    }
}
