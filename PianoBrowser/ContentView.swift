import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject private var browser: Browser

    var body: some View {
        BrowserScreen(tab: browser.selectedTab)
    }
}

/// The browser window: page on top, Safari-style address bar and toolbar at the bottom.
struct BrowserScreen: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject private var browser: Browser
    @EnvironmentObject private var midi: MIDIManager
    @FocusState private var addressFocused: Bool
    @State private var addressText = ""
    @State private var showInstruments = false
    @State private var showLibrary = false
    @State private var showSettings = false
    @State private var showTabs = UserDefaults.standard.string(forKey: "uiTestScreen") == "tabs"
    @State private var fullScreen = false
    @State private var activityLit = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                WebViewContainer(webView: tab.webView)
                    .id(tab.id)
                if tab.showsStartPage {
                    StartPageView(tab: tab) { showInstruments = true }
                }
                if addressFocused { suggestions }
            }
            .overlay(alignment: .top) { downloadBanner }
            .overlay(alignment: .bottomTrailing) {
                if fullScreen { exitFullScreenButton }
            }
            if !fullScreen { chrome }
        }
        .statusBarHidden(fullScreen)
        .persistentSystemOverlays(fullScreen ? .hidden : .automatic)
        .sheet(isPresented: $showInstruments) {
            InstrumentsView().environmentObject(browser).environmentObject(midi)
        }
        .sheet(isPresented: $showLibrary) {
            LibraryView().environmentObject(browser)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(browser)
        }
        .fullScreenCover(isPresented: $showTabs) {
            TabSwitcherView().environmentObject(browser)
        }
        .onChange(of: addressFocused) { focused in
            if focused { addressText = tab.isTestKeyboard ? "" : (tab.displayURL?.absoluteString ?? "") }
        }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { note in
            // Like Safari: tapping the address selects it all, ready to type over.
            if addressFocused, let field = note.object as? UITextField {
                DispatchQueue.main.async { field.selectAll(nil) }
            }
        }
        .onReceive(midi.$activityTick.dropFirst()) { _ in
            activityLit = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { activityLit = false }
        }
    }

    private func go(_ input: String) {
        addressFocused = false
        if let url = browser.url(fromInput: input) { tab.load(url) }
    }

    // MARK: Bottom bar

    private var chrome: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                addressCapsule
                if addressFocused {
                    Button("Cancel") { addressFocused = false }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, addressFocused ? 8 : 2)
            if !addressFocused { toolbar }
        }
        .background(.bar)
    }

    private var addressCapsule: some View {
        HStack(spacing: 4) {
            if !addressFocused { pageMenu }
            ZStack {
                TextField("", text: $addressText)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit { go(addressText) }
                    .foregroundColor(addressFocused ? .primary : .clear)
                    .tint(addressFocused ? .accentColor : .clear)
                    .padding(.leading, addressFocused ? 10 : 0)
                if !addressFocused { addressLabel.allowsHitTesting(false) }
            }
            if addressFocused {
                if !addressText.isEmpty {
                    Button { addressText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 10)
                    .accessibilityLabel("Clear")
                }
            } else if !tab.showsStartPage {
                Button { tab.isLoading ? tab.webView.stopLoading() : tab.reload() } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 40, height: 44)
                }
                .tint(.primary)
                .accessibilityLabel(tab.isLoading ? "Stop" : "Reload")
            } else {
                Color.clear.frame(width: 40, height: 44)
            }
        }
        .frame(height: 44)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottom) {
            if tab.isLoading && !addressFocused {
                GeometryReader { proxy in
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(8, proxy.size.width * tab.progress), height: 2.5)
                }
                .frame(height: 2.5)
                .padding(.horizontal, 8)
            }
        }
    }

    private var addressLabel: some View {
        HStack(spacing: 5) {
            if tab.displayHost.isEmpty {
                Image(systemName: "magnifyingglass").font(.footnote)
                Text("Search or enter website name")
            } else {
                if tab.isPrivate {
                    Image(systemName: "hand.raised.fill").font(.caption)
                } else if tab.isSecure {
                    Image(systemName: "lock.fill").font(.caption2)
                } else if tab.internalPageFor == nil, tab.displayURL?.scheme == "http" {
                    Text("Not Secure —")
                }
                Text(tab.displayHost).foregroundStyle(.primary)
            }
        }
        .lineLimit(1)
        .foregroundStyle(.secondary)
    }

    private var pageMenu: some View {
        Menu {
            if let url = tab.displayURL, !tab.isTestKeyboard {
                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                Button { browser.toggleBookmark(title: tab.title, url: url) } label: {
                    browser.bookmark(for: url) == nil
                        ? Label("Add Bookmark", systemImage: "bookmark")
                        : Label("Remove Bookmark", systemImage: "bookmark.slash")
                }
                Button { tab.findOnPage() } label: { Label("Find on Page", systemImage: "doc.text.magnifyingglass") }
                Button { tab.toggleDesktopSite() } label: {
                    tab.desktopSite
                        ? Label("Request Mobile Website", systemImage: "iphone")
                        : Label("Request Desktop Website", systemImage: "desktopcomputer")
                }
                Button { browser.setHome(url) } label: { Label("Set as Home Page", systemImage: "house") }
            }
            Button { fullScreen = true } label: {
                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button { tab.loadTestKeyboard() } label: { Label("Test Keyboard", systemImage: "pianokeys") }
            Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .tint(.primary)
        .accessibilityLabel("Page Menu")
    }

    private var toolbar: some View {
        HStack {
            Button { tab.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!tab.canGoBack)
                .accessibilityLabel("Back")
            Spacer()
            Button { tab.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!tab.canGoForward)
                .accessibilityLabel("Forward")
            Spacer()
            Button { showInstruments = true } label: {
                Image(systemName: "pianokeys")
                    .overlay(alignment: .topTrailing) {
                        if !midi.inputs.isEmpty {
                            Circle()
                                .fill(activityLit ? Color.green : Color.accentColor)
                                .frame(width: 8, height: 8)
                                .offset(x: 6, y: -4)
                        }
                    }
            }
            .accessibilityLabel("Instruments, \(midi.inputs.count) connected")
            Spacer()
            Button { showLibrary = true } label: { Image(systemName: "book") }
                .accessibilityLabel("Bookmarks and History")
            Spacer()
            Button {
                tab.takeSnapshot()
                showTabs = true
            } label: { Image(systemName: "square.on.square") }
                .contextMenu {
                    Button { browser.newTab() } label: { Label("New Tab", systemImage: "plus.square.on.square") }
                    Button { browser.newTab(isPrivate: true) } label: { Label("New Private Tab", systemImage: "hand.raised") }
                    Button(role: .destructive) { browser.close(tab) } label: { Label("Close This Tab", systemImage: "xmark") }
                }
                .accessibilityLabel("Tabs, \(browser.tabs.count) open")
        }
        .font(.system(size: 21))
        .padding(.horizontal, 26)
        .frame(height: 46)
    }

    // MARK: Overlays

    private var suggestions: some View {
        let matches = browser.suggestions(for: addressText)
        return ZStack(alignment: .bottom) {
            Color.black.opacity(0.25)
                .onTapGesture { addressFocused = false }
            if !matches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(matches) { match in
                        Button { go(match.url) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "globe").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(match.title).foregroundStyle(.primary)
                                    Text(match.url).font(.footnote).foregroundStyle(.secondary)
                                }
                                .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                        }
                        Divider().padding(.leading, 46)
                    }
                }
                .background(Color(.systemBackground))
            }
        }
    }

    @ViewBuilder
    private var downloadBanner: some View {
        if let file = browser.lastDownload {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.lastPathComponent).lineLimit(1)
                    Text("Saved to Files › Piano Browser").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                Button { browser.finishedDownload(nil) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(10)
        }
    }

    private var exitFullScreenButton: some View {
        Button { fullScreen = false } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.footnote.weight(.semibold))
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(10)
        .opacity(0.7)
        .accessibilityLabel("Exit Full Screen")
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
