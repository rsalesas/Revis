import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A window asking for replies. Carries the model and nothing else — what is being
/// imported is typed or pasted into the sheet itself.
struct ReplyImportPreview: Identifiable {
    let id = UUID()
    var model: ReviewModel
}

/// Where answers come back in.
///
/// **Why this is shown and not merged.** `ExportSheet` shows a review before it leaves,
/// because what leaves is a prompt and its author should read it first. The argument is
/// stronger inwards: this is text a language model wrote, about to be filed under the
/// reviewer's own annotations and quoted back out in the next export. And there is no undo
/// manager anywhere in this app — so this sheet IS the undo, and it has to happen before
/// rather than after.
///
/// It shows each reply against the annotation it landed on, so "is this answering the right
/// question" is a thing you can see rather than trust. Anything that matched nothing is
/// shown in full rather than counted: what the model said is the valuable part, and a
/// reviewer told "1 reply did not match" has been told the least useful fact about it.
struct ReplyImportSheet: View {
    let preview: ReplyImportPreview
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettings
    @State private var author: String = ""
    /// The reply document, as text. **Pasted, usually.** The export's own Copy button
    /// exists because the commonest thing anybody does with a review is paste it into a
    /// chat window — so the answer comes back in that same window, as text, and asking for
    /// it to be saved to a file first would be inventing a step. A file is still accepted
    /// for one that was saved.
    @State private var raw = ""
    @State private var sourceName = "what you pasted"

    private var reading: ReplyImport.Reading { ReplyImport.read(raw) }
    private var landings: [ReplyImport.Landing] {
        ReplyImport.plan(reading, against: preview.model.annotations)
    }
    private var attachable: [ReplyImport.Landing] { landings.filter(\.isAttachable) }
    private var unmatched: [ReplyImport.Landing] { landings.filter { !$0.isAttachable } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            if raw.isEmpty {
                paste
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(attachable) { landing in
                            landingRow(landing)
                        }
                        if !unmatched.isEmpty { unmatchedSection }
                        if !reading.problems.isEmpty { problemsSection }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
            Divider().overlay(Theme.hairline)
            footer
        }
        .frame(width: 720, height: 560)
        .onAppear { author = appSettings.lastReplyAuthor }
        .onChange(of: raw) { _, _ in
            // The document's own name for itself wins: a reply that says who wrote it knows
            // better than a default does.
            if let named = landings.compactMap({ $0.reply.author }).first { author = named }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Replies to this review")
                .font(.system(size: 13, weight: .semibold))
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var summary: String {
        if raw.isEmpty {
            return "Paste what the assistant replied — the whole message is fine, anything"
                + " before the first item id is ignored."
        }
        if attachable.isEmpty && !landings.isEmpty {
            return "None of the \(landings.count) ids in \(sourceName) are in this review."
                + " This is probably a reply to a different one."
        }
        if landings.isEmpty {
            return "Nothing in \(sourceName) looked like a reply. A reply document has one"
                + " heading per item, and the heading is the item's id."
        }
        var text = "\(attachable.count) repl\(attachable.count == 1 ? "y" : "ies")"
            + " read from \(sourceName)."
        if !unmatched.isEmpty {
            text += " \(unmatched.count) name\(unmatched.count == 1 ? "s" : "")"
                + " an item that is not in this review."
        }
        return text
    }

    /// One reply against the annotation it will be filed under. The annotation is shown the
    /// way the pane shows it — same quote, same path — so "the right question" is a
    /// judgement the reviewer can make by looking rather than by trusting an id.
    @ViewBuilder
    private func landingRow(_ landing: ReplyImport.Landing) -> some View {
        if let target = landing.target,
           let annotation = preview.model.annotation(target) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Label(annotation.intent.title, systemImage: annotation.intent.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AnnotationPalette.color(for: annotation.intent))
                    if case .prefix(let length) = landing.match {
                        Text("matched by a short id of \(length) characters")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                if !annotation.note.isEmpty {
                    Text(annotation.note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(annotation.anchor.summary(limit: 140))
                    .font(.system(size: 10.5))
                    .italic()
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                Text(landing.reply.text)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.hairline).frame(width: 2)
                    }
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var unmatchedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("NOT ATTACHED")
            ForEach(unmatched) { landing in
                VStack(alignment: .leading, spacing: 3) {
                    Text("No item with the id \(landing.reply.rawID)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    // Whole, not summarised. This is the part worth keeping.
                    Text(landing.reply.text)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.top, 4)
    }

    private var problemsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("WHAT WAS SKIPPED")
            ForEach(Array(reading.problems.enumerated()), id: \.offset) { _, problem in
                Text(describe(problem))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private func describe(_ problem: ReplyImport.Problem) -> String {
        switch problem {
        case .noRepliesFound:
            return "No item ids were found in this file."
        case .emptyReply(let line, let rawID):
            return "Line \(line): the reply to \(rawID) has no text under it."
        case .ambiguousID(let line, let rawID, let candidates):
            return "Line \(line): \(rawID) is short enough to mean \(candidates) different"
                + " items, so it was not attached to either."
        }
    }

    /// The empty state, which is where most imports start.
    private var paste: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $raw)
                .font(.system(size: 11.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
            HStack(spacing: 10) {
                Button("Paste") {
                    raw = NSPasteboard.general.string(forType: .string) ?? ""
                    sourceName = "what you pasted"
                }
                .disabled(NSPasteboard.general.string(forType: .string)?.isEmpty != false)
                Button("Open File…") { openFile() }
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// For an answer that was saved rather than pasted. The extension is not insisted on —
    /// a model's output arrives named `.txt` as often as `.md`, and refusing to read one
    /// over its name would be the app losing an answer to a formality.
    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText,
                                     .plainText, .text]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Read Replies"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        sourceName = url.lastPathComponent
        raw = text
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Replies from")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Assistant", text: $author)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: 160)
                .help("Used for any reply whose document did not say who wrote it. They are"
                      + " marked as an assistant's either way — that records how they got"
                      + " in, which is not the document's to claim.")
            if !raw.isEmpty {
                Button("Start Over") { raw = "" }
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(attachable.count == 1 ? "Attach 1 reply"
                                         : "Attach \(attachable.count) replies") { attach() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(attachable.isEmpty)
        }
        .padding(16)
    }

    private func attach() {
        let name = author.trimmingCharacters(in: .whitespaces)
        appSettings.lastReplyAuthor = name.isEmpty ? "Assistant" : name
        preview.model.importReplies(landings, signedBy: appSettings.lastReplyAuthor)
        dismiss()
    }
}
