import SwiftUI

/// Preferences.
///
/// Two tabs, and short ones. Most of what a document app keeps in here is about output —
/// page size, stylesheets, margins — and Revis has none of that: it shows the document as
/// it was sent and writes its review as text. What is left is who is reviewing, what a new
/// mark starts as, and what the export writes.
struct SettingsView: View {
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            SafetySettingsTab()
                .tabItem { Label("Safety", systemImage: "lock.shield") }
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
