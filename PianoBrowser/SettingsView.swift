import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var browser: Browser
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Block Unsafe and Adult Websites", isOn: $browser.filterEnabled)
                } header: {
                    Text("Protection")
                } footer: {
                    Text("Blocks websites known for malware, phishing or adult content, and turns on safe search in Google, Bing, DuckDuckGo and Yahoo. To check a website, its name (not the page or what you do there) is sent to Cloudflare’s family filter. Fraudulent-website warnings are always on.")
                }

                Section("Search") {
                    Picker("Search Engine", selection: $browser.searchEngine) {
                        ForEach(SearchEngine.allCases) { engine in
                            Text(engine.name).tag(engine)
                        }
                    }
                }

                Section {
                    LabeledContent("Opens", value: browser.homeURL.isEmpty ? "Start Page" : browser.homeURL)
                        .lineLimit(1)
                    if !browser.homeURL.isEmpty {
                        Button("Use Start Page") { browser.setHome(nil) }
                    }
                } header: {
                    Text("New Tabs")
                } footer: {
                    Text("To open your piano app in every new tab, visit it and choose Set as Home Page from the ••• menu.")
                }

                Section {
                    Button("Clear History and Website Data", role: .destructive) { confirmClear = true }
                    if browser.hasMIDIPermissions {
                        Button("Forget Websites Allowed to Use MIDI", role: .destructive) { browser.resetMIDIPermissions() }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Clear all history, cookies and website data?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear History and Data", role: .destructive) { browser.clearHistoryAndData() }
            }
        }
    }
}
