import SwiftUI
import WebKit

/// Stops pages from loading known tracker and ad servers, using WebKit's
/// content blocker so blocked requests never leave the device.
final class TrackerBlocker: ObservableObject {
    @Published private(set) var ruleCount = 0
    @Published private(set) var exemptHosts: Set<String>
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "trackerBlocking")
            apply()
        }
    }

    private static let listID = "trackers"
    private static let remoteList = URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=nohtml&showintro=0&mimetype=plaintext")
    private static let cacheFile = Storage.folder.appendingPathComponent("trackers.txt")
    private let controller: WKUserContentController
    private var domains: [String] = []

    init(controller: WKUserContentController) {
        self.controller = controller
        isEnabled = UserDefaults.standard.object(forKey: "trackerBlocking") as? Bool ?? true
        exemptHosts = Set(UserDefaults.standard.stringArray(forKey: "trackerExemptHosts") ?? [])
        domains = TrackerBlocker.loadDomains()
        apply()
        refreshIfStale()
    }

    // MARK: Per-site switch

    private func key(for host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func isExempt(_ host: String?) -> Bool {
        guard let host else { return false }
        return exemptHosts.contains(key(for: host))
    }

    func toggleExempt(_ host: String) {
        let host = key(for: host)
        if !exemptHosts.insert(host).inserted { exemptHosts.remove(host) }
        UserDefaults.standard.set(Array(exemptHosts), forKey: "trackerExemptHosts")
        apply()
    }

    // MARK: Rules

    private static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let domain = line.trimmingCharacters(in: .whitespaces).lowercased()
            let valid = domain.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil
            return valid ? domain : nil
        }
    }

    private static func loadDomains() -> [String] {
        var text = ""
        if let url = Bundle.main.url(forResource: "Trackers", withExtension: "txt") {
            text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        text += "\n" + ((try? String(contentsOf: cacheFile, encoding: .utf8)) ?? "")
        return Array(Set(parse(text))).sorted().prefix(30_000).map { $0 }
    }

    static func rulesJSON(domains: [String], exempt: Set<String>) -> String {
        var rules = domains.map { domain -> String in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\\\.")
            return "{\"trigger\":{\"url-filter\":\"^[^:]+://+([^:/]+\\\\.)?\(escaped)[:/]\",\"load-type\":[\"third-party\"]},\"action\":{\"type\":\"block\"}}"
        }
        if !exempt.isEmpty {
            let list = exempt.sorted().map { "\"*\($0)\"" }.joined(separator: ",")
            rules.append("{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":[\(list)]},\"action\":{\"type\":\"ignore-previous-rules\"}}")
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    private func install(_ list: WKContentRuleList, count: Int) {
        guard isEnabled else { return }
        controller.removeAllContentRuleLists()
        controller.add(list)
        ruleCount = count
    }

    /// Installs the block list, reusing the compiled copy from last time when nothing changed.
    private func apply() {
        guard isEnabled, !domains.isEmpty else {
            controller.removeAllContentRuleLists()
            ruleCount = 0
            return
        }
        let domains = self.domains
        let exempt = exemptHosts
        let signature = "3|\(domains.count)|\(domains.first ?? "")|\(domains.last ?? "")|\(exempt.sorted().joined(separator: ","))"
        let store = WKContentRuleListStore.default()

        func compile() {
            DispatchQueue.global(qos: .userInitiated).async {
                let json = TrackerBlocker.rulesJSON(domains: domains, exempt: exempt)
                DispatchQueue.main.async {
                    store?.compileContentRuleList(forIdentifier: TrackerBlocker.listID, encodedContentRuleList: json) { [weak self] list, _ in
                        guard let self, let list else { return }
                        UserDefaults.standard.set(signature, forKey: "trackerListSignature")
                        self.install(list, count: domains.count)
                    }
                }
            }
        }

        if UserDefaults.standard.string(forKey: "trackerListSignature") == signature {
            store?.lookUpContentRuleList(forIdentifier: TrackerBlocker.listID) { [weak self] list, _ in
                if let list { self?.install(list, count: domains.count) } else { compile() }
            }
        } else {
            compile()
        }
    }

    /// Downloads the public ad/tracker server list about once a week.
    private func refreshIfStale() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: TrackerBlocker.cacheFile.path))?[.modificationDate] as? Date
        if let modified, Date().timeIntervalSince(modified) < 7 * 86_400 { return }
        guard let url = TrackerBlocker.remoteList else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else { return }
            let found = TrackerBlocker.parse(text)
            guard found.count > 500 else { return } // not the list we expected
            try? found.joined(separator: "\n").write(to: TrackerBlocker.cacheFile, atomically: true, encoding: .utf8)
            let all = TrackerBlocker.loadDomains()
            DispatchQueue.main.async {
                self?.domains = all
                self?.apply()
            }
        }.resume()
    }
}
