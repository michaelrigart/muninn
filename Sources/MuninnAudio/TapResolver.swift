import Foundation

/// The audio process objects a call tap covers, and the bundle IDs CoreAudio uses to restore a restarted helper.
struct ResolvedTap: Equatable {
    var objectIDs: [UInt32]
    var bundleIDs: [String]
}

enum TapResolver {
    /// Every audio process of the watched app, whether it is running input, output or neither, except Muninn itself.
    /// A call's audio often plays through a different helper than the one holding the microphone.
    static func resolve(
        entry: String,
        processes: [AudioProcessInfo],
        ownPID: pid_t,
        ignoredBundleIDs: Set<String>
    ) -> ResolvedTap {
        var objectIDs: [UInt32] = []
        var bundleIDs: [String] = []
        for process in processes where process.pid != ownPID {
            guard matches(process.bundleID, entry: entry) else { continue }
            guard !ignoredBundleIDs.contains(where: { matches(process.bundleID, entry: $0) }) else { continue }
            if !objectIDs.contains(process.objectID) { objectIDs.append(process.objectID) }
            if !bundleIDs.contains(process.bundleID) { bundleIDs.append(process.bundleID) }
        }
        return ResolvedTap(objectIDs: objectIDs, bundleIDs: bundleIDs)
    }
}
