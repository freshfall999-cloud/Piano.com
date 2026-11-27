import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject private var browser: BrowserModel
    @EnvironmentObject private var midi: MIDIManager
    @FocusState private var addressFocused: Bool
    @State private var showInstruments = false
    @State private var fullScreen = false
    @State private var activityLit = false

    var body: some View {
        VStack(spacing: 0) {
            if !fullScreen { addressBar }
            WebViewContainer(webView: browser.webView)
                .overlay(alignment: .top) {
                    if browser.isLoading {
                        ProgressView(value: browser.progress).progressViewStyle(.linear)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if fullScreen { exitFullScreenButton }
                }
            if !fullScreen { toolbar }
        }
        .statusBarHidden(fullScreen)
        .persistentSystemOverlays(fullScreen ? .hidden : .automatic)
        .sheet(isPresented: $showInstruments) {
            InstrumentsView()
                .environmentObject(browser)
                .environmentObject(midi)
        }
        .onChange(of: addressFocused) { focused in
            browser.isEditingAddress = focused
        }
        .onReceive(midi.$activityTick.dropFirst()) { _ in
            activityLit = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { activityLit = false }
        }
    }

    private var addressBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: browser.pageURL?.scheme == "https" ? "lock.fill" : "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("Search or enter address", text: $browser.addressText)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit { browser.load(input: browser.addressText) }
                if addressFocused && !browser.addressText.isEmpty {
                    Button { browser.addressText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear address")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

            if addressFocused {
                Button("Cancel") { addressFocused = false }
            } else {
                Button { browser.reloadOrStop() } label: {
                    Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
                }
                .accessibilityLabel(browser.isLoading ? "Stop" : "Reload")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    private var toolbar: some View {
        HStack {
            Button { browser.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!browser.canGoBack)
                .accessibilityLabel("Back")
            Spacer()
            Button { browser.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!browser.canGoForward)
                .accessibilityLabel("Forward")
            Spacer()
            Button { showInstruments = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "pianokeys")
                    Text("\(midi.inputs.count)")
                        .font(.footnote.monospacedDigit().weight(.semibold))
                    Circle()
                        .fill(activityLit ? Color.green : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityLabel("Instruments, \(midi.inputs.count) connected")
            Spacer()
            Button { browser.loadHome() } label: { Image(systemName: "house") }
                .accessibilityLabel("Home")
            Spacer()
            menu
        }
        .font(.title3)
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { Divider() }
    }

    private var menu: some View {
        Menu {
            Button { fullScreen = true } label: {
                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            if let url = browser.pageURL, !browser.isOnStartPage {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                Button { browser.toggleBookmark() } label: {
                    browser.currentBookmark == nil
                        ? Label("Add Bookmark", systemImage: "bookmark")
                        : Label("Remove Bookmark", systemImage: "bookmark.slash")
                }
                Button { browser.setHomeToCurrentPage() } label: {
                    Label("Set as Home Page", systemImage: "house")
                }
            }
            if !browser.homeURL.isEmpty {
                Button { browser.resetHome() } label: {
                    Label("Reset Home Page", systemImage: "house.slash")
                }
            }
            Button { browser.loadStartPage() } label: {
                Label("Test Keyboard", systemImage: "pianokeys")
            }
            if !browser.bookmarks.isEmpty {
                Section("Bookmarks") {
                    ForEach(browser.bookmarks) { bookmark in
                        Button(bookmark.title) { browser.load(input: bookmark.url) }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
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
