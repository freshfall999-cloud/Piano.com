import SwiftUI

/// The grid of open tabs.
struct TabSwitcherView: View {
    @EnvironmentObject private var browser: Browser
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(browser.tabs) { tab in
                        TabCard(tab: tab, isSelected: tab.id == browser.selectedTabID) {
                            browser.select(tab)
                            dismiss()
                        } onClose: {
                            withAnimation { browser.close(tab) }
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Menu {
                    Button { open(isPrivate: false) } label: { Label("New Tab", systemImage: "plus.square.on.square") }
                    Button { open(isPrivate: true) } label: { Label("New Private Tab", systemImage: "hand.raised") }
                    Button(role: .destructive) { browser.closeAllTabs(); dismiss() } label: {
                        Label("Close All \(browser.tabs.count) Tabs", systemImage: "xmark")
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 21))
                } primaryAction: {
                    open(isPrivate: false)
                }
                .accessibilityLabel("New Tab")
                Spacer()
                Text(browser.tabs.count == 1 ? "1 Tab" : "\(browser.tabs.count) Tabs")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.fontWeight(.semibold)
            }
            .padding(.horizontal, 22)
            .frame(height: 50)
            .background(.bar)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func open(isPrivate: Bool) {
        browser.newTab(isPrivate: isPrivate)
        dismiss()
    }
}

private struct TabCard: View {
    @ObservedObject var tab: Tab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Button(action: onSelect) {
                (tab.isPrivate ? Color(white: 0.16) : Color(.secondarySystemGroupedBackground))
                    .frame(height: 220)
                    .overlay(alignment: .top) {
                        if let snapshot = tab.snapshot {
                            Image(uiImage: snapshot).resizable().scaledToFill()
                        } else {
                            Image(systemName: tab.isPrivate ? "hand.raised.fill" : tab.showsStartPage ? "star.fill" : "globe")
                                .font(.system(size: 34))
                                .foregroundStyle(.tertiary)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 3 : 1)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                        .background(.regularMaterial, in: Circle())
                }
                .padding(7)
                .accessibilityLabel("Close \(tab.displayTitle)")
            }
            HStack(spacing: 5) {
                if tab.isPrivate {
                    Image(systemName: "hand.raised.fill").font(.caption2)
                } else if let url = tab.displayURL, !tab.isTestKeyboard {
                    SiteIcon(address: url.absoluteString, title: tab.displayTitle)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Text(tab.displayTitle).font(.caption.weight(.medium)).lineLimit(1)
            }
        }
    }
}
