import Foundation

public enum InstanceArbiter {
    public static let waitLimit: TimeInterval = 10
    public static let pollInterval: TimeInterval = 0.25

    /// Takes the data-folder lock, waiting for a holder that is on its way out. Returns false when the lock is still held
    /// after `limit`, which means another Muninn is running and this one should hand over.
    public static func acquire(
        limit: TimeInterval = waitLimit,
        interval: TimeInterval = pollInterval,
        tryLock: () -> Bool,
        sleep: (TimeInterval) -> Void
    ) -> Bool {
        var waited: TimeInterval = 0
        while !tryLock() {
            guard waited < limit else { return false }
            sleep(interval)
            waited += interval
        }
        return true
    }
}
