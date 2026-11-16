import Foundation

/// A document attached to a user message, already turned into text and split
/// into parts: a PDF's pages, or stretches of a long text file.
public struct DocumentAttachment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var parts: [String]
    /// What a part is called when talking to the model: "page" for a PDF, "part" otherwise.
    public var partNoun: String

    public init(id: UUID = UUID(), name: String, parts: [String], partNoun: String = "part") {
        self.id = id
        self.name = name
        self.parts = parts
        self.partNoun = partNoun
    }

    /// Makes a document from plain text, cut into parts at paragraph breaks.
    public init(name: String, text: String, partSize: Int = 3000) {
        var parts: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n") {
            if current.count + paragraph.count > partSize, !current.isEmpty {
                parts.append(current)
                current = ""
            }
            // A single paragraph longer than a part is cut where it must be.
            var rest = Substring(paragraph)
            while rest.count > partSize {
                parts.append(String(rest.prefix(partSize)))
                rest = rest.dropFirst(partSize)
            }
            current += (current.isEmpty ? "" : "\n") + rest
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(current) }
        self.init(name: name, parts: parts)
    }

    public var characterCount: Int { parts.reduce(0) { $0 + $1.count } }
}

/// Turns a message's attachments into what a given model can take.
///
/// A whole document rarely fits a small model's context, so the model gets the
/// opening of each one and a tool to read the rest. A model that cannot see
/// images gets the text found in a photo instead of the photo.
public enum AttachmentRenderer {
    /// Characters of a document placed directly in the conversation.
    public static let inlineLimit = 3000

    public static func render(_ message: Message, vision: Bool, canReadMore: Bool = true) -> Message {
        guard message.role == .user else { return message }
        var rendered = message
        var notes: [String] = []

        for document in message.documents ?? [] {
            let total = document.characterCount
            guard total > 0 else {
                notes.append("[Attached document \"\(document.name)\": no text could be read from it.]")
                continue
            }
            var shown = ""
            var partsShown = 0
            for part in document.parts {
                if !shown.isEmpty, shown.count + part.count > inlineLimit { break }
                shown += (shown.isEmpty ? "" : "\n") + part
                partsShown += 1
                if shown.count >= inlineLimit { break }
            }
            let cut = shown.count > inlineLimit * 2
            if cut { shown = String(shown.prefix(inlineLimit * 2)) }
            if partsShown == document.parts.count, !cut {
                notes.append("[Attached document \"\(document.name)\", shown in full]\n\(shown)")
            } else {
                let more = canReadMore
                    ? " Call read_document to read other \(document.partNoun)s or search it; do not guess at what is not shown."
                    : " The rest is not available."
                notes.append(
                    "[Attached document \"\(document.name)\": \(document.parts.count) \(document.partNoun)s, \(total) characters. Below is \(document.partNoun) 1\(partsShown > 1 ? " to \(partsShown)" : "").\(more)]\n\(shown)")
            }
        }

        if !vision, !message.images.isEmpty {
            for (index, image) in message.images.enumerated() {
                let label = message.images.count > 1 ? "photo \(index + 1)" : "photo"
                if let text = image.recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    notes.append("[Attached \(label). You cannot see images, but this text was read from it:]\n\(text.prefix(inlineLimit))")
                } else {
                    notes.append("[Attached \(label). You cannot see images and no text was found in it. Tell the user you cannot see this photo.]")
                }
            }
            rendered.images = []
        }

        rendered.documents = nil
        if !notes.isEmpty {
            rendered.text = (notes + (message.text.isEmpty ? [] : [message.text])).joined(separator: "\n\n")
        }
        return rendered
    }
}

/// Reads further into documents attached to the chat.
public struct ReadDocumentTool: Tool {
    public static let name = "read_document"
    public var documents: [DocumentAttachment]

    public init(documents: [DocumentAttachment]) { self.documents = documents }

    public var spec: ToolSpec {
        ToolSpec(
            name: Self.name,
            description:
                "Read more of a document the user attached. Give `part` to read one page or part by number, or `search` to find the passages about something. Use this whenever the answer is not in the part already shown.",
            parameters: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "The document's file name. Not needed when only one is attached."],
                    "part": ["type": "integer", "description": "Page or part number to read, starting at 1"],
                    "search": ["type": "string", "description": "Words to look for"],
                ],
            ])
    }

    public func summary(for arguments: JSONValue) -> String { "Read a document" }

    public func call(_ arguments: JSONValue) async -> ToolResult {
        let wanted = arguments["name"]?.stringValue?.lowercased() ?? ""
        let matches = documents.filter { wanted.isEmpty || $0.name.lowercased().contains(wanted) || wanted.contains($0.name.lowercased()) }
        // With several documents and no clear name, the most recent one is meant.
        guard let document = matches.last ?? documents.last else { return .error("No document is attached to this chat.") }

        if let query = arguments["search"]?.stringValue, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 }
            let scored = document.parts.enumerated().map { index, part -> (index: Int, score: Int) in
                let lower = part.lowercased()
                return (index, words.reduce(0) { $0 + lower.components(separatedBy: $1).count - 1 })
            }.filter { $0.score > 0 }.sorted { $0.score > $1.score }.prefix(2)
            guard !scored.isEmpty else {
                return ToolResult("Nothing in \"\(document.name)\" mentions \(query). It has \(document.parts.count) \(document.partNoun)s; read them by number if you need to check.")
            }
            let text = scored.sorted { $0.index < $1.index }.map { hit in
                "[\(document.partNoun.capitalized) \(hit.index + 1) of \(document.parts.count)]\n"
                    + PassageRanker.excerpt(from: document.parts[hit.index], query: query, limit: 2000)
            }.joined(separator: "\n\n")
            return ToolResult(text)
        }

        guard let number = arguments["part"]?.intValue ?? arguments["page"]?.intValue else {
            return .error("Give `part` (1 to \(document.parts.count)) or `search`.")
        }
        guard (1...max(1, document.parts.count)).contains(number), !document.parts.isEmpty else {
            return .error("\"\(document.name)\" has \(document.parts.count) \(document.partNoun)s. Ask for a number from 1 to \(document.parts.count).")
        }
        let text = document.parts[number - 1]
        return ToolResult("[\(document.partNoun.capitalized) \(number) of \(document.parts.count) of \"\(document.name)\"]\n\(text.prefix(6000))")
    }
}
