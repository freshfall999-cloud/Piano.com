import Combine
import SwiftUI
import WebKit

struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var url: String
}

/// Owns the web view, and is the bridge between web pages and `MIDIManager`.
final class BrowserModel: NSObject, ObservableObject {
    static let handlerName = "pianoMIDI"

    @Published var addressText = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var pageURL: URL?
    @Published private(set) var pageTitle = ""
    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var homeURL = UserDefaults.standard.string(forKey: "homeURL") ?? ""

    /// While the address field has focus, navigation doesn't overwrite what's being typed.
    var isEditingAddress = false {
        didSet { if !isEditingAddress { addressText = displayAddress } }
    }

    let webView: WKWebView
    private let midi: MIDIManager
    private var allowedOrigins = Set(UserDefaults.standard.stringArray(forKey: "midiAllowedOrigins") ?? [])
    private var mainFrameListening = false
    private var subframes: [WKFrameInfo] = []
    private var cancellables = Set<AnyCancellable>()

    init(midi: MIDIManager) {
        self.midi = midi

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.applicationNameForUserAgent = "Version/17.0 Mobile/15E148 Safari/604.1 PianoBrowser"
        if let url = Bundle.main.url(forResource: "WebMIDIPolyfill", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            configuration.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: BrowserModel.handlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if #available(iOS 16.4, *) { webView.isInspectable = true }

        if let data = UserDefaults.standard.data(forKey: "bookmarks"),
           let saved = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = saved
        }

        webView.publisher(for: \.canGoBack).receive(on: DispatchQueue.main).assign(to: &$canGoBack)
        webView.publisher(for: \.canGoForward).receive(on: DispatchQueue.main).assign(to: &$canGoForward)
        webView.publisher(for: \.isLoading).receive(on: DispatchQueue.main).assign(to: &$isLoading)
        webView.publisher(for: \.estimatedProgress).receive(on: DispatchQueue.main).assign(to: &$progress)
        webView.publisher(for: \.title).receive(on: DispatchQueue.main).map { $0 ?? "" }.assign(to: &$pageTitle)
        webView.publisher(for: \.url).receive(on: DispatchQueue.main).sink { [weak self] url in
            guard let self else { return }
            self.pageURL = url
            if !self.isEditingAddress { self.addressText = self.displayAddress }
        }.store(in: &cancellables)

        midi.onMessage = { [weak self] id, bytes in
            guard let self, self.mainFrameListening || !self.subframes.isEmpty else { return }
            let list = bytes.map { String($0) }.joined(separator: ",")
            self.deliver("__pianoBrowserMIDI.receive(\"\(id)\",[\(list)]);0")
        }
        midi.onDevicesChanged = { [weak self] in
            guard let self, self.mainFrameListening || !self.subframes.isEmpty else { return }
            guard let data = try? JSONSerialization.data(withJSONObject: self.devicePayload()),
                  let json = String(data: data, encoding: .utf8) else { return }
            self.deliver("__pianoBrowserMIDI.devices(\(json));0")
        }

        loadHome()
    }

    // MARK: Navigation

    var isOnStartPage: Bool { pageURL?.isFileURL ?? true }

    private var displayAddress: String {
        guard let url = pageURL, !url.isFileURL, url.scheme != "about" else { return "" }
        return url.absoluteString
    }

    func loadHome() {
        if let url = URL(string: homeURL), !homeURL.isEmpty {
            webView.load(URLRequest(url: url))
        } else {
            loadStartPage()
        }
    }

    func loadStartPage() {
        guard let url = Bundle.main.url(forResource: "start", withExtension: "html") else { return }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func load(input: String) {
        guard let url = BrowserModel.url(fromInput: input) else { return }
        webView.load(URLRequest(url: url))
    }

    func reloadOrStop() {
        if isLoading { webView.stopLoading() } else { webView.reload() }
    }

    /// Turns what was typed in the address bar into a URL: an address if it looks like one, otherwise a search.
    static func url(fromInput raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil {
            return URL(string: text)
        }
        let lower = text.lowercased()
        if !text.contains(" "), text.contains(".") || lower.hasPrefix("localhost") {
            // Local servers (localhost, 192.168.1.20:3000, my-mac.local) rarely have https.
            let host = lower.split(separator: "/").first.map(String.init) ?? lower
            let isLocal = host.range(of: #"^(localhost|[0-9.]+|[^:]+\.local)(:[0-9]+)?$"#, options: .regularExpression) != nil
            if let url = URL(string: (isLocal ? "http://" : "https://") + text) { return url }
        }
        var search = URLComponents(string: "https://duckduckgo.com/")
        search?.queryItems = [URLQueryItem(name: "q", value: text)]
        return search?.url
    }

    // MARK: Home page and bookmarks

    func setHomeToCurrentPage() {
        homeURL = isOnStartPage ? "" : (pageURL?.absoluteString ?? "")
        UserDefaults.standard.set(homeURL, forKey: "homeURL")
    }

    func resetHome() {
        homeURL = ""
        UserDefaults.standard.set(homeURL, forKey: "homeURL")
    }

    var currentBookmark: Bookmark? {
        guard let url = pageURL?.absoluteString else { return nil }
        return bookmarks.first { $0.url == url }
    }

    func toggleBookmark() {
        guard let url = pageURL, !url.isFileURL else { return }
        if let existing = currentBookmark {
            bookmarks.removeAll { $0.id == existing.id }
        } else {
            let title = pageTitle.isEmpty ? (url.host ?? url.absoluteString) : pageTitle
            bookmarks.append(Bookmark(title: title, url: url.absoluteString))
        }
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: "bookmarks")
        }
    }

    // MARK: MIDI bridge

    var hasMIDIPermissions: Bool { !allowedOrigins.isEmpty }

    func resetMIDIPermissions() {
        allowedOrigins.removeAll()
        UserDefaults.standard.removeObject(forKey: "midiAllowedOrigins")
        objectWillChange.send()
    }

    private func devicePayload() -> [String: Any] {
        ["inputs": midi.inputs.map(\.payload), "outputs": midi.outputs.map(\.payload)]
    }

    private func deliver(_ script: String) {
        if mainFrameListening { webView.evaluateJavaScript(script, completionHandler: nil) }
        for frame in subframes {
            webView.evaluateJavaScript(script, in: frame, in: .page, completionHandler: nil)
        }
    }

    private func originKey(_ frame: WKFrameInfo) -> String {
        let origin = frame.securityOrigin
        return "\(origin.protocol)://\(origin.host):\(origin.port)"
    }

    private func isAllowed(_ frame: WKFrameInfo) -> Bool {
        frame.securityOrigin.protocol == "file" || allowedOrigins.contains(originKey(frame))
    }

    /// Asks once per site before handing it the instruments.
    private func authorize(_ frame: WKFrameInfo, completion: @escaping (Bool) -> Void) {
        if isAllowed(frame) { return completion(true) }
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
        present(alert) { completion(false) }
    }

    private func present(_ alert: UIAlertController, orElse fallback: () -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController else { return fallback() }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        top.present(alert, animated: true)
    }
}

extension BrowserModel: WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
            return replyHandler(nil, "Bad message")
        }
        let frame = message.frameInfo
        switch type {
        case "request":
            authorize(frame) { [weak self] allowed in
                guard let self, allowed else { return replyHandler(nil, "MIDI access was denied.") }
                if frame.isMainFrame {
                    self.mainFrameListening = true
                } else if self.subframes.count < 16 {
                    self.subframes.append(frame)
                }
                self.midi.refresh()
                replyHandler(self.devicePayload(), nil)
            }
        case "send":
            if isAllowed(frame), let id = body["id"] as? String, let data = body["data"] as? [NSNumber] {
                midi.send(to: id, bytes: data.map { $0.uint8Value }, delayMs: (body["delay"] as? NSNumber)?.doubleValue ?? 0)
            }
            replyHandler(nil, nil)
        case "clear":
            if isAllowed(frame), let id = body["id"] as? String { midi.clear(id: id) }
            replyHandler(nil, nil)
        default:
            replyHandler(nil, "Unknown message")
        }
    }
}

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            return decisionHandler(.allow)
        }
        if ["http", "https", "file", "about", "blob", "data"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            // mailto:, tel:, App Store links and the like belong to other apps.
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new page has to ask for MIDI again before it receives anything.
        mainFrameListening = false
        subframes.removeAll()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // Cancelled loads and "frame load interrupted" (downloads, app links) aren't worth a page.
        if nsError.code == NSURLErrorCancelled || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102) { return }
        let message = nsError.localizedDescription
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let html = """
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <body style="font: 17px -apple-system; padding: 48px 24px; color-scheme: light dark">
        <h2>Can’t open this page</h2><p style="opacity: 0.7">\(message)</p>
        """
        webView.loadHTMLString(html, baseURL: nil)
        if !isEditingAddress, let failed = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            addressText = failed
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

extension BrowserModel: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Links that want a new window open in this one.
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, orElse: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text ?? "")
        })
        present(alert) { completionHandler(nil) }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // Microphone (tuners, recording) gets the normal prompt; the app has no camera access.
        decisionHandler(type == .microphone ? .prompt : .deny)
    }
}
