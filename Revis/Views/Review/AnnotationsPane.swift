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
                    // The draft opens where it will END UP — its place in document order —
                    // rather than at the top. See `ReviewModel.draftIndex`.
                    if model.draftIndex == 0 { draftSlot }
                    ForEach(Array(model.visibleAnnotations.enumerated()),
                            id: \.element.id) { position, annotation in
                        row(annotation)
                            .id(annotation.id)
                        Divider().overlay(Theme.hairline)
                        if model.draftIndex == position + 1 { draftSlot }
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

    @ViewBuilder private var draftSlot: some View {
        if let draft = model.draft {
            draftRow(draft)
                .id(Self.draftRowID)
                .revealedRowTransition()
            Divider().overlay(Theme.hairline)
        }
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
                // No explanatory line beside the buttons. There was one — it said what the
                // field was missing — and it was noise: the placeholder in the field
                // directly above is already asking the question, and a prompt answered
                // twice reads as the app not trusting you to have read it once. What the
                // difference between an enabled and a disabled Add rests on is carried by
                // the placeholder instead, which says "(optional)" where words are not
                // needed.
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
            .padding(.top, 6)
        }
        .padding(.leading, 13).padding(.trailing, 16).padding(.vertical, 12)
        .background(alignment: .leading) { bar(AnnotationPalette.color(for: draft.intent)) }
    }

    /// The same question `ReviewModel.commitDraft` asks, of the same property — so the
    /// button cannot offer something the model would refuse, or refuse something it would
    /// accept.
    private func canCommit(_ draft: AnnotationDraft) -> Bool {
        !draft.intent.needsInstruction
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
                // ALWAYS the picker, selected or not.
                //
                // It used to be a plain label that became a menu when the row was chosen,
                // with matched metrics on the label so nothing would move. That was not
                // enough and could not be: a `Menu` restyles its own label — its control
                // size, its font, its padding — so swapping one for the other moved the
                // icon, changed the type size, and shifted the whole card. Matching two
                // controls pixel for pixel is a losing game; having one control is not.
                //
                // It is also the truer interface. An annotation's intent can be changed
                // whether or not the row is the chosen one, and a chevron that is always
                // there says so.
                IntentPicker(intent: Binding(
                    get: { model.annotation(annotation.id)?.intent ?? annotation.intent },
                    set: { model.setIntent($0, for: annotation.id) }))
                Spacer()
                if let verdict = annotation.verdict {
                    badge(verdict.title, colour: Color(hex: verdict.hex),
                          help: annotation.verdictBy.map { "\(verdict.title) by \($0)" })
                }
                if annotation.status == .resolved {
                    badge("Resolved", colour: .secondary, help: nil)
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
                // An annotation that needs no words is complete without them, and must
                // not read as unfinished.
                Text(annotation.intent.needsInstruction ? "Nothing written yet"
                                                        : "No reason given")
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
                    // Agreeing or disagreeing with what was asked — a verdict on the
                    // annotation, which is a different question from whether it has been
                    // dealt with. Pressing the same one again takes it back.
                    ForEach(Verdict.allCases, id: \.self) { verdict in
                        Button {
                            model.decide(verdict, for: annotation.id)
                        } label: {
                            Image(systemName: verdict.symbol)
                        }
                        .foregroundStyle(annotation.verdict == verdict
                                         ? AnyShapeStyle(Color(hex: verdict.hex))
                                         : AnyShapeStyle(.secondary))
                        .help(annotation.verdict == verdict
                              ? "Take back this \(verdict.title.lowercased()) verdict"
                              : "\(verdict.verb) this — "
                                + (verdict == .approved
                                   ? "agree it should be done"
                                   : "say it should NOT be done; the export will tell the"
                                     + " reader not to act on it"))
                    }
                    Divider().frame(height: 11)
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
            // On top of the stack's own 8. The footer carries the byline and the actions,
            // and at 8 they sat close enough under the note to read as another line of it
            // — buttons that look like part of the sentence above them.
            .padding(.top, 6)
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

    /// A small capsule stating something about the row — a verdict, or that it is settled.
    private func badge(_ text: String, colour: Color, help: String?) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(colour)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(colour.opacity(0.14), in: Capsule())
            .help(help ?? text)
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

/// An intent's symbol and name, at metrics that do not depend on which intent it is.
///
/// Both fixed, and both load-bearing. SF Symbols have different intrinsic widths —
/// `pencil.line` is far wider than `checkmark` — so an icon left to size itself moved the
/// title beside it every time the intent changed, and in a menu it moved the chevron too:
/// the control appeared to twitch as you chose from it. The name is boxed to the widest of
/// the seven for the same reason.
///
/// Shared by the plain row and the menu so a row does not shift when it becomes selected
/// and swaps one for the other.
private struct IntentLabel: View {
    let intent: Intent

    /// Wide enough for "Question", the longest of the seven at this size, with slack — a
    /// name that just fits is a name that clips on the first system font change.
    static let titleWidth: CGFloat = 66
    static let iconSide: CGFloat = 16
    /// The type size. This is the row's headline — the one thing that says what an
    /// annotation IS — and it was set at 10pt, smaller than the note beneath it and
    /// smaller than the quote. It was hard to read and a poor target to click. It matches
    /// the note now, and carries its weight to stay distinct from it.
    static let fontSize: CGFloat = 12
    /// The whole label, stated outright. See below for why a fixed width on each half was
    /// not enough.
    static let width: CGFloat = iconSide + 5 + titleWidth

    /// Taller than the type needs: this is a control people click to change an
    /// annotation's kind, and at the type's own height it was a nine-point strip.
    static let height: CGFloat = 22

    var body: some View {
        // The SIZE comes from the empty rectangle; the content is drawn over it and has no
        // say in the matter.
        //
        // Frames on the content were tried twice and were not enough either time. A
        // `.frame` sets a view's layout size but lets it paint outside, and the things
        // measuring this label — a `Menu`, and the row's stack — measure what is painted.
        // So `pencil.line` made the control wider than `checkmark`, and `text.bubble` made
        // the whole card one point taller than the other six. A point is not much; a card
        // that is a different height for one of seven types is still wrong, and no amount
        // of matching frames to glyphs was going to end it. Laying out a fixed empty box
        // and hanging the content off it does: the content cannot influence a size that was
        // decided without reference to it.
        Color.clear
            .frame(width: Self.width, height: Self.height)
            .overlay(alignment: .leading) {
                HStack(spacing: 5) {
                    Image(systemName: intent.symbol)
                        .font(.system(size: Self.fontSize, weight: .semibold))
                        .frame(width: Self.iconSide, height: Self.iconSide)
                        .clipped()
                    Text(intent.title)
                        .font(.system(size: Self.fontSize, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
            .foregroundStyle(AnnotationPalette.color(for: intent))
    }
}

/// The intent, as a compact menu.
///
/// A menu rather than a segmented control or a row of icons, because there are seven and a
/// review pane is 300 points wide. The current choice is shown with its colour and its
/// symbol, so a glance at the row says what kind of thing it is without the menu being
/// opened.
struct IntentPicker: View {
    @Binding var intent: Intent

    /// Room for the disclosure chevron beside the label.
    private static let chevron: CGFloat = 16

    var body: some View {
        Menu {
            ForEach(Intent.allCases) { option in
                Button {
                    intent = option
                } label: {
                    // Explicitly icon AND title: a `Label` in a SwiftUI menu drops its
                    // icon unless the style says otherwise, so the list came out as seven
                    // bare words with nothing tying them to the marks on the page.
                    Label(option.title, systemImage: option.symbol)
                        .labelStyle(.titleAndIcon)
                }
            }
        } label: {
            IntentLabel(intent: intent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        // `.regular` rather than `.small`: the small size shrinks the chevron to a mark
        // you have to aim at, and this is the control that says what an annotation is.
        .controlSize(.regular)
        .font(.system(size: IntentLabel.fontSize, weight: .semibold))
        .imageScale(.medium)
        // The frame goes on the MENU, not just on its label, and `fixedSize` is gone.
        //
        // A fixed frame inside the label was not enough and could not be: `fixedSize` asks
        // the menu for its ideal width, and a menu's idea of ideal is its own — it tracked
        // the length of the word, so the chevron after "Note" sat twelve points left of the
        // one after "Approve" and a column of rows had a ragged edge. Constraining the
        // control itself is the only thing the menu cannot reinterpret. The height is
        // pinned for the same reason: `text.bubble` was reporting a taller control than the
        // other six.
        .frame(width: IntentLabel.width + Self.chevron, height: IntentLabel.height,
               alignment: .leading)
        .help("What is being asked for here — click to change it")
    }
}
