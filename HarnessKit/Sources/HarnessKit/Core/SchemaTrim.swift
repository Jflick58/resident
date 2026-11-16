import Foundation

/// Cuts a tool's definition down to what a small model needs to call it.
///
/// Servers written for large models describe every parameter at length and
/// nest schemas several levels deep; one of Linear's tools is about 2,000
/// tokens as sent. The names, types, allowed values and which parameters are
/// required are kept. Long explanations, validation details and the insides of
/// nested objects are dropped. The server still checks calls against its full
/// schema, so a call the trimmed form allows can only be refused, not misread.
public enum SchemaTrim {
    public static let descriptionLimit = 600
    public static let parameterDescriptionLimit = 120
    public static let enumLimit = 12
    /// Characters of option names written out when a list is longer than `enumLimit`.
    public static let optionListLimit = 320

    /// Keys that only matter to a validator.
    private static let dropped: Set<String> = [
        "$schema", "additionalProperties", "minLength", "maxLength", "pattern", "format", "default", "minItems",
        "maxItems", "minimum", "maximum", "title", "examples",
    ]

    /// A description cut at the end of a sentence where one falls inside the limit.
    public static func shorten(_ text: String, to limit: Int) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let end = head.range(of: ". ", options: .backwards), head.distance(from: head.startIndex, to: end.lowerBound) > limit / 3 {
            return String(head[..<end.lowerBound]) + "."
        }
        let words = head.split(separator: " ").dropLast()
        return words.joined(separator: " ") + "…"
    }

    /// The arguments schema of a tool, trimmed.
    public static func parameters(_ schema: JSONValue) -> JSONValue {
        guard var object = schema.objectValue else { return schema }
        for key in dropped { object[key] = nil }
        if let properties = object["properties"]?.objectValue {
            object["properties"] = .object(properties.mapValues(parameter))
        }
        return .object(object)
    }

    /// A long list of allowed values, written into the description. Listing only
    /// the first few as the allowed values would tell the model the rest do not exist.
    private static func describe(_ values: [JSONValue], after description: String?) -> String {
        var listed: [String] = []
        var length = 0
        for value in values {
            let text = value.stringValue ?? value.jsonString
            if length + text.count > optionListLimit { break }
            listed.append(text)
            length += text.count + 2
        }
        let rest = values.count - listed.count
        let options = "Options: " + listed.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "") + "."
        guard let description, !description.isEmpty else { return options }
        return description + (description.hasSuffix(".") ? " " : ". ") + options
    }

    /// One parameter: its type, allowed values and a short description.
    private static func parameter(_ schema: JSONValue) -> JSONValue {
        guard var object = schema.objectValue else { return schema }
        // "A or nothing" is written as a choice of two; keep the real one.
        for key in ["anyOf", "oneOf"] {
            guard let choices = object[key]?.arrayValue else { continue }
            object[key] = nil
            let real = choices.compactMap(\.objectValue).first { $0["type"]?.stringValue != "null" } ?? [:]
            for (name, value) in real where object[name] == nil { object[name] = value }
        }
        if let types = object["type"]?.arrayValue {
            object["type"] = types.first { $0.stringValue != "null" } ?? "string"
        }
        for key in dropped { object[key] = nil }
        if let description = object["description"]?.stringValue {
            object["description"] = .string(shorten(description, to: parameterDescriptionLimit))
        }
        if let values = object["enum"]?.arrayValue, values.count > enumLimit {
            object["enum"] = nil
            object["description"] = .string(describe(values, after: object["description"]?.stringValue))
        }
        // What is inside a list or a nested object is left to the description.
        if let items = object["items"]?.objectValue {
            var kept: [String: JSONValue] = [:]
            if let type = items["type"] { kept["type"] = type } else if items["oneOf"] != nil || items["anyOf"] != nil { kept["type"] = "object" }
            if let values = items["enum"]?.arrayValue {
                if values.count > enumLimit {
                    object["description"] = .string(describe(values, after: object["description"]?.stringValue))
                } else {
                    kept["enum"] = .array(values)
                }
            }
            object["items"] = .object(kept)
        }
        object["properties"] = nil
        object["required"] = nil
        return .object(object)
    }
}

extension ToolSpec {
    /// About how many tokens declaring this tool costs.
    public var estimatedTokens: Int { functionDeclaration.jsonString.utf8.count / 4 }
}
