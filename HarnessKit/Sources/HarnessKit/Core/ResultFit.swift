import Foundation

/// Fits a tool's result into the room a small model has for it.
///
/// A list from a real service is mostly long text the model did not ask for:
/// twenty issues arrive with twenty full descriptions, and cutting that at a
/// character limit leaves the first five and no sign of the rest. A model then
/// calls the tool again and again hoping for more. So a JSON result is made
/// smaller where it is bulky before anything is cut off: long strings are
/// shortened, empty values dropped, and only then are items left out, with a
/// note saying how many and what to do about it.
public enum ResultFit {
    /// Lengths that long strings are shortened to, tried in turn until the result fits.
    static let stringCaps = [400, 160, 80]

    /// Whether a result is a JSON list or object, which is made smaller item by item, not read in parts.
    public static func isStructured(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return false }
        return value.arrayValue != nil || value.objectValue != nil
    }

    /// Plain text split into parts of at most `limit` characters, each ending at the end of a line where one is near.
    ///
    /// A file or a page cannot be made smaller the way a list can: every line of it may be the one that matters.
    /// So the model reads it a part at a time.
    public static func parts(_ text: String, limit: Int) -> [String] {
        var parts: [String] = []
        var rest = Substring(text)
        while rest.count > limit {
            let window = rest.prefix(limit)
            // A line break in the last quarter of the window, so a part is never much shorter than it could be.
            let cut = window.lastIndex(of: "\n").flatMap { window.distance(from: window.startIndex, to: $0) > limit * 3 / 4 ? window.index(after: $0) : nil }
                ?? window.endIndex
            parts.append(String(rest[..<cut]))
            rest = rest[cut...]
        }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts
    }

    public static func fit(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
            value.arrayValue != nil || value.objectValue != nil
        else {
            return String(text.prefix(limit)) + "\n[Result cut off at \(limit) characters. Ask for less at a time to see the rest.]"
        }

        let shortened = "\n[Long text was shortened to fit. Ask for one item by its id to read it in full.]"
        for cap in stringCaps {
            let candidate = render(slim(value, cap: cap))
            if candidate.count + shortened.count <= limit { return candidate + shortened }
        }

        // Still too long: keep as many whole items of the list as fit.
        let slimmed = slim(value, cap: stringCaps.last ?? 80)
        if let (items, rebuild) = list(in: slimmed), items.count > 1 {
            var kept = items
            while kept.count > 1 {
                kept.removeLast()
                let note =
                    "\n[Showing the first \(kept.count) of \(items.count) items, with long text shortened. "
                    + "To see others, call again with a filter or a smaller page.]"
                let candidate = render(rebuild(kept))
                if candidate.count + note.count <= limit { return candidate + note }
            }
        }
        let rendered = render(slimmed)
        return String(rendered.prefix(limit)) + "\n[Result cut off at \(limit) characters. Ask for less at a time to see the rest.]"
    }

    /// The list a result is mostly made of: the result itself, or the largest array one level down.
    private static func list(in value: JSONValue) -> (items: [JSONValue], rebuild: ([JSONValue]) -> JSONValue)? {
        if let items = value.arrayValue { return (items, { .array($0) }) }
        guard let object = value.objectValue,
            let (key, items) = object.compactMap({ key, value in value.arrayValue.map { (key, $0) } })
                .max(by: { $0.1.count < $1.1.count })
        else { return nil }
        return (
            items,
            { kept in
                var copy = object
                copy[key] = .array(kept)
                return .object(copy)
            }
        )
    }

    /// The same value with long strings shortened and empty values removed.
    private static func slim(_ value: JSONValue, cap: Int) -> JSONValue {
        switch value {
        case .string(let text):
            return text.count > cap ? .string(String(text.prefix(cap)) + "…") : value
        case .array(let items):
            return .array(items.map { slim($0, cap: cap) })
        case .object(let object):
            var result: [String: JSONValue] = [:]
            for (key, item) in object {
                let slimmed = slim(item, cap: cap)
                switch slimmed {
                case .null: continue
                case .array(let items) where items.isEmpty: continue
                case .object(let inner) where inner.isEmpty: continue
                case .string(let text) where text.isEmpty: continue
                default: result[key] = slimmed
                }
            }
            return .object(result)
        default:
            return value
        }
    }

    /// Keys that say what an item is, written first so they survive any later cut.
    private static let leadingKeys = ["id", "identifier", "key", "name", "title", "status", "state"]

    /// Compact JSON with each object's identifying keys first, then its other
    /// plain values, then anything nested.
    private static func render(_ value: JSONValue) -> String {
        switch value {
        case .array(let items):
            return "[" + items.map(render).joined(separator: ",") + "]"
        case .object(let object):
            func rank(_ key: String) -> Int {
                if let index = leadingKeys.firstIndex(of: key) { return index }
                switch object[key] {
                case .array, .object: return leadingKeys.count + 1
                default: return leadingKeys.count
                }
            }
            let keys = object.keys.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0 < $1 }
            return "{" + keys.map { JSONValue.string($0).jsonString + ":" + render(object[$0] ?? .null) }.joined(separator: ",") + "}"
        default:
            return value.jsonString
        }
    }
}
