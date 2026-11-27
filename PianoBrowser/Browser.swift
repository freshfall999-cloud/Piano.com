import SwiftUI
import WebKit

struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var url: String
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var url: String
    var date: Date
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case duckDuckGo, google, bing

    var id: String { rawValue }

    var name: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .google: return "Google"
        case .bing: return "Bing"
        }
    }

    func searchURL(for query: String) -> URL? {
        var components: URLComponents?
        switch self {
        case .duckDuckGo: components = URLComponents(string: "https://duckduckgo.com/")
        case .google: components = URLComponents(string: "https://www.google.com/search")
        case .bing: components = URLComponents(string: "https://www.bing.com/search")
        }
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

struct Suggestion: Identifiable {
    let id = UUID()
    let title: String
    let url: String
}

/// The whole browser: tabs, bookmarks, history, settings, and the link
/// between web pages and `MIDIManager`.
final class Browser: NSObject, ObservableObject {
    static let handlerName = "pianoMIDI"

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var selectedTabID = UUID()
    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var homeURL = UserDefaults.standard.string(forKey: "homeURL") ?? ""
    @Published private(set) var downloads: [DownloadItem] = []
    /// The download shown in the banner at the top of the page.
    @Published var bannerDownload: DownloadItem?
    @Published var filterEnabled = UserDefaults.standard.object(forKey: "filterEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(filterEnabled, forKey: "filterEnabled")
            if filterEnabled { filter.prewarm() }
        }
    }
    @Published var searchEngine = SearchEngine(rawValue: UserDefaults.standard.string(forKey: "searchEngine") ?? "") ?? .duckDuckGo {
        didSet { UserDefaults.standard.set(searchEngine.rawValue, forKey: "searchEngine") }
    }

    let midi: MIDIManager
    let filter = SiteFilter()
    private(set) lazy var trackers = TrackerBlocker(controller: userContentController)
    /// Websites that turned out not to offer https, so they aren't upgraded again.
    var httpOnlyHosts = Set<String>()
    /// The web view's own User-Agent, reused for accelerated downloads.
    var userAgent: String?
    private let userContentController = WKUserContentController()
    private var privateStore: WKWebsiteDataStore?
    private var allowedOrigins = Set(UserDefaults.standard.stringArray(forKey: "midiAllowedOrigins") ?? [])

    init(midi: MIDIManager) {
        self.midi = midi
        super.init()
        _ = trackers

        // Tells websites not to sell or share this visitor's data (Global Privacy Control).
        userContentController.addUserScript(WKUserScript(
            source: "try{Object.defineProperty(Navigator.prototype,'globalPrivacyControl',{value:true,configurable:true})}catch(e){}",
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if filterEnabled { filter.prewarm() }

        if let url = Bundle.main.url(forResource: "WebMIDIPolyfill", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        userContentController.addScriptMessageHandler(self, contentWorld: .page, name: Browser.handlerName)

        bookmarks = Storage.load([Bookmark].self, key: "bookmarks") ?? []
        history = Storage.load([HistoryEntry].self, key: "history") ?? []

        midi.onMessage = { [weak self] id, bytes in
            guard let tab = self?.selectedTab, tab.isListeningForMIDI else { return }
            let list = bytes.map { String($0) }.joined(separator: ",")
            tab.deliverMIDI("__pianoBrowserMIDI.receive(\"\(id)\",[\(list)]);0")
        }
        midi.onDevicesChanged = { [weak self] in
            guard let self,
                  let data = try? JSONSerialization.data(withJSONObject: self.devicePayload()),
                  let json = String(data: data, encoding: .utf8) else { return }
            for tab in self.tabs where tab.isListeningForMIDI {
                tab.deliverMIDI("__pianoBrowserMIDI.devices(\(json));0")
            }
        }

        restoreTabs()
        #if DEBUG
        if let test = UserDefaults.standard.string(forKey: "uiTestURL"), let url = url(fromInput: test) {
            let tab = newTab(url: url)
            if let script = UserDefaults.standard.string(forKey: "uiTestJS") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 7) { tab.webView.evaluateJavaScript(script, completionHandler: nil) }
            }
        }
        #endif
    }

    // MARK: Tabs

    var selectedTab: Tab {
        tabs.first { $0.id == selectedTabID } ?? tabs[0]
    }

    func makeConfiguration(isPrivate: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.upgradeKnownHostsToHTTPS = true
        if isPrivate {
            if privateStore == nil { privateStore = .nonPersistent() }
            configuration.websiteDataStore = privateStore ?? .nonPersistent()
        }
        return configuration
    }

    /// Opens a tab on `url`, or on the home page / start page when there is none.
    @discardableResult
    func newTab(url: URL? = nil, isPrivate: Bool = false) -> Tab {
        let tab = Tab(browser: self, configuration: makeConfiguration(isPrivate: isPrivate), isPrivate: isPrivate)
        tabs.append(tab)
        selectedTabID = tab.id
        if let url = url ?? URL(string: homeURL), !(url.absoluteString.isEmpty) {
            tab.load(url)
        }
        return tab
    }

    /// A tab for a page that asked for a new window; WebKit supplies the configuration.
    func openTab(configuration: WKWebViewConfiguration, opener: Tab) -> Tab {
        let tab = Tab(browser: self, configuration: configuration, isPrivate: opener.isPrivate, showsStartPage: false)
        let index = tabs.firstIndex { $0.id == opener.id } ?? tabs.count - 1
        tabs.insert(tab, at: index + 1)
        selectedTabID = tab.id
        return tab
    }

    func select(_ tab: Tab) {
        selectedTab.takeSnapshot()
        selectedTabID = tab.id
        tab.activate()
        saveTabs()
    }

    /// Moves to the tab before (-1) or after (+1) the current one.
    func selectAdjacentTab(_ step: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }), tabs.indices.contains(index + step) else { return }
        select(tabs[index + step])
    }

    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.stop()
        tabs.remove(at: index)
        if !tabs.contains(where: \.isPrivate) { privateStore = nil }
        if tabs.isEmpty {
            newTab()
        } else if selectedTabID == tab.id {
            let next = tabs[min(index, tabs.count - 1)]
            selectedTabID = next.id
            next.activate()
        }
        saveTabs()
    }

    func closeAllTabs() {
        tabs.forEach { $0.stop() }
        tabs.removeAll()
        privateStore = nil
        newTab()
        saveTabs()
    }

    private struct SavedTab: Codable {
        var url: String
        var title: String
    }

    /// Remembers open tabs (not private ones) for the next launch.
    func saveTabs() {
        let normal = tabs.filter { !$0.isPrivate }
        let saved = normal.compactMap { tab -> SavedTab? in
            guard let url = tab.displayURL, !url.isFileURL else { return nil }
            return SavedTab(url: url.absoluteString, title: tab.title)
        }
        Storage.save(saved, key: "tabs")
        let selected = normal.filter { $0.displayURL?.isFileURL == false }.firstIndex { $0.id == selectedTabID }
        UserDefaults.standard.set(selected ?? -1, forKey: "selectedTab")
    }

    private func restoreTabs() {
        let saved = Storage.load([SavedTab].self, key: "tabs") ?? []
        for item in saved {
            guard let url = URL(string: item.url) else { continue }
            tabs.append(Tab(browser: self, configuration: makeConfiguration(isPrivate: false), isPrivate: false,
                            restoring: url, title: item.title))
        }
        let index = UserDefaults.standard.integer(forKey: "selectedTab")
        if tabs.indices.contains(index) {
            selectedTabID = tabs[index].id
            tabs[index].activate()
        } else {
            newTab()
        }
    }

    // MARK: Addresses and suggestions

    /// Turns what was typed in the address bar into a URL: an address if it looks like one, otherwise a search.
    func url(fromInput raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil
            || text.lowercased().hasPrefix("about:") {
            return URL(string: text)
        }
        let lower = text.lowercased()
        if !text.contains(" "), text.contains(".") || lower.hasPrefix("localhost") {
            // Local servers (localhost, 192.168.1.20:3000, my-mac.local) rarely have https.
            let host = lower.split(separator: "/").first.map(String.init) ?? lower
            let isLocal = host.range(of: #"^(localhost|[0-9.]+|[^:]+\.local)(:[0-9]+)?$"#, options: .regularExpression) != nil
            if let url = URL(string: (isLocal ? "http://" : "https://") + text) { return url }
        }
        return searchEngine.searchURL(for: text)
    }

    func suggestions(for text: String) -> [Suggestion] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        var seen = Set<String>()
        var result: [Suggestion] = []
        let candidates = bookmarks.map { ($0.title, $0.url) } + history.map { ($0.title, $0.url) }
        for (title, url) in candidates where result.count < 6 {
            guard title.lowercased().contains(query) || url.lowercased().contains(query), seen.insert(url).inserted else { continue }
            result.append(Suggestion(title: title, url: url))
        }
        return result
    }

    // MARK: Bookmarks, history, home page

    func bookmark(for url: URL?) -> Bookmark? {
        guard let url = url?.absoluteString else { return nil }
        return bookmarks.first { $0.url == url }
    }

    func toggleBookmark(title: String, url: URL) {
        if let existing = bookmark(for: url) {
            bookmarks.removeAll { $0.id == existing.id }
        } else {
            bookmarks.append(Bookmark(title: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url.absoluteString))
        }
        Storage.save(bookmarks, key: "bookmarks")
    }

    func removeBookmarks(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        Storage.save(bookmarks, key: "bookmarks")
    }

    func recordVisit(title: String, url: URL) {
        let address = url.absoluteString
        if history.first?.url == address { history.removeFirst() }
        history.insert(HistoryEntry(title: title.isEmpty ? (url.host ?? address) : title, url: address, date: Date()), at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        Storage.save(history, key: "history")
    }

    func removeHistory(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        Storage.save(history, key: "history")
    }

    func clearHistoryAndData() {
        history.removeAll()
        Storage.save(history, key: "history")
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                modifiedSince: .distantPast) {}
    }

    func setHome(_ url: URL?) {
        homeURL = url?.absoluteString ?? ""
        UserDefaults.standard.set(homeURL, forKey: "homeURL")
    }

// MARK: Downloads

    var hasActiveDownloads: Bool { downloads.contains { $0.state == .running } }

    func register(_ item: DownloadItem) {
        item.onChange = { [weak self] in self?.objectWillChange.send() }
        downloads.insert(item, at: 0)
        bannerDownload = item
    }

    func removeDownload(_ item: DownloadItem) {
        item.cancel()
        downloads.removeAll { $0.id == item.id }
        if bannerDownload?.id == item.id { bannerDownload = nil }
    }

    func clearFinishedDownloads() {
        downloads.removeAll { $0.state != .running }
        if let banner = bannerDownload, banner.state != .running { bannerDownload = nil }
    }

    /// Fetches a large file over several connections, signed in with the tab's cookies.
    func startFastDownload(original: URLRequest?, response: HTTPURLResponse, from tab: Tab) {
        guard let url = response.url else { return }
        let destination = DownloadItem.uniqueDestination(for: response.suggestedFilename ?? url.lastPathComponent)
        let item = DownloadItem(name: destination.lastPathComponent, total: response.expectedContentLength)
        register(item)

        var request = URLRequest(url: url)
        if let referer = original?.value(forHTTPHeaderField: "Referer") { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        let etag = response.value(forHTTPHeaderField: "ETag")
        let validator = (etag.map { !$0.hasPrefix("W/") } ?? false) ? etag : response.value(forHTTPHeaderField: "Last-Modified")
        let total = response.expectedContentLength

        tab.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            guard item.state == .running else { return }
            let host = (url.host ?? "").lowercased()
            let path = url.path.isEmpty ? "/" : url.path
            let matching = cookies.filter { cookie in
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return (host == domain.lowercased() || host.hasSuffix("." + domain.lowercased()))
                    && path.hasPrefix(cookie.path) && (!cookie.isSecure || url.scheme == "https")
            }
            for (name, value) in HTTPCookie.requestHeaderFields(with: matching) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let downloader = FastDownloader(request: request, total: total, validator: validator, destination: destination, item: item)
            item.cancelAction = { downloader.cancel() }
            downloader.start()
        }
    }

        // MARK: MIDI permission

    var hasMIDIPermissions: Bool { !allowedOrigins.isEmpty }

    func resetMIDIPermissions() {
        allowedOrigins.removeAll()
        UserDefaults.standard.removeObject(forKey: "midiAllowedOrigins")
        objectWillChange.send()
    }

    func devicePayload() -> [String: Any] {
        ["inputs": midi.inputs.map(\.payload), "outputs": midi.outputs.map(\.payload)]
    }

    private func originKey(_ frame: WKFrameInfo) -> String {
        let origin = frame.securityOrigin
        return "\(origin.protocol)://\(origin.host):\(origin.port)"
    }

    func isMIDIAllowed(_ frame: WKFrameInfo) -> Bool {
        frame.securityOrigin.protocol == "file" || allowedOrigins.contains(originKey(frame))
    }

    /// Asks once per site before handing it the instruments.
    func authorizeMIDI(_ frame: WKFrameInfo, completion: @escaping (Bool) -> Void) {
        if isMIDIAllowed(frame) { return completion(true) }
        let host = frame.securityOrigin.host.isEmpty ? "This page" : "“\(frame.securityOrigin.host)”"
        let alert = UIAlertController(
            title: "\(host) would like to use your MIDI instruments",
            message: "It will be able to see what you play and send notes to connected instruments.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Don’t Allow", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "Allow", style: .default) { [weak self] _ in
            guard let self else { return completion(false) }
            self.allowedOrigins.insert(self.originKey(frame))
            UserDefaults.standard.set(Array(self.allowedOrigins), forKey: "midiAllowedOrigins")
            self.objectWillChange.send()
            completion(true)
        })
        Presenter.present(alert) { completion(false) }
    }
}

extension Browser: WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let tab = tabs.first(where: { $0.isWebViewLoaded && $0.webView === message.webView }),
              let body = message.body as? [String: Any], let type = body["type"] as? String else {
            return replyHandler(nil, "Bad message")
        }
        let frame = message.frameInfo
        switch type {
        case "request":
            authorizeMIDI(frame) { [weak self] allowed in
                guard let self, allowed else { return replyHandler(nil, "MIDI access was denied.") }
                tab.startListeningForMIDI(frame)
                self.midi.refresh()
                replyHandler(self.devicePayload(), nil)
            }
        case "send":
            if isMIDIAllowed(frame), let id = body["id"] as? String, let data = body["data"] as? [NSNumber] {
                midi.send(to: id, bytes: data.map { $0.uint8Value }, delayMs: (body["delay"] as? NSNumber)?.doubleValue ?? 0)
            }
            replyHandler(nil, nil)
        case "clear":
            if isMIDIAllowed(frame), let id = body["id"] as? String { midi.clear(id: id) }
            replyHandler(nil, nil)
        default:
            replyHandler(nil, "Unknown message")
        }
    }
}

/// Shows UIKit alerts and sheets on top of whatever SwiftUI is presenting.
enum Presenter {
    static func present(_ controller: UIViewController, orElse fallback: () -> Void = {}) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController else { return fallback() }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 1, height: 1)
        }
        top.present(controller, animated: true)
    }
}
