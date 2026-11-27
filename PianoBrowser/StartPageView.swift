import SwiftUI

/// What a new tab shows: favorites, like Safari's start page.
struct StartPageView: View {
    @ObservedObject var tab: Tab
    let openInstruments: () -> Void
    @EnvironmentObject private var browser: Browser
    @EnvironmentObject private var midi: MIDIManager

    var body: some View {
        StartPageContent(tab: tab, trackers: browser.trackers, openInstruments: openInstruments)
    }
}

private struct StartPageContent: View {
    @ObservedObject var tab: Tab
    @ObservedObject var trackers: TrackerBlocker
    let openInstruments: () -> Void
    @EnvironmentObject private var browser: Browser
    @EnvironmentObject private var midi: MIDIManager

    private let columns = [GridItem(.adaptive(minimum: 74), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if tab.isPrivate {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Private Browsing", systemImage: "hand.raised.fill").font(.headline)
                        Text("Pages you open in this tab aren’t added to History, and their cookies are forgotten when you close your private tabs.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Text("Favorites").font(.title2.bold())
                LazyVGrid(columns: columns, spacing: 18) {
                    Button { tab.loadTestKeyboard() } label: {
                        FavoriteTile(title: "Test Keyboard") {
                            Image(systemName: "pianokeys")
                                .font(.system(size: 26))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(red: 0.76, green: 0.25, blue: 0.05))
                        }
                    }
                    .buttonStyle(.plain)
                    ForEach(browser.bookmarks) { bookmark in
                        Button {
                            if let url = URL(string: bookmark.url) { tab.load(url) }
                        } label: {
                            FavoriteTile(title: bookmark.title) { SiteIcon(address: bookmark.url, title: bookmark.title) }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if browser.bookmarks.isEmpty {
                    Text("Websites you bookmark from the address bar menu appear here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("Privacy Report").font(.title3.bold())
                HStack(spacing: 12) {
                    Image(systemName: trackers.isEnabled ? "shield.lefthalf.filled" : "shield.slash")
                        .font(.title2)
                        .foregroundStyle(trackers.isEnabled ? Color.accentColor : Color.secondary)
                    Text(trackers.isEnabled
                         ? "Piano Browser stops \(trackers.ruleCount.formatted()) known trackers and ad servers from following you across websites."
                         : "Tracker blocking is turned off in Settings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text("Instruments").font(.title3.bold())
                Button(action: openInstruments) {
                    HStack(spacing: 12) {
                        Image(systemName: "pianokeys").font(.title3).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(midi.inputs.isEmpty ? "No instrument connected"
                                 : midi.inputs.count == 1 ? midi.inputs[0].name : "\(midi.inputs.count) instruments connected")
                                .foregroundStyle(.primary)
                            Text(midi.inputs.isEmpty ? "Plug in with USB or pair over Bluetooth" : "Ready for web apps that use MIDI")
                                .font(.footnote)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 130)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }
}

private struct FavoriteTile<Icon: View>: View {
    let title: String
    @ViewBuilder let icon: Icon

    var body: some View {
        VStack(spacing: 6) {
            icon
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            Text(title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A site's home-screen icon when it has one, otherwise its initial.
struct SiteIcon: View {
    let address: String
    let title: String

    private var iconURL: URL? {
        guard let url = URL(string: address), let host = url.host, url.scheme == "https" else { return nil }
        return URL(string: "https://\(host)/apple-touch-icon.png")
    }

    var body: some View {
        AsyncImage(url: iconURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Text(String((title.first { $0.isLetter || $0.isNumber } ?? "•")).uppercased())
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemGroupedBackground))
            }
        }
    }
}
