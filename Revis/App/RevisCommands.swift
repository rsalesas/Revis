import SwiftUI

/// The menu bar.
///
/// Every command acts on the focused window's model, reached through `@FocusedValue`
/// rather than through a shared singleton — two reviews open at once must not annotate
/// each other.
struct RevisCommands: Commands {
    @FocusedValue(\.activeReview) private var review

    var body: some Commands {
        // A review app has no use for the standard New Item group beyond New, and a
        // document that cannot be typed into has no use for the pasteboard's replace
        // commands. What it does need is a way to make a mark.
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Annotate Selection") { review?.beginAnnotationFromSelection() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(review?.hasSelection != true)

            Menu("Annotate As") {
                ForEach(Intent.allCases) { intent in
                    Button(intent.title) {
                        review?.beginAnnotationFromSelection()
                        // The intent is applied to whatever draft the capture opens. It
                        // arrives a turn later, since reading the selection out of the web
                        // view is a round trip.
                        DispatchQueue.main.async { review?.draft?.intent = intent }
                    }
                }
            }
            .disabled(review?.hasSelection != true)

            Divider()
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

        CommandGroup(before: .toolbar) {
            Button("Show Annotations") {
                guard let review else { return }
                withMotion(.panel) { review.annotationsVisible.toggle() }
            }
            .keyboardShortcut("1", modifiers: [.command, .option])
            .disabled(review == nil)

            Button("Show Inspector") {
                guard let review else { return }
                withMotion(.panel) { review.inspectorVisible.toggle() }
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
