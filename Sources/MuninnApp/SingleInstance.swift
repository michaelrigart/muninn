import AppKit
import Darwin
import MuninnCore
import os

private let logger = Logger(subsystem: "be.netronix.muninn", category: "instance")

/// Only one Muninn may run on a data folder: two would both recover the meetings and fight over the audio devices.
/// The bundled app and a `swift run` build share the one lock in the data folder, so they exclude each other too.
enum SingleInstance {
    private static var lock: FileLock?

    /// Call before anything touches the store. Returns when this process holds the lock, which it keeps until it exits.
    /// A holder that is still quitting gets up to ten seconds to let go. A lock that can't be taken for any other reason
    /// (a filesystem without locking, an unwritable folder) is logged, and Muninn starts without it.
    static func claim() {
        let paths = MuninnPaths(home: FileManager.default.homeDirectoryForCurrentUser, environment: ProcessInfo.processInfo.environment)
        do {
            try FileManager.default.createDirectory(at: paths.data, withIntermediateDirectories: true)
        } catch {
            logger.error("Creating the data folder for the instance lock failed: \(String(describing: error), privacy: .public)")
            return
        }
        let url = paths.data.appendingPathComponent("muninn.lock")
        var held: FileLock?
        var failure: Error?
        let acquired = InstanceArbiter.acquire(
            tryLock: {
                do {
                    held = try FileLock.tryAcquire(url)
                } catch {
                    failure = error
                    return true
                }
                return held != nil
            },
            sleep: { Thread.sleep(forTimeInterval: $0) }
        )
        if let failure {
            logger.error("Taking the instance lock failed; starting without it: \(String(describing: failure), privacy: .public)")
            return
        }
        guard acquired else { handOver(lockPath: url.path) }
        lock = held
    }

    private static func handOver(lockPath: String) -> Never {
        if let bundleID = Bundle.main.bundleIdentifier, Bundle.main.bundleURL.pathExtension == "app" {
            if let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0.processIdentifier != getpid() }) {
                logger.notice("Muninn is already running (\(lockPath, privacy: .public) is held); activating it and quitting this copy")
                other.activate()
            } else {
                logger.notice("\(lockPath, privacy: .public) is held by a process that is not a bundled Muninn; telling the user and quitting")
                let alert = NSAlert()
                alert.messageText = "Muninn can't start"
                alert.informativeText = "Another Muninn process is using its data folder (for example a development build). Quit it and open Muninn again."
                alert.addButton(withTitle: "OK")
                alert.window.level = .floating
                NSApplication.shared.activate()
                alert.runModal()
            }
            exit(0)
        }
        let message = "Muninn is already running on this data folder (\(lockPath) is held). Quit it first.\n"
        FileHandle.standardError.write(Data(message.utf8))
        logger.notice("Another Muninn holds \(lockPath, privacy: .public); exiting")
        exit(1)
    }
}
