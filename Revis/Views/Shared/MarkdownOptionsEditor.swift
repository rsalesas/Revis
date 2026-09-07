import SwiftUI

/// What each switch costs the reader, in the terms a reviewer thinks in.
///
/// Written out here rather than as a line of grey text under each row, for the reason
/// Vaelora keeps its own: a column of twenty controls each with a sentence beneath it is a
/// wall nobody reads, and the one explanation somebody actually wants is the one they went
/// looking for. Every one of these says what turning it OFF does to the document on
/// screen, because that is the question being asked — a reviewer is deciding whether the
/// thing in front of them is what the author wrote.
enum MarkdownHelp {
    static let mode = "Markdown is not one language. A file written for one processor and"
        + " read as another loses whichever constructs that one does not know — they stay"
        + " on the page as punctuation rather than becoming tables and footnotes. Unified"
        + " reads everything Revis knows; CommonMark reads the specification and nothing"
        + " else."
    static let tables = "Read `| a | b |` rows as a table. Off, they stay on the page as"
        + " lines of pipes, which is what a processor without tables shows."
    static let relaxedTables = "Allow a table with no `|---|` rule under its header. Off by"
        + " default, and deliberately so even in the dialects that enable it: with it on,"
        + " an ordinary table that DOES have the rule loses its header row — the headings"
        + " come out as ordinary cells. A specification whose column headings have quietly"
        + " become data is not the document that was sent."
    static let gridTables = "Read Pandoc grid tables — the ones drawn with `+---+` corners."
    static let footnotes = "Read `[^1]` as a footnote: a numbered marker in the text and the"
        + " note collected at the foot of the document. Off, both the marker and the"
        + " definition stay where they are written, as literal brackets."
    static let definitionLists = "Read a line beginning `:` as the definition of the term"
        + " above it. Off, the colon is a colon."
    static let taskLists = "Draw `- [ ]` and `- [x]` as checkboxes rather than as brackets."
    static let callouts = "Read `> [!NOTE]` and the Obsidian and Bear spellings of it as a"
        + " callout block."
    static let strikethrough = "Read `~~text~~` as struck through. Off, the tildes show."
    static let supSub = "Read `^text^` as superscript and `~text~` as subscript."
    static let math = "Read `$…$` as mathematics. Off, the dollars are dollars — which is"
        + " what you want in a document that quotes prices."
    static let wikiLinks = "Read `[[Page]]` as a link. Off, it is four brackets and a word."
    static let autolink = "Turn a bare URL into a link. It is still shown in full either"
        + " way, so this changes nothing about what the document says."
    static let criticMarkup = "Read CriticMarkup — `{++inserted++}`, `{--deleted--}` — as"
        + " marks rather than as braces. On by default here because this is a review app,"
        + " and a document arriving with somebody else's tracked changes still in it is"
        + " both a thing that happens and a thing worth seeing."
    static let smartTypography = "Turn straight quotes curly, `---` into an em dash and"
        + " `...` into an ellipsis. Worth knowing that this is the one setting that makes"
        + " the words on screen differ from the words in the file — Revis folds the"
        + " difference back out when it locates a quote in the source, so the export still"
        + " quotes the file correctly either way."
    static let hardBreaks = "Break every line where the source breaks it, as a chat window"
        + " does. Off, because a document whose source is wrapped at 90 columns otherwise"
        + " renders as one ragged line per source line."
    static let showMetadata = "Show the `---` block at the top of the file. Off, because"
        + " frontmatter is machinery — a template name, a date, a status field — and a"
        + " reviewer opening a specification did not come to read it. It stays in the"
        + " source either way, and the export still quotes from it if you mark it."
}

/// The Markdown reading settings, as controls.
///
/// One view, two places, on purpose. The same switches appear in Settings, where they are
/// the guess made before a file is opened, and in a window's inspector, where they belong
/// to the document in front of you. Two copies of this list would drift, and the drift
/// would show up as a preference that does nothing — the reviewer sets it, opens a
/// document, and the document is read some other way.
struct MarkdownOptionsEditor: View {
    @Binding var options: MarkdownOptions

    var body: some View {
        SettingRow(title: "Read as", help: MarkdownHelp.mode) {
            Picker("", selection: $options.mode) {
                ForEach(MarkdownMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        Text(options.mode.detail)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

        SettingToggle(title: "Tables", isOn: $options.tables, help: MarkdownHelp.tables)
        SettingToggle(title: "Tables without a header rule", isOn: $options.relaxedTables,
                      help: MarkdownHelp.relaxedTables)
            .disabled(!options.tables)
        SettingToggle(title: "Grid tables", isOn: $options.gridTables,
                      help: MarkdownHelp.gridTables)
            .disabled(!options.tables)
        SettingToggle(title: "Footnotes", isOn: $options.footnotes,
                      help: MarkdownHelp.footnotes)
        SettingToggle(title: "Definition lists", isOn: $options.definitionLists,
                      help: MarkdownHelp.definitionLists)
        SettingToggle(title: "Task lists", isOn: $options.taskLists,
                      help: MarkdownHelp.taskLists)
        SettingToggle(title: "Callouts", isOn: $options.callouts, help: MarkdownHelp.callouts)
        SettingToggle(title: "Strikethrough", isOn: $options.strikethrough,
                      help: MarkdownHelp.strikethrough)
        SettingToggle(title: "Superscript and subscript", isOn: $options.supSub,
                      help: MarkdownHelp.supSub)
        SettingToggle(title: "Maths", isOn: $options.math, help: MarkdownHelp.math)
        SettingToggle(title: "Wiki links", isOn: $options.wikiLinks,
                      help: MarkdownHelp.wikiLinks)
        SettingToggle(title: "Link bare URLs", isOn: $options.autolink,
                      help: MarkdownHelp.autolink)
        SettingToggle(title: "Tracked changes", isOn: $options.criticMarkup,
                      help: MarkdownHelp.criticMarkup)
        SettingToggle(title: "Smart punctuation", isOn: $options.smartTypography,
                      help: MarkdownHelp.smartTypography)
        SettingToggle(title: "Every line break is a break", isOn: $options.hardBreaks,
                      help: MarkdownHelp.hardBreaks)
        SettingToggle(title: "Show the metadata block", isOn: $options.showMetadata,
                      help: MarkdownHelp.showMetadata)
    }
}

/// What the reviewer is told after a document has been read again.
///
/// Re-reading is not a display setting, and it must not look like one. The stylesheet
/// switch changes how the same document is drawn; this changes *what the document is* — a
/// row of pipes becomes a table, a paragraph splits in two — and every mark already on the
/// page was made against the other one.
///
/// Reported rather than confirmed beforehand. A dialog would have to be answered before
/// the reviewer could see what the answer costs, and there is nothing to protect them
/// from: no annotation is deleted, each still carries its own words, and setting the
/// dialect back puts them all where they were. What they do need is to be TOLD, because a
/// mark that has quietly stopped pointing at anything looks exactly like one that has not.
struct MarkdownRereadWarning: View {
    let disturbed: [Annotation]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(disturbed.count) annotation\(disturbed.count == 1 ? "" : "s") no longer"
                  + " match the document", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.warning)
            Text("Their quoted words are not in the document as it is now read. Nothing has"
                 + " been deleted — the marks are still in the review and still carry their"
                 + " words. Change the setting back to see them in place again.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(disturbed.prefix(6)) { annotation in
                Text("“" + annotation.anchor.summary(limit: 60) + "”")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
    }
}
