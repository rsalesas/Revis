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
        Group {
            if model.isEmpty {
                EmptyReviewView()
            } else {
                // Nested, inspector OUTERMOST: opening the annotations then takes width
                // from the document and leaves the inspector where it is, which is what
                // you want when the inspector is the thing you were reading.
                CollapsibleSidePane(isOpen: model.inspectorVisible, width: 260) {
                    CollapsibleSidePane(isOpen: model.annotationsVisible, width: 300) {
                        document
                    } pane: {
                        AnnotationsPane(model: model)
                    }
                } pane: {
                    InspectorView(model: model)
                }
            }
        }
        .background(Theme.documentBackground)
        .navigationTitle(model.displayName)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
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
            revealToken: model.revealToken,
            revealBlock: model.revealBlock,
            revealBlockToken: model.revealBlockToken,
            onReady: { blocks, outline in
                model.blockCount = blocks
                model.outline = outline
                model.isPreparing = false
            },
            onSelectionChanged: { model.hasSelection = $0 },
            onPick: { id in
                // The draft's own mark is not something to select — it is already the
                // thing being worked on.
                guard id != ReviewModel.draftID, let uuid = UUID(uuidString: id) else { return }
                model.reveal(uuid)
            },
            onAnchor: { model.receive(anchor: $0) },
            onRegion: { model.openDraft(on: $0, intent: appSettings.defaultIntent) })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
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
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.beginAnnotationFromSelection()
            } label: {
                Label("Annotate", systemImage: "plus.bubble")
            }
            // Disabled rather than hidden: a control you can see and cannot use says why,
            // and a missing one says nothing at all.
            .disabled(!model.hasSelection)
            .help(model.hasSelection ? "Annotate the selected text (⌘⇧A)"
                  : "Select some text in the document first")

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

            Button {
                withMotion(.panel) { model.inspectorVisible.toggle() }
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Show or hide the outline and document details")
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
