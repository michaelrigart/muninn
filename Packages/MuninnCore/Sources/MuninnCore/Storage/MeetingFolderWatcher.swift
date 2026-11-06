import Darwin
import Dispatch
import Foundation
import os

private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "storage")

/// Watches one directory, not its subdirectories, and calls `onChange` on `queue` once per burst of entries added, removed
/// or renamed in it. Stops by itself when the directory is deleted or renamed.
public final class MeetingFolderWatcher {
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private let events = DispatchQueue(label: "\(AppIdentity.bundleIdentifier).meeting-folder-watcher")
    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    public init(directory: URL, queue: DispatchQueue, debounce: TimeInterval = 0.5, onChange: @escaping () -> Void) {
        self.queue = queue
        self.debounce = debounce
        self.onChange = onChange
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            logger.error("Watching \(directory.path, privacy: .public) failed: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: events)
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            self?.handle(source.data)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    deinit {
        stop()
    }

    public func stop() {
        lock.lock()
        let source = self.source
        self.source = nil
        pending?.cancel()
        pending = nil
        lock.unlock()
        source?.cancel()
    }

    private func handle(_ event: DispatchSource.FileSystemEvent) {
        if !event.isDisjoint(with: [.delete, .rename]) {
            logger.notice("The meetings folder was deleted or renamed; no longer watching it")
            stop()
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard source != nil else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.fire()
        }
        pending = item
        events.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func fire() {
        lock.lock()
        let watching = source != nil
        pending = nil
        lock.unlock()
        if watching {
            queue.async(execute: onChange)
        }
    }
}
