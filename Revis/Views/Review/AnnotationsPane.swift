import SwiftUI

/// The marks beside the document.
///
/// A view onto `ReviewModel.annotations` and nothing more — there is no second store here
/// and no channel pushing rows at the page. Every action edits the model, the model
/// re-publishes, and the margin markers and these rows are both rebuilt from the result.
/// One list, two drawings of it.
struct AnnotationsPane: View {
    @ObservedObject var model: ReviewModel

    @FocusState private var focused: Field?
    private enum Field: Hashable { case draft, note(UUID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            if model.visibleAnnotations.isEmpty && model.draft == nil {
                empty
            } else {
                list
            }
        }
        .background(Theme.paneBackground)
        .onChange(of: model.draft?.token) { _, token in
            guard token != nil else { return }
            focused = .draft
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Annotations").font(.system(size: 11, weight: .semibold))
            Spacer()
            // The filter is a menu rather than a segmented control: it is changed rarely,
            // and three segments would take a third of a 280-point header to say something
            // that is usually "Open".
            Menu {
                Picker("Show", selection: $model.filter) {
                    ForEach(AnnotationFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 3) {
                    Text(model.filter.title)
                    Text("\(model.visibleAnnotations.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .frame(height: Theme.paneHeader)
    }

    // MARK: - Empty

    private var empty: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: model.isPreparing ? "hourglass" : "text.bubble")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.isPreparing ? "Preparing document"
                 : (model.filter == .open ? "Nothing outstanding" : "No annotations"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if !model.isPreparing {
                Text("Select text in the document and press ⌘⇧A, or drag a box with the"
                     + " Region tool.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { scroll in
            ScrollView {
                // A plain VStack, not a lazy one. A lazy stack does not know the height of
                // a row it has not built, so the scroll view works from an estimate and
                // corrects it as rows are realised — which shows as the scrollbar drifting
                // after an edit and then jumping when you touch it. A review holds tens of
                // rows, not thousands; laziness buys nothing here and costs that.
                VStack(alignment: .leading, spacing: 0) {
                    if let draft = model.draft {
                        draftRow(draft)
                            .id(Self.draftRowID)
                            .revealedRowTransition()
                        Divider().overlay(Theme.hairline)
                    }
                    ForEach(model.visibleAnnotations) { annotation in
                        row(annotation)
                            .id(annotation.id)
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
            // Hold the BOTTOM of the list still while a row is being written in.
            //
            // A text field that takes another line makes its row taller, and a scroll view
            // holding its top offset answers by letting the extra hang off the end — which
            // for the last row is the Add button sliding under the edge of the pane as you
            // type. Anchored at the bottom the box grows upward instead and the buttons
            // stay where your hand already is. Both roles are load-bearing: the size-change
            // compensation is worked out against the offset anchor, so the two have to name
            // the same edge.
            .defaultScrollAnchor(model.draft != nil ? .bottom : nil, for: .sizeChanges)
            .defaultScrollAnchor(model.draft != nil ? .bottom : nil, for: .initialOffset)
            .onChange(of: model.draft?.token) { _, token in
                guard token != nil else { return }
                reveal(Self.draftRowID, with: scroll)
            }
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                reveal(id, with: scroll)
            }
        }
        // Deliberately not animated on the list changing: resolving one mark moves every
        // row after it, and animating that makes the whole column slide about while you
        // are reading it.
    }

    private static let draftRowID = "revis-draft"

    /// No anchor, so this scrolls the minimum needed to show the row and does nothing when
    /// it is already visible — an anchor would recentre the list every time you clicked
    /// something on it. Always a turn late, because `scrollTo` can only reach a row the
    /// scroll view has already laid out at its new height.
    private func reveal(_ id: some Hashable, with scroll: ScrollViewProxy) {
        DispatchQueue.main.async { scroll.scrollTo(id) }
    }

    // MARK: - The draft

    private func draftRow(_ draft: AnnotationDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IntentPicker(intent: Binding(
                get: { model.draft?.intent ?? .change },
                set: { model.draft?.intent = $0 }))
            quoted(draft.anchor)
            TextField(draft.intent.prompt, text: Binding(
                get: { model.draft?.note ?? "" },
                set: { model.draft?.note = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...8)
                .focused($focused, equals: .draft)
                .onSubmit { model.commitDraft() }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { model.cancelDraft() }
                    .keyboardShortcut(.cancelAction)
                // Explicitly prominent and explicitly tinted: a plain default button takes
                // its highlight from AppKit's accent, which is the system blue whatever the
                // app is tinted with — so this one control would ignore the app's colour.
                Button("Add") { model.commitDraft() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit(draft))
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.leading, 13).padding(.trailing, 16).padding(.vertical, 12)
        .background(alignment: .leading) { bar(AnnotationPalette.color(for: draft.intent)) }
    }

    /// An approval needs no words — the mark is the statement. Everything else does, or
    /// the export would carry an operation with no instruction attached to it.
    private func canCommit(_ draft: AnnotationDraft) -> Bool {
        draft.intent == .approve
            || !draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - A row

    private func row(_ annotation: Annotation) -> some View {
        // One question, one answer: the row being worked on wears the bar AND carries the
        // controls, and no other row shows either. A draft is the thing being written, so
        // while one is open nothing else reads as active.
        let selected = model.draft == nil && model.selectedID == annotation.id
        let colour = AnnotationPalette.color(for: annotation.intent)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if selected {
                    IntentPicker(intent: Binding(
                        get: { model.annotation(annotation.id)?.intent ?? annotation.intent },
                        set: { model.setIntent($0, for: annotation.id) }))
                } else {
                    Image(systemName: annotation.intent.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(colour)
                        .frame(width: 14)
                    Text(annotation.intent.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(colour)
                }
                Spacer()
                if annotation.status == .resolved {
                    Text("Resolved")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07),
                                    in: Capsule())
                }
            }

            quoted(annotation.anchor)

            if selected {
                TextField(annotation.intent.prompt, text: noteBinding(annotation.id),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...8)
                    .focused($focused, equals: .note(annotation.id))
            } else if !annotation.note.isEmpty {
                Text(annotation.note)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // An approval with no words is complete, and should not read as unfinished.
                Text(annotation.intent == .approve ? "Approved as written"
                     : "Nothing written yet")
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                Text(annotation.author.isEmpty ? "Unsigned" : annotation.author)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                if selected {
                    if annotation.status == .open {
                        Button("Resolve") { model.resolve(annotation.id) }
                            .help("Mark as dealt with. It stays in the review, and the"
                                  + " export lists it separately.")
                    } else {
                        Button("Reopen") { model.reopen(annotation.id) }
                    }
                    Button(role: .destructive) { model.delete(annotation.id) } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete this annotation")
                }
            }
            .controlSize(.small)
            .modifier(RevealIfSelected(selected: selected))
        }
        .padding(.leading, 13).padding(.trailing, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A bar down the leading edge rather than a block of colour behind the row. A flat
        // fill reads as a square being clipped, because that is what it is: a full-bleed
        // rectangle with nothing to give it an edge.
        .background(alignment: .leading) { bar(colour).opacity(selected ? 1 : 0) }
        .opacity(annotation.status == .resolved ? 0.62 : 1)
        .contentShape(Rectangle())
        // A row selects, and takes the document to its mark. Clicking a mark selects the
        // row by the same route, so the two directions cannot mean different things.
        .onTapGesture { model.reveal(annotation.id) }
        .motion(.panel, value: selected)
    }

    /// What the annotation is about, in the reviewer's own view of it.
    ///
    /// Shown on every row, not just the chosen one. A list of notes with no quotes is a
    /// list of opinions about an unnamed subject — you have to click each one to find out
    /// what it is talking about, which is precisely the work the pane exists to save.
    private func quoted(_ anchor: Anchor) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(anchor.summary(limit: 140))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .italic()
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 7)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.hairline).frame(width: 2)
                }
            if !anchor.path.isEmpty {
                Text(anchor.path)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bar(_ colour: Color) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(colour).frame(width: 3)
            colour.opacity(0.07)
        }
    }

    private func noteBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { model.annotation(id)?.note ?? "" },
                set: { model.setNote($0, for: id) })
    }
}

/// The controls a chosen row grows. Its own modifier so the transition is applied at one
/// point and cannot drift between the two places rows are drawn.
private struct RevealIfSelected: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        if selected { content.revealedRowTransition() } else { content }
    }
}

/// The intent, as a compact menu.
///
/// A menu rather than a segmented control or a row of icons, because there are seven and a
/// review pane is 280 points wide. The current choice is shown with its colour and its
/// symbol, so a glance at the row says what kind of thing it is without the menu being
/// opened.
struct IntentPicker: View {
    @Binding var intent: Intent

    var body: some View {
        Menu {
            ForEach(Intent.allCases) { option in
                Button {
                    intent = option
                } label: {
                    Label(option.title, systemImage: option.symbol)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: intent.symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(intent.title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(AnnotationPalette.color(for: intent))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("What is being asked for here")
    }
}
