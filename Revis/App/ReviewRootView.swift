import SwiftUI

/// One document window. Owns its own `ReviewModel`, kept in step with the DocumentGroup
/// document so that saving writes what is on screen.
struct ReviewRootView: View {
    @Binding var document: ReviewDocument
    let fileURL: URL?

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var appSettings: AppSettings
    @Environment(\.controlActiveState) private var controlActiveState
    @StateObject private var model: ReviewModel
    /// Bumped once an HTML document has been imported, which is the moment the window has
    /// to stop being attached to the file it read. See `SourceDetachment`.
    @State private var detachGeneration = 0

    init(document: Binding<ReviewDocument>, fileURL: URL?) {
        _document = document
        self.fileURL = fileURL
        _model = StateObject(wrappedValue: ReviewModel(file: document.wrappedValue.file,
                                                       appSettings: AppState.shared.appSettings))
    }

    var body: some View {
        ReviewView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Not decoration: this is what stops the review being autosaved over the
            // document it is a review OF.
            .background(SourceDetachment(generation: detachGeneration, name: model.displayName))
            .focusedSceneValue(\.activeReview, model)
            .onAppear {
                model.tool = appSettings.defaultTool
                prepareIfNeeded()
                appState.activeReview = model
            }
            // A document opened from Finder has its URL by `init`, but one opened through
            // File ▸ Open can arrive a beat later — and preparation needs the folder to
            // resolve the document's images against.
            .onChange(of: fileURL) { _, _ in prepareIfNeeded() }
            .onChange(of: controlActiveState) { _, state in
                if state != .inactive { appState.activeReview = model }
            }
            // The model is the working copy and the document is what gets written. Kept in
            // step here rather than by making the model edit the document directly: a
            // window that wrote through to its `FileDocument` on every keystroke would mark
            // the file dirty for a note that was then abandoned.
            .onChange(of: model.annotations) { _, new in
                if document.file.annotations != new { document.file.annotations = new }
            }
            .onChange(of: model.prepared) { _, new in
                if document.file.document != new { document.file.document = new }
            }
            .onChange(of: model.source) { _, new in
                if document.file.source != new { document.file.source = new }
            }
    }

    /// Sanitize an imported HTML document, once its folder is known.
    ///
    /// The raw markup is parked on the `FileDocument` by its reader, because a reader is
    /// handed bytes and has no URL to resolve relative images against. This is the first
    /// place both are in hand. Clearing `pendingHTML` afterwards is what stops it running
    /// twice.
    private func prepareIfNeeded() {
        guard let html = document.pendingHTML else { return }
        model.adopt(html: html, from: fileURL)
        document.pendingHTML = nil
        // The folder was needed to resolve the document's images; the URL is not wanted
        // for anything after that, and keeping it is what would let a save reach the
        // source file.
        detachGeneration &+= 1
    }
}
