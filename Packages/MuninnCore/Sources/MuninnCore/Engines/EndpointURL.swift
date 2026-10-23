import Foundation

public enum EndpointURL {
    public static func parseBase(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    public static func make(base: URL, path: String) -> URL {
        var parts = base.pathComponents.filter { $0 != "/" }
        var extra = path.split(separator: "/").map(String.init)
        if let last = parts.last, last == extra.first {
            extra.removeFirst()
        }
        parts += extra
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base.appendingPathComponent(path) }
        components.path = "/" + parts.joined(separator: "/")
        return components.url ?? base.appendingPathComponent(path)
    }
}
