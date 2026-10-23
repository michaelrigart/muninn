import Foundation
import MuninnCore
import Security

public enum KeychainError: Error, Equatable {
    case status(OSStatus)
    case invalidData
}

protocol SecretsReading: Sendable {
    func get(_ key: String) throws -> String?
}

// Generic-password items in the file-based keychain: the data-protection keychain needs entitlements an ad-hoc signed app lacks.
public struct KeychainSecrets: SecretsReading {
    private let service: String

    public init(service: String = "be.netronix.muninn") {
        self.service = service
    }

    public func get(_ key: String) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    public func set(_ v: String, for key: String) throws {
        let data = Data(v.utf8)
        let updated = SecItemUpdate(baseQuery(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = baseQuery(key)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError.status(added) }
        default:
            throw KeychainError.status(updated)
        }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

public struct KeychainTokenStore: TokenStore {
    private let secrets: KeychainSecrets

    public init(secrets: KeychainSecrets) {
        self.secrets = secrets
    }

    public func load(account: String) throws -> TokenSet? {
        guard let json = try secrets.get(key(account)) else { return nil }
        return try Self.decoder.decode(TokenSet.self, from: Data(json.utf8))
    }

    public func save(_ t: TokenSet, account: String) throws {
        let data = try Self.encoder.encode(t)
        try secrets.set(String(decoding: data, as: UTF8.self), for: key(account))
    }

    public func delete(account: String) throws {
        try secrets.delete(key(account))
    }

    private func key(_ account: String) -> String {
        "graph.\(account)"
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.withFractionalSeconds.string(from: date))
        }
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601DateFormatter.withFractionalSeconds.date(from: string)
                ?? ISO8601DateFormatter.plain.date(from: string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO 8601 date: \(string)"))
            }
            return date
        }
        return decoder
    }
}

private extension ISO8601DateFormatter {
    static var withFractionalSeconds: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static var plain: ISO8601DateFormatter {
        ISO8601DateFormatter()
    }
}
