import SwiftUI
import Combine

/// A heading in the document, for the inspector's outline.
struct OutlineItem: Identifiable, Equatable, Codable, Sendable {
    var level: Int
    var text: String
    /// The `data-rv` index of the heading, so clicking the row can scroll to it.
    var block: Int
    var id: Int { block }
}

/// An annotation being written but not yet in the review.
///
/// A draft rather than an empty annotation committed straight away. The difference shows
/// the moment somebody changes their mind: an annotation that exists from the first
/// keystroke has to be deleted to be abandoned, and a review then accumulates the marks
/// its author decided against.
struct AnnotationDraft: Equatable {
    var anchor: Anchor
    var intent: Intent
    var note: String = ""
    /// Bumped each time a draft opens, so the pane can scroll to it and take focus even
    /// when the anchor happens to be identical to the last one's.
    var token: Int
}

/// One review window's state.
///
/// Per window, not shared: two reviews open at once have their own tool, their own
/// selection and their own pane widths, in the same way two Vaelora documents do. What
/// *is* shared — the reviewer's name, the appearance defaults — lives in `AppSettings`.
@MainActor
final class ReviewModel: ObservableObject {

    // MARK: - The document

    @Published private(set) var source: SourceInfo
    @Published private(set) var prepared: PreparedDocument
    /// The complete page handed to the web view. Rebuilt only when the document itself
    /// changes, which after import is never — so it is computed once and held.
    @Published private(set) var pageHTML: String = ""
    /// Headings, reported by the runtime once it has stamped the document.
    @Published var outline: [OutlineItem] = []
    @Published var blockCount: Int = 0

    // MARK: - The marks

    @Published var annotations: [Annotation] = []
    @Published var selectedID: UUID?
    @Published var draft: AnnotationDraft?
    @Published var filter: AnnotationFilter = .open

    // MARK: - The window

    @Published var tool: ReviewTool = .select
    @Published var annotationsVisible: Bool
    @Published var inspectorVisible: Bool
    @Published var inspectorTab: InspectorTab = .outline
    /// Whether the reviewer has text selected in the document. Reported by the runtime, so
    /// Add can be disabled rather than offered and then refused.
    @Published var hasSelection = false
    /// True until the runtime has reported back. The pane says "preparing" rather than
    /// "no annotations", which would be a claim it cannot yet make.
    @Published var isPreparing = true

    // MARK: - How it is shown

    /// Whether the document is drawn with its own stylesheet, or with the app's reading
    /// style. Per window: one document can be unreadable as sent while another is fine.
    @Published var useDocumentStyle: Bool { didSet { rebuildPage() } }

    /// The current zoom, as the page reports it back — never as the app assumes it. Fit is
    /// a measurement, so the only honest source for "what percentage am I at" is the page.
    @Published private(set) var zoom: Double = 1
    /// What "fit the window" currently means, kept up to date as the window is resized.
    @Published private(set) var fitZoom: Double = 1
    /// The zoom to apply; zero asks the page to fit. Pushed on the token changing so the
    /// same value can be asked for twice.
    @Published private(set) var requestedZoom: Double = 0
    @Published private(set) var zoomToken = 0

    /// Bumped to ask the runtime for the current selection; the answer arrives
    /// asynchronously, since reading the DOM from Swift is a round trip.
    @Published var captureToken = 0
    /// Bumped to scroll the document to `selectedID`.
    @Published var revealToken = 0
    /// The block the outline was last asked to scroll to, and a token so asking twice for
    /// the same heading still moves.
    @Published var revealBlock: Int?
    @Published var revealBlockToken = 0

    /// Who new annotations are signed by.
    let author: String

    private var draftCounter = 0

    init(file: ReviewFile, appSettings: AppSettings) {
        source = file.source
        prepared = file.document
        annotations = file.annotations
        author = appSettings.reviewerName
        annotationsVisible = appSettings.lastAnnotationsVisible
        inspectorVisible = appSettings.lastInspectorVisible
        useDocumentStyle = appSettings.useDocumentStyle
        requestedZoom = appSettings.defaultZoom
        rebuildPage()
    }

    // MARK: - Preparing an imported document

    /// Sanitize raw HTML and adopt the result.
    ///
    /// Called by the window rather than by the document, because resolving the document's
    /// images needs the folder it came from and a `FileDocument` is handed bytes with no
    /// URL attached. See `ReviewDocument.pendingHTML`.
    func adopt(html: String, from url: URL?) {
        prepared = DocumentPrep.prepare(html: html, baseURL: url?.deletingLastPathComponent())
        if let title = prepared.title, source.name == "Untitled" || source.name.isEmpty {
            source.name = title
        }
        source.path = url?.path
        rebuildPage()
    }

    private func rebuildPage() {
        guard !prepared.body.isEmpty else { pageHTML = ""; return }
        pageHTML = DocumentShell.page(
            for: prepared, chromeCSS: DocumentShell.bundleString(named: "review", ext: "css"),
            useDocumentCSS: useDocumentStyle)
    }

    // MARK: - Zoom

    /// The steps the -/+ buttons walk. Not a percentage added or multiplied: an even
    /// multiplier gives silly numbers (137%) and an even step is too coarse at the bottom
    /// and too fine at the top. These are the ones a document viewer conventionally offers.
    static let zoomStops: [Double] = [0.5, 0.67, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0]

    func setZoom(_ value: Double) {
        requestedZoom = max(0.35, min(3, value))
        zoomToken &+= 1
    }

    /// Ask the page what fits and go there. A measurement, not a number the app can work
    /// out: the answer depends on the document's own width, which only the page knows.
    func zoomToFit() {
        requestedZoom = 0
        zoomToken &+= 1
    }

    func zoomIn() { setZoom(Self.zoomStops.first { $0 > zoom + 0.001 } ?? 3) }

    func zoomOut() { setZoom(Self.zoomStops.last { $0 < zoom - 0.001 } ?? 0.35) }

    /// The page reporting what it actually did. Kept separate from `requestedZoom` so the
    /// status bar shows the real percentage after a fit rather than the zero that asked
    /// for it.
    func receive(zoom value: Double) { zoom = value }

    func receive(fit value: Double) { fitZoom = value }

    /// Whether the current zoom already fits, so the Fit control can say so rather than
    /// offering to do what has been done.
    var isFitted: Bool { abs(zoom - fitZoom) < 0.005 }

    /// Everything that goes back into the file on save.
    ///
    /// Built from the model rather than mutating what was loaded, so there is exactly one
    /// description of what a review IS — and saving, exporting and reopening cannot end up
    /// disagreeing about it.
    var snapshotFile: ReviewFile {
        ReviewFile(source: source, document: prepared, annotations: annotations)
    }

    /// What an exported review should be called: the document's name without its
    /// extension, since `spec.html.md` reads as a mistake.
    var exportBaseName: String {
        let name = source.name.isEmpty ? displayName : source.name
        return (name as NSString).deletingPathExtension.isEmpty
            ? name : (name as NSString).deletingPathExtension
    }

    var isEmpty: Bool { prepared.body.isEmpty }

    var displayName: String {
        prepared.title ?? (source.name.isEmpty ? "Untitled" : source.name)
    }

    // MARK: - What the pane shows

    /// In document order, filtered. One list, computed in one place, so the pane, the
    /// margin and the export cannot disagree about what is in the review.
    var visibleAnnotations: [Annotation] {
        annotations.inDocumentOrder().filter { filter.admits($0) }
    }

    var openCount: Int { annotations.filter { $0.status == .open }.count }

    /// Where in the visible list an open draft belongs — the position it will occupy once
    /// it is added.
    ///
    /// The draft used to be drawn at the top of the pane whatever it was about, so
    /// pressing Add made the row jump somewhere else. A row that appears in one place and
    /// lands in another reads as the app correcting a mistake; opened where it ends up, it
    /// simply stays put.
    var draftIndex: Int? {
        guard let draft else { return nil }
        let key = (draft.anchor.blocks.first ?? Int.max, draft.anchor.start)
        let visible = visibleAnnotations
        let after = visible.firstIndex {
            let order = $0.ordering
            return (order.0, order.1) > key
        }
        return after ?? visible.count
    }

    func index(of id: UUID) -> Int? { annotations.firstIndex { $0.id == id } }

    func annotation(_ id: UUID) -> Annotation? { annotations.first { $0.id == id } }

    // MARK: - Making one

    /// Ask the runtime what is selected. The draft opens when the answer comes back
    /// through `receive(anchor:)` — nothing happens here if there is no selection, which
    /// is why the command is disabled without one rather than failing silently.
    func beginAnnotationFromSelection() {
        guard hasSelection else { return }
        captureToken &+= 1
    }

    /// The runtime's answer, or nil when the selection turned out to be empty.
    func receive(anchor: Anchor?) {
        guard let anchor else { return }
        openDraft(on: anchor)
    }

    func openDraft(on anchor: Anchor, intent: Intent = .change) {
        draftCounter &+= 1
        selectedID = nil
        draft = AnnotationDraft(anchor: anchor, intent: intent, token: draftCounter)
    }

    func commitDraft() {
        guard let draft else { return }
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        // An approval is complete without words — the mark IS the statement. Everything
        // else needs to say something, or the export would carry an operation with no
        // instruction, which is worse than no annotation at all.
        guard !note.isEmpty || draft.intent == .approve else { return }
        let annotation = Annotation(author: author, intent: draft.intent,
                                    note: note, anchor: draft.anchor)
        annotations.append(annotation)
        self.draft = nil
        selectedID = annotation.id
        // An annotation made from a region leaves the tool in region mode, which is right
        // — somebody boxing one figure is usually about to box another.
    }

    func cancelDraft() { draft = nil }

    // MARK: - Changing one

    func setIntent(_ intent: Intent, for id: UUID) {
        guard let index = index(of: id) else { return }
        annotations[index].intent = intent
    }

    func setNote(_ note: String, for id: UUID) {
        guard let index = index(of: id) else { return }
        annotations[index].note = note
    }

    /// Resolving marks; it does not delete.
    ///
    /// A review is handed over and handed back, and "we already dealt with that" is part
    /// of what it records. The export leaves resolved items out of the instructions and
    /// lists them separately, so a second pass cannot re-open a settled question.
    func resolve(_ id: UUID) {
        guard let index = index(of: id) else { return }
        annotations[index].status = .resolved
    }

    func reopen(_ id: UUID) {
        guard let index = index(of: id) else { return }
        annotations[index].status = .open
    }

    func delete(_ id: UUID) {
        annotations.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    // MARK: - Moving about

    /// Choose an annotation and take the document to it. Both directions are this one
    /// call, so clicking a marker and clicking a row cannot end up meaning different
    /// things.
    func reveal(_ id: UUID) {
        selectedID = id
        revealToken &+= 1
    }

    func scrollToBlock(_ index: Int) {
        revealBlock = index
        revealBlockToken &+= 1
    }

    // MARK: - Export

    func exportMarkdown() -> String { ReviewExport.markdown(snapshotFile, filter: filter) }

    func exportJSON() -> String { ReviewExport.json(snapshotFile, filter: filter) }

    /// What gets pushed at the runtime so it can draw. A flattened shape rather than the
    /// annotations themselves: the page needs a colour and a position, and has no business
    /// holding the text of everybody's notes.
    var annotationsJSON: String {
        struct Wire: Encodable {
            var id: String
            var intent: String
            var status: String
            var blocks: [Int]
            var start: Int
            var end: Int
            var rect: NormalizedRect?
        }
        var wire = visibleAnnotations.map {
            Wire(id: $0.id.uuidString, intent: $0.intent.rawValue, status: $0.status.rawValue,
                 blocks: $0.anchor.blocks, start: $0.anchor.start, end: $0.anchor.end,
                 rect: $0.anchor.rect)
        }
        // The draft is drawn too, under a reserved id. A mark that only appears once the
        // note is written leaves the reviewer typing about a passage with nothing on the
        // page to say which one.
        if let draft {
            wire.append(Wire(id: Self.draftID, intent: draft.intent.rawValue, status: "open",
                             blocks: draft.anchor.blocks, start: draft.anchor.start,
                             end: draft.anchor.end, rect: draft.anchor.rect))
        }
        guard let data = try? JSONEncoder().encode(wire) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Not a UUID, so it can never collide with a real annotation's id.
    static let draftID = "draft"

    /// Which mark the page should draw as current.
    var currentMarkID: String {
        draft != nil ? Self.draftID : (selectedID?.uuidString ?? "")
    }
}
