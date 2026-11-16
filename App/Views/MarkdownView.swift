import SwiftUI

/// Renders the Markdown that chat models write: paragraphs, headings, lists,
/// quotes, tables and fenced code. Inline styling uses the system parser.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text))
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 4)
        case .list(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(Self.inline(item.text))
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case .quote(let text):
            Text(Self.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(.quaternary).frame(width: 3)
                }
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(Self.inline(cell)).fontWeight(index == 0 ? .semibold : .regular)
                            }
                        }
                        if index == 0 { Divider() }
                    }
                }
                .font(.subheadline)
            }
        case .rule:
            Divider()
        }
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

enum MarkdownBlock: Equatable {
    struct ListItem: Equatable {
        var marker: String
        var text: String
        var indent: Int
    }

    case paragraph(String)
    case heading(Int, String)
    case list([ListItem])
    case quote(String)
    case code(language: String, code: String)
    case table([[String]])
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var list: [ListItem] = []
        var quote: [String] = []
        var table: [[String]] = []

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if !list.isEmpty {
                blocks.append(.list(list))
                list = []
            }
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
            if !table.isEmpty {
                blocks.append(.table(table))
                table = []
            }
        }

        let lines = stripSimpleHTML(text).components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flush()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                // An unterminated fence, as during streaming, runs to the end.
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language, code: code.joined(separator: "\n")))
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flush()
            } else if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count > 1 {
                if table.isEmpty { flush() }
                let cells = trimmed.dropFirst().dropLast().components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // Skip the |---|---| separator row.
                let isSeparator = cells.allSatisfy { cell in
                    !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
                }
                if !isSeparator { table.append(cells) }
            } else if let item = listItem(line) {
                if list.isEmpty { flush() }
                list.append(item)
            } else if trimmed.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if !list.isEmpty {
                // A continuation line of the previous list item.
                list[list.count - 1].text += " " + trimmed
            } else {
                if !quote.isEmpty || !table.isEmpty { flush() }
                paragraph.append(trimmed)
            }
            index += 1
        }
        flush()
        return blocks
    }

    /// Models sometimes reach for HTML that Markdown renderers on the web accept.
    /// Collapsible sections are shown open, with the summary as a bold line.
    static func stripSimpleHTML(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var result = text
        for tag in ["<details>", "</details>", "<details open>"] {
            result = result.replacingOccurrences(of: tag, with: "")
        }
        result = result.replacingOccurrences(of: "<summary>", with: "**")
        result = result.replacingOccurrences(of: "</summary>", with: "**\n")
        for tag in ["<br>", "<br/>", "<br />"] {
            result = result.replacingOccurrences(of: tag, with: "\n")
        }
        return result
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func listItem(_ line: String) -> ListItem? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        let body = line.dropFirst(leading.count)

        for bullet in ["- ", "* ", "+ "] where body.hasPrefix(bullet) {
            return ListItem(marker: "•", text: String(body.dropFirst(2)), indent: indent)
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = body.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return ListItem(marker: "\(digits).", text: String(rest.dropFirst(2)), indent: indent)
            }
        }
        return nil
    }
}
