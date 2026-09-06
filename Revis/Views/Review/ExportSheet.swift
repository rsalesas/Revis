import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A rendered review, ready to leave the app.
struct ExportPreview: Identifiable {
    let id = UUID()
    var markdown: String
    var json: String
    var suggestedName: String
}

/// Where a review turns into instructions.
///
/// **Why the export is shown rather than just written.** What leaves this app is a prompt:
/// somebody is going to hand it to an assistant and let it edit their document. A person
/// about to do that should be able to read it first — to see that "Change" came out as
/// *rewrite the quoted text*, that their note is attached to the passage they meant, and
/// that nothing they wrote in a hurry says something they did not mean. A file written
/// silently to disk is read by the model before it is read by its author.
struct ExportSheet: View {
    let preview: ExportPreview
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettings
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            ScrollView {
                Text(preview.markdown)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider().overlay(Theme.hairline)
            footer
        }
        .frame(width: 720, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Review as instructions")
                .font(.system(size: 13, weight: .semibold))
            Text("Hand this to whatever wrote the document. Every item names an operation,"
                 + " the exact text it applies to, and what you asked for.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("Also write the JSON sidecar", isOn: $appSettings.exportSidecar)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("A machine-readable copy of the same items, for a script that applies"
                      + " them rather than a model that reads them.")
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(copied ? "Copied" : "Copy") { copy() }
                .disabled(copied)
            Button("Save…") { save() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    /// The commonest thing anybody will do with this: straight onto the clipboard and into
    /// a chat window. Worth a button of its own rather than making them select 400 lines.
    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(preview.markdown, forType: .string)
        copied = true
        // Reset, so a second export is not offered a button that says it already worked.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = preview.suggestedName + " review.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try preview.markdown.write(to: url, atomically: true, encoding: .utf8)
            if appSettings.exportSidecar {
                // Beside the Markdown and named after it, so the pair travels together and
                // it is obvious which JSON belongs to which review.
                let sidecar = url.deletingPathExtension().appendingPathExtension("json")
                try preview.json.write(to: sidecar, atomically: true, encoding: .utf8)
            }
            dismiss()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "The review could not be saved."
            alert.runModal()
        }
    }
}
