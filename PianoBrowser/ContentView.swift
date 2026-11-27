import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject private var browser: Browser

    var body: some View {
        BrowserScreen(tab: browser.selectedTab, trackers: browser.trackers)
    }
}

/// The browser window, laid out like Safari: the page fills the screen and a
/// translucent bar with the address field and toolbar floats over its bottom edge.
struct BrowserScreen: View {
    @ObservedObject var tab: Tab
    @ObservedObject var trackers: TrackerBlocker
    @EnvironmentObject private var browser: Browser
    @EnvironmentObject private var midi: MIDIManager
    @FocusState private var addressFocused: Bool
    @State private var addressText = ""
    @State private var showInstruments = false
    @State private var showLibrary = false
    @State private var showSettings = UserDefaults.standard.string(forKey: "uiTestScreen") == "settings"
    @State private var showTabs = UserDefaults.standard.string(forKey: "uiTestScreen") == "tabs"
    @State private var fullScreen = false
    @State private var keyboardUp = false

    /// The bar steps aside while a web page's own keyboard is up, and in full screen.
    private var barHidden: Bool { fullScreen || (keyboardUp && !addressFocused) }
    private var showsCollapsedBar: Bool { tab.barCollapsed && !addressFocused && !tab.showsStartPage }

    /// How much of the page's bottom edge the bar covers; the page keeps its own content clear of it.
    private var barHeight: CGFloat { barHidden ? 0 : showsCollapsedBar ? Self.collapsedBarHeight : Self.fullBarHeight }
    private static let collapsedBarHeight: CGFloat = 26
    private static let fullBarHeight: CGFloat = 104

    var body: some View {
        ZStack {
            if tab.showsStartPage {
                StartPageView(tab: tab) { showInstruments = true }
            } else {
                WebViewContainer(webView: tab.webView, barHeight: barHeight)
                    .id(tab.id)
                    .ignoresSafeArea(.all, edges: .bottom)
            }
            if addressFocused { suggestions }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !barHidden {
                if showsCollapsedBar { collapsedBar } else { bar }
            }
        }
        .overlay(alignment: .top) { downloadBanner }
        .overlay(alignment: .bottomTrailing) {
            if fullScreen { exitFullScreenButton }
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
    }

    private func go(_ input: String) {
        addressFocused = false
        if let url = browser.url(fromInput: input) { tab.load(url) }
    }

    // MARK: Bottom bar

    private var bar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                addressCapsule
                if addressFocused {
                    Button("Cancel") { addressFocused = false }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, addressFocused ? 10 : 4)
            if !addressFocused { toolbar }
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// After scrolling down the bar shrinks to the site name; a tap brings it back.
    private var collapsedBar: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { tab.barCollapsed = false }
        } label: {
            HStack(spacing: 4) {
                if tab.isSecure { Image(systemName: "lock.fill").font(.system(size: 9)) }
                Text(tab.displayHost).font(.footnote.weight(.medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: Self.collapsedBarHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .accessibilityLabel("Show toolbar, \(tab.displayHost)")
    }

    private var addressCapsule: some View {
        HStack(spacing: 0) {
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
                    .padding(.leading, addressFocused ? 12 : 0)
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
            } else {
                InstrumentIndicator { showInstruments = true }
                if tab.showsStartPage {
                    Color.clear.frame(width: 40, height: 44)
                } else {
                    Button { tab.isLoading ? tab.stop() : tab.reload() } label: {
                        Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 40, height: 44)
                    }
                    .tint(.primary)
                    .accessibilityLabel(tab.isLoading ? "Stop" : "Reload")
                }
            }
        }
        .frame(height: 46)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.13), radius: 5, y: 1.5)
        .overlay(alignment: .bottom) {
            if tab.isLoading && !addressFocused {
                GeometryReader { proxy in
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(8, proxy.size.width * tab.progress), height: 2.5)
                }
                .frame(height: 2.5)
                .padding(.horizontal, 10)
            }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { drag in
            // Like Safari: swipe across the address bar to move between tabs.
            let distance = drag.translation.width
            guard !addressFocused, abs(distance) > 70, abs(distance) > abs(drag.translation.height) * 2 else { return }
            browser.selectAdjacentTab(distance < 0 ? 1 : -1)
        })
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
            Section {
                Button { showInstruments = true } label: { Label("Instruments", systemImage: "pianokeys") }
                Button { tab.loadTestKeyboard() } label: { Label("Test Keyboard", systemImage: "music.note") }
            }
            if let url = tab.displayURL, !tab.isTestKeyboard {
                Section {
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
                    if trackers.isEnabled, let host = url.host {
                        Button {
                            trackers.toggleExempt(host)
                            tab.reload()
                        } label: {
                            trackers.isExempt(host)
                                ? Label("Turn On Tracker Blocking Here", systemImage: "shield.lefthalf.filled")
                                : Label("Turn Off Tracker Blocking Here", systemImage: "shield.slash")
                        }
                    }
                    Button { browser.setHome(url) } label: { Label("Set as Home Page", systemImage: "house") }
                }
            }
            Section {
                Button { fullScreen = true } label: {
                    Label("Hide Toolbar", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
        } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .tint(.primary)
        .accessibilityLabel("Page Menu")
    }

    private var toolbar: some View {
        HStack {
            Button { tab.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(tab.showsStartPage || !tab.canGoBack)
                .accessibilityLabel("Back")
            Spacer()
            Button { tab.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(tab.showsStartPage || !tab.canGoForward)
                .accessibilityLabel("Forward")
            Spacer()
            if let url = tab.displayURL, !tab.isTestKeyboard {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share")
            } else {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.tertiary)
            }
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
        .padding(.horizontal, 28)
        .frame(height: 46)
    }

    // MARK: Overlays

    private var suggestions: some View {
        let matches = browser.suggestions(for: addressText)
        return ZStack(alignment: .bottom) {
            Color.black.opacity(0.25)
                .ignoresSafeArea(edges: .top)
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
        .accessibilityLabel("Show Toolbar")
    }
}

/// Piano icon in the address bar while an instrument is connected; flashes green as notes arrive.
/// Kept as its own view so incoming notes redraw only this icon.
private struct InstrumentIndicator: View {
    let action: () -> Void
    @EnvironmentObject private var midi: MIDIManager
    @State private var lit = false

    var body: some View {
        if !midi.inputs.isEmpty {
            Button(action: action) {
                Image(systemName: "pianokeys")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(lit ? Color.green : Color.accentColor)
                    .frame(width: 30, height: 44)
            }
            .onReceive(midi.activity) { _ in
                lit = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { lit = false }
            }
            .accessibilityLabel("Instruments, \(midi.inputs.count) connected")
        }
    }
}

/// Hosts a tab's web view full-height underneath the bottom bar, and tells WebKit
/// how much of it the bar covers so pages lay out (and pin their footers) above it.
struct WebViewContainer: UIViewControllerRepresentable {
    let webView: WKWebView
    let barHeight: CGFloat

    func makeUIViewController(context: Context) -> WebViewController {
        WebViewController(webView: webView)
    }

    func updateUIViewController(_ controller: WebViewController, context: Context) {
        controller.barHeight = barHeight
    }
}

final class WebViewController: UIViewController {
    private let webView: WKWebView
    var barHeight: CGFloat = 0 {
        didSet { if barHeight != oldValue { updateInsets() } }
    }

    init(webView: WKWebView) {
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.removeFromSuperview()
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)
        updateInsets()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateInsets()
    }

    /// Makes the bottom safe area exactly "home indicator + bar", whatever SwiftUI passed down.
    private func updateInsets() {
        guard isViewLoaded else { return }
        let system = view.safeAreaInsets.bottom - additionalSafeAreaInsets.bottom
        let wanted = barHeight == 0 ? system : barHeight + (view.window?.safeAreaInsets.bottom ?? 0)
        let extra = max(0, wanted - system)
        if abs(extra - additionalSafeAreaInsets.bottom) > 0.5 { additionalSafeAreaInsets.bottom = extra }
    }
}
