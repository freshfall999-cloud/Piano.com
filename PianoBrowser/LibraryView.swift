import SwiftUI

/// Bookmarks and history, behind the book button.
struct LibraryView: View {
    @EnvironmentObject private var browser: Browser
    @Environment(\.dismiss) private var dismiss
    @State private var showHistory = false
    @State private var search = ""
    @State private var confirmClear = false

    private var entries: [HistoryEntry] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return browser.history }
        return browser.history.filter { $0.title.lowercased().contains(query) || $0.url.lowercased().contains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if showHistory {
                    if entries.isEmpty {
                        Text(search.isEmpty ? "Pages you visit will appear here." : "No matches.").foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        row(title: entry.title, address: entry.url, detail: entry.date.formatted(.relative(presentation: .named)))
                            .swipeActions {
                                Button("Delete", role: .destructive) { browser.removeHistory(entry) }
                            }
                    }
                } else {
                    if browser.bookmarks.isEmpty {
                        Text("Add bookmarks from the menu in the address bar.").foregroundStyle(.secondary)
                    }
                    ForEach(browser.bookmarks) { bookmark in
                        row(title: bookmark.title, address: bookmark.url, detail: nil)
                    }
                    .onDelete { browser.removeBookmarks(at: $0) }
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $showHistory) {
                        Image(systemName: "book").tag(false)
                        Image(systemName: "clock").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    if showHistory && !browser.history.isEmpty {
                        Button("Clear") { confirmClear = true }
                    }
                }
            }
            .confirmationDialog("Clear all history, cookies and website data?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear History and Data", role: .destructive) { browser.clearHistoryAndData() }
            }
        }
    }

    private func row(title: String, address: String, detail: String?) -> some View {
        Button {
            if let url = URL(string: address) { browser.selectedTab.load(url) }
            dismiss()
        } label: {
            HStack(spacing: 12) {
                SiteIcon(address: address, title: title)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary)
                    Text(address).font(.footnote).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer()
                if let detail { Text(detail).font(.caption).foregroundStyle(.tertiary) }
            }
        }
    }
}
