import Foundation

/// Blocks malware and adult websites by asking Cloudflare's family DNS filter
/// (1.1.1.3) about each site before it loads, and forces safe search on
/// search engines.
final class SiteFilter {
    private struct Reply: Decodable {
        struct Answer: Decodable {
            let type: Int
            let data: String
        }
        let Answer: [Answer]?
    }

    private var cache: [String: (blocked: Bool, checked: Date)] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        return URLSession(configuration: configuration)
    }()

    /// True if the filter lists this host. If the filter can't be reached the site is allowed.
    @MainActor
    func isBlocked(host rawHost: String) async -> Bool {
        let host = rawHost.lowercased()
        if SiteFilter.isLocal(host) { return false }
        if let hit = cache[host], Date().timeIntervalSince(hit.checked) < 3600 { return hit.blocked }

        var components = URLComponents(string: "https://family.cloudflare-dns.com/dns-query")
        components?.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A")]
        guard let url = components?.url else { return false }
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "accept")

        guard let (data, _) = try? await session.data(for: request),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return false }
        // The filter answers 0.0.0.0 for anything it blocks.
        let blocked = reply.Answer?.contains { $0.type == 1 && $0.data == "0.0.0.0" } ?? false
        cache[host] = (blocked, Date())
        return blocked
    }

    /// Devices on the local network are never looked up.
    static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".local") || !host.contains(".") || host.contains(":")
            || host.range(of: #"^[0-9.]+$"#, options: .regularExpression) != nil
    }

    /// For a search-results URL without safe search switched on, the same URL with it on.
    static func safeSearchURL(for url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let name: String, value: String
        if host.range(of: #"(^|\.)google\.[a-z.]+$"#, options: .regularExpression) != nil,
           ["/search", "/images", "/imghp"].contains(url.path) {
            (name, value) = ("safe", "active")
        } else if host.hasSuffix("bing.com"), url.path.hasSuffix("/search") {
            (name, value) = ("adlt", "strict")
        } else if host.hasSuffix("duckduckgo.com") {
            (name, value) = ("kp", "1")
        } else if host.hasSuffix("search.yahoo.com") {
            (name, value) = ("vm", "r")
        } else {
            return nil
        }
        var items = components.queryItems ?? []
        guard items.contains(where: { $0.name == "q" || $0.name == "p" }) else { return nil }
        if items.contains(where: { $0.name == name && $0.value == value }) { return nil }
        items.removeAll { $0.name == name }
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
        return components.url
    }
}
