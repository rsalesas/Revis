import SwiftUI

/// The panel on the far side of the window: where you are in the document, and what the
/// document is.
///
/// Two tabs. Vaelora's inspector configures an export; there is almost nothing here to
/// configure, because Revis renders what it was given. What it has instead is the thing a
/// reviewer of a long generated spec actually needs — a way to get about it — and the
/// provenance the app owes them for having rewritten the file before showing it.
///
/// The one exception is Markdown, and it is an exception for a reason rather than by
/// concession. A `.html` document IS the page; a `.md` document is not, and something has
/// to decide which dialect it is in before it can be shown at all. That decision belongs
/// to the document — a file is written for one processor and the reader does not get a
/// vote — so it lives here, beside the rest of what this document is, and is stored in the
/// review with it.
struct InspectorView: View {
    @ObservedObject var model: ReviewModel

    /// Annotations whose words vanished when the document was last read again. Cleared by
    /// the next change, because it describes one change and not a running total.
    @State private var disturbed: [Annotation] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            switch model.inspectorTab {
            case .outline:  outline
            case .document: document
            case .markdown: markdown
            }
        }
        .background(Theme.inspectorBackground)
    }

    private var header: some View {
        Picker("", selection: $model.inspectorTab) {
            ForEach(InspectorTab.available(forMarkdown: model.markdownOptions != nil)) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .frame(height: Theme.paneHeader)
    }

    // MARK: - Outline

    @ViewBuilder private var outline: some View {
        if model.outline.isEmpty {
            placeholder(model.isPreparing ? "Reading the document…" : "No headings",
                        symbol: "list.bullet.indent")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.outline) { item in
                        OutlineRow(item: item, markCount: markCount(in: item)) {
                            model.scrollToBlock(item.block)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    /// The blocks a heading's SECTION covers: itself, then everything up to the next
    /// heading at its own level or higher.
    ///
    /// A nested heading's blocks belong to its parent as well, which is what anybody
    /// reading an outline expects — "3. Retention periods" counts what is in 3.1, 3.2 and
    /// 3.3, because those are in it.
    private func section(of item: OutlineItem) -> Range<Int> {
        guard let index = model.outline.firstIndex(where: { $0.block == item.block })
        else { return item.block..<(item.block + 1) }
        let end = model.outline[(index + 1)...]
            .first { $0.level <= item.level }?.block ?? model.blockCount
        return item.block..<Swift.max(item.block + 1, end)
    }

    /// How many annotations are in a heading's section.
    ///
    /// It used to count only the heading's OWN line, on the reasoning that deciding where
    /// a section ends was a judgement not worth making. That was the wrong call and it
    /// showed: the number then appeared beside whichever headings happened to have been
    /// annotated directly and nowhere else, which reads as arbitrary — it drew the
    /// question "what are these supposed to be?", which is the only review a piece of
    /// interface can fail. A count beside a heading means "in here"; where a section ends
    /// is not, in fact, hard.
    private func markCount(in item: OutlineItem) -> Int {
        let span = section(of: item)
        return model.annotations.filter { annotation in
            annotation.anchor.blocks.contains { span.contains($0) }
        }.count
    }

    // MARK: - Document

    private var document: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group("Source") {
                    field("File", model.source.name)
                    if let path = model.source.path {
                        field("Location", (path as NSString).deletingLastPathComponent)
                    }
                    field("Captured", Self.formatter.string(from: model.source.capturedAt))
                    if !model.source.digest.isEmpty {
                        // Truncated on screen and complete in the export: sixteen hex
                        // digits is enough to tell two documents apart by eye, and the
                        // full sixty-four is a wall.
                        field("SHA-256", String(model.source.digest.prefix(16)) + "…")
                    }
                    field("Blocks", "\(model.blockCount)")
                }

                group("Display") {
                    // Here as well as in the status bar, and that is not a duplicate: the
                    // bar is where you reach for it while reading, and this is where it is
                    // explained. A one-word control with no room for a sentence beside it
                    // cannot say what it costs you.
                    Toggle("Use the document's own stylesheet",
                           isOn: $model.useDocumentStyle)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.system(size: 11))
                    Text(model.useDocumentStyle
                         ? "The document is drawn exactly as it was sent, which is what you"
                           + " are reviewing."
                         : "The document's stylesheet has been set aside for a plain reading"
                           + " style. What you see is NOT how it looks — turn this back on"
                           + " before judging its appearance.")
                        .font(.system(size: 11))
                        .foregroundStyle(model.useDocumentStyle ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                group("Made safe") {
                    if model.prepared.report.isClean {
                        Text("Nothing had to be removed.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        // Said plainly, because the app rewrote the file before showing
                        // it. A reviewer who is told what came out can judge whether they
                        // are still looking at the document they were sent; one who is
                        // told nothing cannot.
                        Text("This document is untrusted input, so it was scrubbed before"
                             + " it was shown. Removed:")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(model.prepared.report.lines, id: \.label) { line in
                            HStack {
                                Text(line.label).font(.system(size: 11))
                                Spacer()
                                Text("\(line.count)")
                                    .font(.system(size: 11)).monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !model.prepared.missingImages.isEmpty {
                    group("Images not shown") {
                        Text("These were referenced but could not be read — they are"
                             + " missing, too large, or outside the document's folder.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(model.prepared.missingImages.prefix(12), id: \.self) { name in
                            Text(name)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Markdown

    /// How this document is being read — and, when reading it again has left marks that no
    /// longer point at anything, which ones.
    @ViewBuilder private var markdown: some View {
        if let options = model.markdownOptions {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group("Read as Markdown") {
                        // Written straight through the model rather than held in a local
                        // copy: the settings belong to the document and are stored in its
                        // review, so a second copy here would be a second answer to the
                        // question of what this document is.
                        MarkdownOptionsEditor(options: Binding(
                            get: { options },
                            set: { disturbed = model.reread(with: $0) }))
                    }

                    if !disturbed.isEmpty {
                        MarkdownRereadWarning(disturbed: disturbed)
                    }

                    group("Safety") {
                        Text("A Markdown document cannot pull in other files or run"
                             + " anything, whatever it asks for, and what it renders to is"
                             + " scrubbed by the same sanitizer as any other document"
                             + " before it is shown.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// One heading in the outline.
///
/// Its own view because it needs its own hover state, and a row inside a `ForEach` cannot
/// hold one for it.
private struct OutlineRow: View {
    let item: OutlineItem
    let markCount: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(item.text)
                    // Indented by heading level, capped: past the fourth level the indent
                    // is taking more width than the text it is qualifying.
                    .padding(.leading, CGFloat(min(item.level, 4) - 1) * 12)
                    .font(.system(size: 11.5,
                                  weight: item.level <= 2 ? .semibold : .regular))
                    .foregroundStyle(item.level <= 2 ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if markCount > 0 {
                    Text("\(markCount)")
                        .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.14), in: Capsule())
                        // A number with no label has to be able to say what it is.
                        .help("\(markCount) annotation\(markCount == 1 ? "" : "s") in this"
                              + " section")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hovering ? 0.06 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(.hover, value: hovering)
    }
}
