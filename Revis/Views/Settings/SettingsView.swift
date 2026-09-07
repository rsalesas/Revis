import SwiftUI

/// Preferences.
///
/// Four tabs, and short ones. Most of what a document app keeps in here is about output —
/// page size, stylesheets, margins — and Revis has none of that: it shows the document as
/// it was sent and writes its review as text. What is left is who is reviewing, what a new
/// mark starts as, what the export writes, and — for the one kind of document Revis does
/// not simply show, but has to read first — how Markdown is read. The last tab is there
/// because the licences of the software that does that reading require it.
struct SettingsView: View {
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            MarkdownSettingsTab()
                .tabItem { Label("Markdown", systemImage: "text.alignleft") }
            SafetySettingsTab()
                .tabItem { Label("Safety", systemImage: "lock.shield") }
            AcknowledgementsSettingsTab()
                .tabItem { Label("Acknowledgements", systemImage: "text.book.closed") }
        }
        .frame(width: 480)
        .padding(.top, 4)
    }
}

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        Form {
            Section {
                TextField("Reviewer", text: $appSettings.reviewerName,
                          prompt: Text(AppSettings.systemName))
                Text("Annotations are signed with this name, and the export attributes each"
                     + " instruction to it. Leave it empty for an unsigned review.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("New annotations are", selection: $appSettings.defaultIntent) {
                    ForEach(Intent.allCases) { intent in
                        Label(intent.title, systemImage: intent.symbol).tag(intent)
                    }
                }
                Picker("Windows open in", selection: $appSettings.defaultTool) {
                    ForEach(ReviewTool.allCases) { tool in
                        Label(tool.title, systemImage: tool.symbol).tag(tool)
                    }
                }
            }

            Section {
                Toggle("Show documents with their own stylesheet",
                       isOn: $appSettings.useDocumentStyle)
                Picker("Documents open at", selection: $appSettings.defaultZoom) {
                    Text("Fit width").tag(0.0)
                    Divider()
                    ForEach(ReviewModel.zoomPresets, id: \.self) { stop in
                        Text("\(Int((stop * 100).rounded()))%").tag(stop)
                    }
                }
                Text("A document is reviewed as it was sent, so its own stylesheet is used"
                     + " by default. Either can be changed for one window from the bar along"
                     + " the bottom.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Write a JSON sidecar when exporting", isOn: $appSettings.exportSidecar)
                Text("A machine-readable copy of the same items, saved beside the Markdown."
                     + " Useful for a script that applies the review rather than a model"
                     + " that reads it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

/// Not a settings tab so much as a statement of what the app does.
///
/// There is nothing here to switch off, and that is the point: every one of these is a
/// property of how the document is loaded, and an app whose safety could be turned off in
/// a preference would have to be treated as though it already had been. It is written down
/// because a reviewer opening an untrusted file deserves to know what was done to it, and
/// because a claim that can be read is a claim that can be checked.
/// How a Markdown document is read, before anybody has looked at it.
///
/// Every switch here is a default and nothing more. The settings that decide a document
/// are stored in its review and changed in that window's inspector, because the dialect a
/// file is written in is a fact about the file, not a preference of the reader's.
private struct MarkdownSettingsTab: View {
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        Form {
            Section {
                MarkdownOptionsEditor(options: $appSettings.markdownDefaults)
            }
            Section {
                Text("A Markdown document is scrubbed by the same sanitizer as any other"
                     + " before it is shown, and cannot pull in other files or run anything,"
                     + " whatever it asks for.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // Tall enough to show the list, rather than letting the settings window size
        // itself to the General tab and clip this one to eight rows and a cut edge. It
        // still scrolls, for a short screen.
        .frame(height: 560)
    }
}

/// The licences of the open source software Revis reads Markdown with.
///
/// Here because they say to be. All three require their notice to be reproduced wherever
/// the software is redistributed, and an application is a redistribution — so the text is
/// shipped in the bundle, verbatim, rather than summarised into something shorter that
/// would not satisfy them.
///
/// Its own tab rather than a paragraph at the foot of the Markdown one: a licence is not a
/// setting, and a reviewer scrolling to the end of a column of switches has not gone
/// looking for one.
private struct AcknowledgementsSettingsTab: View {
    var body: some View {
        ScrollView {
            Text(DocumentShell.bundleString(named: "ACKNOWLEDGEMENTS", ext: "txt"))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .frame(height: 560)
    }
}

private struct SafetySettingsTab: View {
    var body: some View {
        Form {
            Section("A reviewed document cannot") {
                claim("Run any code", "Every script is removed before the file reaches the"
                      + " renderer, and the page is then loaded under a policy that forbids"
                      + " scripts outright.")
                claim("Reach the network", "No fetch, no image, no font, no stylesheet from"
                      + " anywhere. Release builds ship without the entitlement that would"
                      + " make it possible at all.")
                claim("Navigate anywhere", "Links are shown but inert; every navigation"
                      + " after the first load is cancelled.")
                claim("Read your files", "Images are resolved by the app, from inside the"
                      + " document's own folder, and embedded before the document is shown."
                      + " The page never asks for a file itself.")
                claim("Leave anything behind", "Cookies and storage are non-persistent, so"
                      + " one document cannot leave a trace for the next.")
            }

            Section {
                Text("What had to be removed from a particular document is listed in that"
                     + " window's inspector, under Document.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func claim(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: "checkmark.shield")
                .font(.system(size: 12, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
