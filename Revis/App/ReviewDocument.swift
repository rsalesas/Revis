import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

extension UTType {
    /// A saved review: the document snapshot plus the marks on it.
    static let revisReview = UTType(exportedAs: "app.revis.review")
    /// Imported, not exported — the identifier belongs to Daring Fireball and is declared
    /// already by every Markdown editor on the disk. See `project.yml`.
    static let markdown = UTType(importedAs: "net.daringfireball.markdown",
                                 conformingTo: .plainText)
}

/// Where the document under review came from.
struct SourceInfo: Codable, Equatable, Sendable {
    /// The original file's name, for the window title and the export's heading.
    var name: String
    /// Its path when the review was started. Kept for the reader's benefit only — nothing
    /// re-reads it, because a review holds its own snapshot.
    var path: String?
    var capturedAt: Date
    /// SHA-256 of the ORIGINAL bytes, before sanitizing.
    ///
    /// It answers a question that comes up the moment a review is handed back: is this
    /// the same document I sent? Comparing snapshots would not do it — the snapshot has
    /// been rewritten — so the digest is taken of what arrived.
    var digest: String

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The `.revis` file.
///
/// **Why a review owns a snapshot of the document rather than pointing at it.**
///
/// Every annotation is anchored to text — an offset into a block, a quote, a path. If the
/// review only remembered where the HTML lived, then regenerating that HTML (which is
/// exactly what happens: the whole point is that an assistant acts on the review and
/// produces a new version) would leave every anchor pointing into a document that no
/// longer exists. The marks would be, at best, approximately right, and there would be no
/// way to tell which ones had drifted.
///
/// Holding the snapshot makes a review a closed, self-describing object: it says what was
/// reviewed and what was said about it, and it says so identically a year later. The new
/// version of the document gets a new review, which is the honest description of what it
/// is.
struct ReviewFile: Codable, Equatable, Sendable {
    /// Bumped when the shape changes. Read on load so an older file can be migrated
    /// rather than refused.
    var format: Int = 1
    /// Which build wrote it — the first thing anyone wants when a file will not open.
    var app: String = "Revis \(AppVersion.marketing)"
    var source: SourceInfo
    /// The sanitized document. Stored prepared, so reopening a review never re-runs the
    /// sanitizer and can never produce a different document from the one that was marked.
    var document: PreparedDocument
    var annotations: [Annotation] = []
}

/// The per-window document.
///
/// Readable as both a review and as raw HTML; writable only as a review. Opening an
/// `.html` therefore starts a review of it and the first save asks where to put the
/// `.revis` — which is the right shape, because reviewing a file should never modify it.
struct ReviewDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.revisReview, .html, .markdown] }
    static var writableContentTypes: [UTType] { [.revisReview] }

    var file: ReviewFile

    /// Raw HTML that still has to be prepared.
    ///
    /// Preparation needs the folder the file came from, to resolve its images — and a
    /// `FileDocument` is handed bytes, not a URL. So an imported document is parked here
    /// and prepared by the window, which does know where it came from. See
    /// `ReviewRootView`.
    var pendingHTML: String?

    /// Markdown that still has to be rendered and prepared, for the same reason.
    var pendingMarkdown: String?

    /// A new, empty review. Reachable through File ▸ New; the window shows it as the
    /// place to open a document rather than as a blank page.
    init() {
        file = ReviewFile(source: SourceInfo(name: "Untitled", path: nil,
                                             capturedAt: .reviewStamp, digest: ""),
                          document: .empty)
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()

        // Decided by CONTENT, not by the declared type. Launch Services will hand us
        // `public.html` for a `.revis` renamed by hand and vice versa, and a review that
        // refused to open because of its extension would be a review lost.
        if let decoded = try? JSONDecoder.revis.decode(ReviewFile.self, from: data) {
            file = decoded
            return
        }

        let text = String(decoding: data, as: UTF8.self)
        let name = configuration.file.filename ?? "Document"
        file = ReviewFile(
            source: SourceInfo(name: name, path: nil, capturedAt: .reviewStamp,
                               digest: SourceInfo.digest(of: data)),
            document: .empty)

        // HTML or Markdown, and here the declared type DOES get a say — unlike the review
        // above, which is decided by content because a `.revis` either parses as one or
        // does not. No such test exists between these two: a Markdown file is plain text,
        // and plain text containing `<p>` is a legitimate Markdown document that happens to
        // embed HTML. So the name is asked first (it is what the author meant), and the
        // declared type only where there is no name to ask.
        if isMarkdown(name: name, type: configuration.contentType) {
            pendingMarkdown = text
        } else {
            pendingHTML = text
        }
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    private func isMarkdown(name: String, type: UTType?) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if Self.markdownExtensions.contains(ext) { return true }
        if ext == "html" || ext == "htm" { return false }
        return type?.conforms(to: .markdown) ?? false
    }

    /// Writes the review, and **only** ever the review.
    ///
    /// The type check is not defensive programming for its own sake; it is the guarantee
    /// the whole app rests on. Reviewing a file must never modify it, and a document
    /// opened from HTML is one autosave away from having a JSON review written over the
    /// specification somebody sent you — which is not a bug you get to apologise for,
    /// because the original is gone.
    ///
    /// `ReviewRootView` detaches an imported document from its source URL so this path is
    /// never reached in normal use. This is what holds if that fails: refusing to write is
    /// always recoverable, and writing the wrong thing is not.
    /// Whether a write of `type` may go ahead.
    ///
    /// Split out from `fileWrapper` so it can be tested at all:
    /// `FileDocumentWriteConfiguration` has no public initialiser, so a test cannot call
    /// the write path directly — and this is the last invariant in the app that should be
    /// left resting on nobody having checked it.
    static func canWrite(_ type: UTType) -> Bool { type == .revisReview }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard Self.canWrite(configuration.contentType) else {
            throw ReviewWriteError.wouldOverwriteSource(configuration.contentType)
        }
        return FileWrapper(regularFileWithContents: try JSONEncoder.revis.encode(file))
    }
}

enum ReviewWriteError: LocalizedError {
    case wouldOverwriteSource(UTType)

    var errorDescription: String? {
        "Revis will not save over the document being reviewed."
    }

    var recoverySuggestion: String? {
        "A review is saved as its own .revis file. Choose File ▸ Save As… and give it a"
            + " name; the document you are reviewing is left exactly as it was."
    }
}

extension JSONEncoder {
    /// One encoder for the file format, so what is written and what is read cannot drift.
    /// Sorted keys and pretty printing because a `.revis` will end up in a repository and
    /// a diff of one should be readable.
    static var revis: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var revis: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Carries the frontmost window's model to menu commands, so a command acts on the window
/// you are looking at rather than on a shared singleton.
struct ActiveReviewKey: FocusedValueKey { typealias Value = ReviewModel }
extension FocusedValues {
    var activeReview: ReviewModel? {
        get { self[ActiveReviewKey.self] }
        set { self[ActiveReviewKey.self] = newValue }
    }
}
