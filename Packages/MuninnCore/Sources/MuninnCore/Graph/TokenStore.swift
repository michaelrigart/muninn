import Foundation

public struct TokenSet: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public protocol TokenStore: Sendable {
    func load(account: String) throws -> TokenSet?
    func save(_ t: TokenSet, account: String) throws
    func delete(account: String) throws
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: TokenSet] = [:]

    public init() {}

    public func load(account: String) throws -> TokenSet? {
        lock.lock()
        defer { lock.unlock() }
        return tokens[account]
    }

    public func save(_ t: TokenSet, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        tokens[account] = t
    }

    public func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        tokens[account] = nil
    }
}

/// Serialises every change to an account's stored tokens across refresh, sign-in and sign-out.
/// The lock is process-wide, so it holds even when several sessions or stores talk to one account.
public enum TokenAccess {
    private static let registry = NSLock()
    nonisolated(unsafe) private static var locks: [String: NSLock] = [:]

    static func withLock<T>(account: String, _ body: () throws -> T) rethrows -> T {
        registry.lock()
        let lock: NSLock
        if let existing = locks[account] {
            lock = existing
        } else {
            lock = NSLock()
            locks[account] = lock
        }
        registry.unlock()
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public static func signIn(_ tokens: TokenSet, account: String, store: TokenStore) throws {
        try withLock(account: account) {
            try store.save(tokens, account: account)
        }
    }

    public static func signOut(account: String, store: TokenStore) throws {
        try withLock(account: account) {
            try store.delete(account: account)
        }
    }
}
