import Foundation
import MuninnCore

/// Samples `SystemLoadReader` into a list, warning once per failing read. `sample()` is called once a second.
final class LoadSampler: @unchecked Sendable {
    private let reader = SystemLoadReader()
    private let lock = NSLock()
    private var taken: [LoadSnapshot] = []
    private var warned = Set<String>()

    init() {
        _ = reader.snapshot()
    }

    var snapshots: [LoadSnapshot] { lock.withLock { taken } }

    @discardableResult
    func sample() -> LoadSnapshot {
        let snapshot = reader.snapshot()
        let fresh = lock.withLock { () -> Set<String> in
            taken.append(snapshot)
            let fresh = Set(snapshot.failedReads).subtracting(warned)
            warned.formUnion(fresh)
            return fresh
        }
        if !fresh.isEmpty {
            Spike.log("warning: these load reads failed and are recorded as zero or normal: \(fresh.sorted().joined(separator: ", "))")
        }
        return snapshot
    }

    /// Samples every second until cancelled.
    func runInBackground() -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                sample()
            }
        }
    }

    func write(to url: URL) throws {
        try Spike.write(LoadReport.csv(snapshots), to: url)
    }

    func printSummary() {
        let snapshots = snapshots
        guard !snapshots.isEmpty else { return }
        let swapOuts = (snapshots.last?.swapOuts ?? 0) &- (snapshots.first?.swapOuts ?? 0)
        let cpu = snapshots.map(\.cpuBusyPercent).reduce(0, +) / Double(snapshots.count)
        print("Load samples:   \(snapshots.count)")
        print("Peak pressure:  \(snapshots.map(\.pressureLevel).max() ?? 1) (1 normal, 2 warning, 4 critical)")
        print(String(format: "Peak swap:      %.1f MB, swap-outs during the run: %llu", Double(snapshots.map(\.swapUsedBytes).max() ?? 0) / 1_048_576, swapOuts))
        print(String(format: "Mean CPU busy:  %.1f %%", cpu))
    }
}
