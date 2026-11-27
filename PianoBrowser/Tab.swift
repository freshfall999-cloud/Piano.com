import Combine
import SwiftUI
import WebKit

/// One browser tab: a web view plus everything the toolbar shows about it.
final class Tab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let isPrivate: Bool
    let webView: WKWebView

    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var showsStartPage: Bool
    @Published private(set) var snapshot: UIImage?
    @Published private(set) var desktopSite = false
    /// Set while a "blocked" or "can't open" page stands in for this address.
    @Published private(set) var internalPageFor: URL?

    private weak var browser: Browser?
    private var pendingURL: URL?
    private var downloadDestination: URL?
    private var midiMainFrame = false
    private var midiSubframes: [WKFrameInfo] = []
    private var cancellables = Set<AnyCancellable>()

    init(browser: Browser, configuration: WKWebViewConfiguration, isPrivate: Bool,
         showsStartPage: Bool = true, restoring restoredURL: URL? = nil, title restoredTitle: String = "") {
        self.browser = browser
        self.isPrivate = isPrivate
        self.pendingURL = restoredURL
        self.url = restoredURL
        self.title = restoredTitle
        self.showsStartPage = showsStartPage && restoredURL == nil
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isFindInteractionEnabled = true
        if #available(iOS 16.4, *) { webView.isInspectable = true }

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pulledToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        webView.publisher(for: \.canGoBack).receive(on: DispatchQueue.main).assign(to: &$canGoBack)
        webView.publisher(for: \.canGoForward).receive(on: DispatchQueue.main).assign(to: &$canGoForward)
        webView.publisher(for: \.isLoading).receive(on: DispatchQueue.main).assign(to: &$isLoading)
        webView.publisher(for: \.estimatedProgress).receive(on: DispatchQueue.main).assign(to: &$progress)
        webView.publisher(for: \.title).receive(on: DispatchQueue.main).sink { [weak self] title in
            guard let self, self.pendingURL == nil else { return }
            self.title = title ?? ""
        }.store(in: &cancellables)
        webView.publisher(for: \.url).receive(on: DispatchQueue.main).sink { [weak self] url in
            guard let self, self.pendingURL == nil else { return }
            self.url = url
        }.store(in: &cancellables)
    }

    // MARK: What the address bar shows

    /// The address this tab is about, even while an error or blocked page is on screen.
    var displayURL: URL? {
        if let internalPageFor { return internalPageFor }
        guard let url, url.scheme != "about" else { return nil }
        return url
    }

    var isTestKeyboard: Bool { displayURL?.isFileURL ?? false }

    var displayHost: String {
        if isTestKeyboard { return "Test Keyboard" }
        guard let host = displayURL?.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var displayTitle: String {
        if showsStartPage { return isPrivate ? "Private Browsing" : "Start Page" }
        if !title.isEmpty { return title }
        return displayHost.isEmpty ? "Untitled" : displayHost
    }

    var isSecure: Bool { internalPageFor == nil && url?.scheme == "https" }

    // MARK: Navigation

    func load(_ url: URL) {
        pendingURL = nil
        internalPageFor = nil
        showsStartPage = false
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func loadTestKeyboard() {
        if let url = Bundle.main.url(forResource: "start", withExtension: "html") { load(url) }
    }

    /// Loads a restored tab the first time it is shown.
    func activate() {
        if let url = pendingURL { load(url) }
    }

    func reload() {
        if let url = internalPageFor { load(url) } else { webView.reload() }
    }

    func toggleDesktopSite() {
        desktopSite.toggle()
        reload()
    }

    func findOnPage() {
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func takeSnapshot() {
        guard !showsStartPage, pendingURL == nil, webView.window != nil else { return }
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            if let image { self?.snapshot = image }
        }
    }

    @objc private func pulledToRefresh(_ control: UIRefreshControl) {
        reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { control.endRefreshing() }
    }

    private func showInternalPage(for url: URL, title: String, symbol: String, heading: String, detail: String) {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        let html = """
        <!doctype html><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <body style="font: 17px -apple-system; margin: 0; padding: 22vh 32px 0; text-align: center; color-scheme: light dark">
        <div style="font-size: 54px">\(symbol)</div>
        <h2 style="margin: 12px 0 8px">\(escape(heading))</h2>
        <p style="opacity: 0.65; margin: 0 auto; max-width: 420px; line-height: 1.4">\(escape(detail))</p>
        """
        internalPageFor = url
        showsStartPage = false
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: MIDI

    var isListeningForMIDI: Bool { midiMainFrame || !midiSubframes.isEmpty }

    func startListeningForMIDI(_ frame: WKFrameInfo) {
        if frame.isMainFrame {
            midiMainFrame = true
        } else if midiSubframes.count < 16 {
            midiSubframes.append(frame)
        }
    }

    func deliverMIDI(_ script: String) {
        if midiMainFrame { webView.evaluateJavaScript(script, completionHandler: nil) }
        for frame in midiSubframes {
            webView.evaluateJavaScript(script, in: frame, in: .page, completionHandler: nil)
        }
    }
}

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = desktopSite ? .desktop : .recommended
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            return decisionHandler(.allow, preferences)
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true

        guard ["http", "https", "file", "about", "blob", "data"].contains(scheme) else {
            // mailto:, tel:, App Store links and the like belong to other apps.
            if isMainFrame { UIApplication.shared.open(url) }
            return decisionHandler(.cancel, preferences)
        }
        if navigationAction.shouldPerformDownload {
            return decisionHandler(.download, preferences)
        }
        guard scheme == "http" || scheme == "https", let browser, browser.filterEnabled, let host = url.host else {
            return decisionHandler(.allow, preferences)
        }
        if isMainFrame, navigationAction.request.httpMethod ?? "GET" == "GET", let safe = SiteFilter.safeSearchURL(for: url) {
            decisionHandler(.cancel, preferences)
            webView.load(URLRequest(url: safe))
            return
        }
        Task { @MainActor in
            if await browser.filter.isBlocked(host: host) {
                decisionHandler(.cancel, preferences)
                if isMainFrame {
                    self.showInternalPage(for: url, title: "Blocked", symbol: "🛡️", heading: "This website is blocked",
                                          detail: "\(host) is listed as unsafe or inappropriate, so Piano Browser didn’t open it.")
                }
            } else {
                decisionHandler(.allow, preferences)
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let download = navigationResponse.isForMainFrame && (!navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment"))
        decisionHandler(download ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new page has to ask for MIDI again before it receives anything.
        midiMainFrame = false
        midiSubframes.removeAll()
        if webView.url?.scheme != "about" { internalPageFor = nil }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        browser?.saveTabs()
        guard !isPrivate, internalPageFor == nil, let url = webView.url,
              url.scheme == "http" || url.scheme == "https" else { return }
        browser?.recordVisit(title: webView.title ?? "", url: url)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // Cancelled loads and "frame load interrupted" (downloads, blocked pages) need no error page.
        if nsError.code == NSURLErrorCancelled || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102) { return }
        guard let failed = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url ?? url else { return }
        showInternalPage(for: failed, title: "Can’t Open Page", symbol: "🧭", heading: "Can’t open this page",
                         detail: nsError.localizedDescription)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
              challenge.previousFailureCount < 3 else {
            return completionHandler(.performDefaultHandling, nil)
        }
        let alert = UIAlertController(title: "Sign in to \(challenge.protectionSpace.host)", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "User name"; $0.autocapitalizationType = .none }
        alert.addTextField { $0.placeholder = "Password"; $0.isSecureTextEntry = true }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(.cancelAuthenticationChallenge, nil) })
        alert.addAction(UIAlertAction(title: "Sign In", style: .default) { [weak alert] _ in
            let user = alert?.textFields?.first?.text ?? ""
            let password = alert?.textFields?.last?.text ?? ""
            completionHandler(.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
        })
        Presenter.present(alert) { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

extension Tab: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = suggestedFilename.isEmpty ? "Download" : suggestedFilename
        var destination = folder.appendingPathComponent(name)
        var copy = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            destination = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(copy)" : "\(base) \(copy).\(ext)")
            copy += 1
        }
        downloadDestination = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        browser?.finishedDownload(downloadDestination)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let alert = UIAlertController(title: "Download Failed", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        Presenter.present(alert)
    }
}

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Links and scripts that want a new window get a new tab.
        browser?.openTab(configuration: configuration, opener: self).webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        browser?.close(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        Presenter.present(alert, orElse: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        Presenter.present(alert) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text ?? "")
        })
        Presenter.present(alert) { completionHandler(nil) }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // Microphone (tuners, recording) gets the normal prompt; the app has no camera access.
        decisionHandler(type == .microphone ? .prompt : .deny)
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let link = elementInfo.linkURL else { return completionHandler(nil) }
        let isPrivate = self.isPrivate
        completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: link.absoluteString, children: [
                UIAction(title: "Open", image: UIImage(systemName: "safari")) { _ in self?.load(link) },
                UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { _ in
                    self?.browser?.newTab(url: link, isPrivate: isPrivate)
                },
                UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.url = link
                },
                UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                    Presenter.present(UIActivityViewController(activityItems: [link], applicationActivities: nil))
                }
            ])
        })
    }
}
