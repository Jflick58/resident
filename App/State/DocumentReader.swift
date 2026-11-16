import Foundation
import HarnessKit
import PDFKit
import UIKit
import Vision

/// Turns a file the user attached into text the model can read, all on the device.
enum DocumentReader {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    enum Attachment {
        case document(DocumentAttachment)
        case image(Data)
    }

    static let maxBytes = 30_000_000
    static let maxPages = 400

    static func read(_ url: URL) async throws -> Attachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { throw Failure(message: "\(name) could not be opened.") }
        guard data.count <= maxBytes else { throw Failure(message: "\(name) is too large. The limit is 30 MB.") }

        let type = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "bmp"].contains(type) { return .image(data) }

        if type == "pdf" || data.prefix(5) == Data("%PDF-".utf8) {
            guard let pdf = PDFDocument(data: data) else { throw Failure(message: "\(name) is not a readable PDF.") }
            guard !pdf.isLocked else { throw Failure(message: "\(name) is password-protected.") }
            var pages: [String] = []
            for index in 0..<min(pdf.pageCount, maxPages) {
                guard let page = pdf.page(at: index) else { continue }
                var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.isEmpty {
                    // A scanned page has no text of its own: read it from a picture of the page.
                    let image = page.thumbnail(of: CGSize(width: 1600, height: 1600), for: .mediaBox)
                    if let scan = image.jpegData(compressionQuality: 0.8) { text = await recognizeText(in: scan) ?? "" }
                }
                pages.append(text)
            }
            return .document(DocumentAttachment(name: name, parts: pages, partNoun: "page"))
        }

        if ["rtf", "rtfd"].contains(type),
            let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        {
            return .document(DocumentAttachment(name: name, text: rich.string))
        }
        if ["docx", "doc", "pages", "xlsx", "xls", "pptx", "key", "numbers", "zip"].contains(type) {
            throw Failure(message: "\(name): this kind of file cannot be read yet. Export it as a PDF and attach that.")
        }

        // Everything else is tried as text: notes, Markdown, CSV, JSON, code, web pages.
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .isoLatin1),
            !text.contains("\u{0}")
        else { throw Failure(message: "\(name) is not a text file or PDF.") }
        if ["html", "htm"].contains(type) { text = HTMLText.plainText(from: text) }
        return .document(DocumentAttachment(name: name, text: text))
    }

    /// The text visible in a photo or scan, or nil when there is none.
    static func recognizeText(in data: Data) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data)?.cgImage else { return nil }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }.value
    }
}
