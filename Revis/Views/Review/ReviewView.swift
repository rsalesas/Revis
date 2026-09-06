import SwiftUI

/// One review window.
///
/// The shape mirrors Vaelora's editor deliberately — document in the middle, notes beside
/// it, an inspector outside that — because the two apps are two halves of one job and a
/// reviewer who knows one should not have to learn the other. What is different is what is
/// missing: there is no editor pane, because the document is not ours to change, and no
/// export inspector, because there is nothing about the rendering to configure.
struct ReviewView: View {
    @ObservedObject var model: ReviewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var appSettings: AppSettings

    /// Whether the export sheet is up, and what it holds.
    @State private var export: ExportPreview?

    var body: some View {
        VStack(spacing: 0) {
            content
            // Below the split rather than inside it: the bar is about the window, and one
            // that sat inside the document pane would stop at the annotations pane's edge
            // and read as part of the page rather than as part of the app.
            if !model.isEmpty { StatusBar(model: model) }
        }
        .background(Theme.documentBackground)
        .navigationTitle(model.displayName)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        // A pane toggle is a resize like any other. Telling the page its future width up
        // front was tried and made things worse both ways: the sheet arrived at its final
        // size while the viewport was still moving, so it sat in the middle of a gap and
        // then grew back — which is the "far away from the trailing margin, then resizes
        // itself" half of the problem. Following the resize is what dragging the window
        // edge does, and that was smooth all along.
        .onChange(of: model.annotationsVisible) { _, visible in
            appSettings.lastAnnotationsVisible = visible   // not @Published, so no re-render
        }
        .onChange(of: model.inspectorVisible) { _, visible in
            appSettings.lastInspectorVisible = visible
        }
        .sheet(item: $export) { ExportSheet(preview: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .revisShowExport)) { note in
            guard (note.object as? ReviewModel) === model else { return }
            export = ExportPreview(markdown: model.exportMarkdown(),
                                   json: model.exportJSON(),
                                   suggestedName: model.exportBaseName)
        }
    }

    /// The pane widths, named once: the layout uses them and `prefit` has to say the same
    /// numbers, and two copies of a width is two chances to say different ones.
    static let inspectorWidth: CGFloat = 260
    static let annotationsWidth: CGFloat = 300

    @ViewBuilder private var content: some View {
        if model.isEmpty {
            EmptyReviewView()
        } else {
            // The outline sits on the LEADING side, and the annotations on the trailing.
            //
            // It was on the trailing side beside the annotations, which is where Vaelora
            // puts its inspector — but Vaelora's inspector configures an export, and this
            // one is a table of contents. Navigation belongs on the leading edge: it is
            // where every document application on this platform puts a source list, and it
            // is where the eye goes to ask "where am I" rather than "what did somebody say
            // about this".
            //
            // Nested with the inspector OUTERMOST: opening the annotations then takes width
            // from the document and leaves the outline where it is, which is what you want
            // when the outline is the thing you were reading down.
            CollapsibleSidePane(edge: .leading, isOpen: model.inspectorVisible,
                                width: Self.inspectorWidth) {
                CollapsibleSidePane(isOpen: model.annotationsVisible,
                                    width: Self.annotationsWidth) {
                    document
                } pane: {
                    AnnotationsPane(model: model)
                }
            } pane: {
                InspectorView(model: model)
            }
        }
    }

    /// What a type button says about itself — including, when it is unavailable, what
    /// would make it available. Insert is the one that needs only a caret: naming a place
    /// between two words is not something you can do by selecting words.
    private func helpFor(_ intent: Intent) -> String {
        if model.canAnnotate(intent) { return "\(intent.title) — \(intent.directive)" }
        return intent == .insert
            ? "Click where the new text should go, or select the text it follows"
            : "Select some text in the document first"
    }

    /// The count, stated once. A window that says "9 open" in its subtitle does not need
    /// the pane open to tell you there is something to look at.
    private var subtitle: String {
        let open = model.openCount
        let total = model.annotations.count
        if total == 0 { return "No annotations" }
        if open == total { return "\(total) annotation\(total == 1 ? "" : "s")" }
        return "\(open) open of \(total)"
    }

    // MARK: - The document

    private var document: some View {
        DocumentWebView(
            html: model.pageHTML,
            annotations: model.annotationsJSON,
            currentMark: model.currentMarkID,
            tool: model.tool,
            captureToken: model.captureToken,
            requestedZoom: model.requestedZoom,
            zoomToken: model.zoomToken,
            revealToken: model.revealToken,
            revealBlock: model.revealBlock,
            revealBlockToken: model.revealBlockToken,
            onReady: { blocks, outline in
                model.blockCount = blocks
                model.outline = outline
                model.isPreparing = false
            },
            onSelectionChanged: { hasSelection, hasCaret in
                model.hasSelection = hasSelection
                model.hasCaret = hasCaret
            },
            onPick: { id in
                // The draft's own mark is not something to select — it is already the
                // thing being worked on.
                guard id != ReviewModel.draftID, let uuid = UUID(uuidString: id) else { return }
                // `select`, not `reveal`: this came from the page, so the page stays put.
                model.select(uuid)
            },
            onAnchor: { model.receive(anchor: $0) },
            onZoom: { model.receive(zoom: $0) },
            onFit: { model.receive(fit: $0) },
            // No intent passed: the model knows the default. Handing it in here was how
            // the two paths came to disagree.
            onRegion: { model.openDraft(on: $0) })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // The outline's toggle sits at the LEADING edge, because that is the side the
        // outline is on. A control that opens something should be on the same side as the
        // thing it opens — it is the one place a toolbar can say which of two panes it
        // means without a word of explanation, and it is where every split-view app on
        // this platform puts it.
        ToolbarItem(placement: .navigation) {
            Button {
                withMotion(.panel) { model.inspectorVisible.toggle() }
            } label: {
                Label("Outline", systemImage: "sidebar.leading")
            }
            .help("Show or hide the outline and document details")
        }

        ToolbarItemGroup(placement: .principal) {
            Picker("Tool", selection: $model.tool) {
                ForEach(ReviewTool.allCases) { tool in
                    Label(tool.title, systemImage: tool.symbol).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Select text, or drag a box over part of the page")
            .disabled(model.isEmpty)

            // A divider, because these are two different questions. The picker on the left
            // is HOW you are pointing; the buttons on the right are WHAT you are asking
            // for. Run together they read as one row of unrelated controls.
            //
            // Inside an `HStack` and given a height, because a bare `Divider()` is a
            // HORIZONTAL rule — it only turns vertical when its container is laying things
            // out in a row, and a toolbar item group is not that container. On its own it
            // drew a short dash between the two sets, which reads as a stray minus sign.
            HStack(spacing: 0) { Divider() }
                .frame(height: 18)

            // One button per kind, so marking something up is a single click rather than a
            // click and then a menu. The kind is still changeable afterwards from the row
            // in the pane — this is the quick way in, not the only way.
            ForEach(Intent.allCases) { intent in
                Button {
                    model.beginAnnotation(intent)
                } label: {
                    Label(intent.title, systemImage: intent.symbol)
                }
                // Carrying the intent's own colour, which is the same colour its mark and
                // its row will be. The toolbar is where that association is learned.
                .foregroundStyle(AnnotationPalette.color(for: intent))
                // Disabled rather than hidden: a control you can see and cannot use says
                // why, and a missing one says nothing at all.
                .disabled(!model.canAnnotate(intent))
                .help(helpFor(intent))
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                NotificationCenter.default.post(name: .revisShowExport, object: model)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.annotations.isEmpty)
            .help("Write the review out as instructions")

            // One icon, always. A dot says there are annotations rather than the glyph
            // changing shape, which would read as a different button.
            Button {
                withMotion(.panel) { model.annotationsVisible.toggle() }
            } label: {
                Label("Annotations", systemImage: "text.bubble")
                    .overlay(alignment: .topTrailing) {
                        if model.openCount > 0 {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 6, height: 6)
                                .offset(x: 3, y: -2)
                        }
                    }
            }
            .help("Show or hide the annotations")

        }
    }
}

extension Notification.Name {
    /// Posted by the toolbar button and by the File menu; carries the model it means, so
    /// it reaches one window rather than all of them.
    static let revisShowExport = Notification.Name("app.revis.showExport")
}

/// What a window shows before there is anything to review.
///
/// A DocumentGroup gives File ▸ New whether or not the app has a use for it, so a new
/// window has to say something. It says the one thing that is true: there is no document
/// yet, and here is how to get one.
struct EmptyReviewView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 42, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("No document to review")
                .font(.system(size: 15, weight: .medium))
            Text("Open an HTML document — a specification, a draft, a report — and mark it"
                 + " up. The review is saved beside it, and exports as instructions the"
                 + " thing that wrote it can act on.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Open Document…") {
                NSDocumentController.shared.openDocument(nil)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
