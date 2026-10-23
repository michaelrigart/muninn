import Darwin
import Foundation

public struct FileLockError: Error, Equatable {
    public let path: String
    public let code: Int32
}

extension FileLockError: LocalizedError {
    public var errorDescription: String? {
        "Locking \(path) failed: \(String(cString: strerror(code))) (errno \(code))"
    }
}

/// An exclusive advisory lock on a file, held until the object is released. Two holders of the same path exclude each other
/// even inside one process, because the lock belongs to the open file, not to the process.
public final class FileLock {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Takes the lock, creating the file if needed. Returns nil when someone else holds it (`flock` says EWOULDBLOCK);
    /// throws when the file can't be opened or the filesystem can't lock, which is no proof that anyone holds it.
    public static func tryAcquire(_ url: URL) throws -> FileLock? {
        try tryAcquire(url, lockCall: { flock($0, $1) })
    }

    static func tryAcquire(_ url: URL, lockCall: (Int32, Int32) -> Int32) throws -> FileLock? {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path, NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))])
        }
        guard lockCall(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw FileLockError(path: url.path, code: code)
        }
        return FileLock(descriptor: descriptor)
    }

    public func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}
