import SwiftUI

enum LibrarySection: Hashable, Identifiable {
    case bookmarks, history, downloads

    var id: Self { self }
}

/// Bookmarks, history and downloads, behind the book button.
struct LibraryView: View {
    @EnvironmentObject private var browser: Browser
    @Environment(\.dismiss) private var dismiss
    @State var section: LibrarySection
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
                switch section {
                case .bookmarks:
                    if browser.bookmarks.isEmpty {
                        Text("Add bookmarks from the AA menu in the address bar.").foregroundStyle(.secondary)
                    }
                    ForEach(browser.bookmarks) { bookmark in
                        row(title: bookmark.title, address: bookmark.url, detail: nil)
                    }
                    .onDelete { browser.removeBookmarks(at: $0) }
                case .history:
                    if entries.isEmpty {
                        Text(search.isEmpty ? "Pages you visit will appear here." : "No matches.").foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        row(title: entry.title, address: entry.url, detail: entry.date.formatted(.relative(presentation: .named)))
                            .swipeActions {
                                Button("Delete", role: .destructive) { browser.removeHistory(entry) }
                            }
                    }
                case .downloads:
                    if browser.downloads.isEmpty {
                        Text("Files you download will appear here and in the Files app, under Piano Browser.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(browser.downloads) { item in
                        DownloadRow(item: item)
                            .swipeActions {
                                Button("Remove", role: .destructive) { browser.removeDownload(item) }
                            }
                    }
                }
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .top, spacing: 0) {
                if section == .history {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search History", text: $search).autocorrectionDisabled()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .background(.bar)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $section) {
                        Image(systemName: "book").tag(LibrarySection.bookmarks)
                        Image(systemName: "clock").tag(LibrarySection.history)
                        Image(systemName: "arrow.down.circle").tag(LibrarySection.downloads)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    if section == .history && !browser.history.isEmpty {
                        Button("Clear") { confirmClear = true }
                    } else if section == .downloads && !browser.downloads.isEmpty {
                        Button("Clear") { browser.clearFinishedDownloads() }
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
