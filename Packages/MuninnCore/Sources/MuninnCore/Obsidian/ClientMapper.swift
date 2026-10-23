import Foundation

public enum ClientMapper {
    public static func client(for attendees: [Attendee], domains: [String: String], selfAddresses: [String]) -> String? {
        let selves = Set(selfAddresses.map { $0.lowercased() })
        let keys = domains.map { (key: $0.key.lowercased(), client: $0.value) }
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        for (index, attendee) in attendees.enumerated() {
            let email = attendee.email.lowercased()
            guard !selves.contains(email), let at = email.lastIndex(of: "@") else { continue }
            let domain = String(email[email.index(after: at)...])
            let match = keys
                .filter { domain == $0.key || domain.hasSuffix("." + $0.key) }
                .max { $0.key.count < $1.key.count }
            guard let client = match?.client else { continue }
            counts[client, default: 0] += 1
            if firstSeen[client] == nil { firstSeen[client] = index }
        }
        return counts.keys.min { lhs, rhs in
            if counts[lhs]! != counts[rhs]! { return counts[lhs]! > counts[rhs]! }
            return firstSeen[lhs]! < firstSeen[rhs]!
        }
    }
}
