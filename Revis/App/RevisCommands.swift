import SwiftUI

/// The menu bar.
///
/// Every command acts on the focused window's model, reached through `@FocusedValue`
/// rather than through a shared singleton — two reviews open at once must not annotate
/// each other.
struct RevisCommands: Commands {
    @FocusedValue(\.activeReview) private var review

    var body: some Commands {
        // Under "About Revis", where every Mac app that updates itself puts it. Reached
        // through the shared state rather than `@FocusedValue` — unlike everything else in
        // here, this command is about the app and not about a document, and it has to work
        // with no window open at all.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                Task {
                    let checker = AppState.shared.updateChecker
                    await checker.check()
                    UpdateAlert.present(for: checker)
                }
            }
        }

        // A review app has no use for the standard New Item group beyond New, and a
        // document that cannot be typed into has no use for the pasteboard's replace
        // commands. What it does need is a way to make a mark.
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Annotate Selection") { review?.beginAnnotation() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(review?.hasSelection != true)

            Menu("Annotate As") {
                ForEach(Intent.allCases) { intent in
                    // The kind is handed to the capture and applied when the page answers.
                    // It used to be set a turn later with a `DispatchQueue.main.async`,
                    // which is a guess about when the round trip lands rather than a fact
                    // about it.
                    Button(intent.title) { review?.beginAnnotation(intent) }
                        // Insert asks only for a caret; the rest act on something and need
                        // it selected.
                        .disabled(review.map { !$0.canAnnotate(intent) } ?? true)
                }
            }
            .disabled(review == nil)

            Divider()
            // Replying is offered whatever the annotation's state: it is a response, and
            // neither authorship nor a verdict has any business stopping one. The only
            // condition is having a row chosen to reply TO.
            Button("Reply to Annotation") {
                if let id = review?.selectedID { review?.beginReply(to: id) }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(review?.selectedID == nil)

            Button("Resolve Annotation") {
                if let id = review?.selectedID { review?.resolve(id) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(review?.selectedID == nil)
        }

        CommandGroup(after: .saveItem) {
            Divider()
            Button("Export Review…") {
                guard let review else { return }
                NotificationCenter.default.post(name: .revisShowExport, object: review)
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(review?.annotations.isEmpty != false)

            // Beside Export, because it is the same journey turned round: what was handed
            // out comes back with answers on it.
            Button("Import Replies…") {
                guard let review else { return }
                NotificationCenter.default.post(name: .revisImportReplies, object: review)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(review?.annotations.isEmpty != false)
        }

        CommandMenu("Review") {
            Picker("Tool", selection: toolBinding) {
                ForEach(ReviewTool.allCases) { tool in Text(tool.title).tag(tool) }
            }
            .pickerStyle(.inline)

            Divider()
            Picker("Show", selection: filterBinding) {
                ForEach(AnnotationFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        }

        CommandGroup(after: .sidebar) {
            Button("Zoom In") { review?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { review?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { review?.setZoom(1) }
                .keyboardShortcut("0", modifiers: .command)
            Button("Fit Width") { review?.zoomToFit() }
                .keyboardShortcut("9", modifiers: .command)
            Divider()
            Button(review?.useDocumentStyle == false ? "Use the Document's Stylesheet"
                                                     : "Use a Plain Reading Style") {
                guard let review else { return }
                withMotion(.reveal) { review.useDocumentStyle.toggle() }
            }
            .keyboardShortcut("y", modifiers: [.command, .shift])
            // Disabled rather than hidden: a menu whose items move about depending on the
            // document is one nobody learns. Greyed out, the shortcut still tells you the
            // command exists and this document has no use for it.
            .disabled(review?.hasDocumentStyle != true)
            Divider()
        }

        CommandGroup(before: .toolbar) {
            Button("Show Annotations") {
                if let review { withMotion(.panel) { review.togglePane(.annotations) } }
            }
            .keyboardShortcut("1", modifiers: [.command, .option])
            .disabled(review == nil)

            Button("Show Inspector") {
                if let review { withMotion(.panel) { review.togglePane(.outline) } }
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            .disabled(review == nil)
            Divider()
        }
    }

    /// A binding that does nothing when there is no window — a menu picker needs one
    /// whether or not anything is focused, and an optional-chained setter is quieter than
    /// hiding the whole menu.
    private var toolBinding: Binding<ReviewTool> {
        Binding(get: { review?.tool ?? .select }, set: { review?.tool = $0 })
    }

    private var filterBinding: Binding<AnnotationFilter> {
        Binding(get: { review?.filter ?? .open }, set: { review?.filter = $0 })
    }
}
