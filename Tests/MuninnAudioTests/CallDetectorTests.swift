import Foundation
import Testing
@testable import MuninnAudio

private func proc(_ bundle: String, pid: pid_t = 100, input: Bool = true, output: Bool = false) -> AudioProcessInfo {
    AudioProcessInfo(pid: pid, bundleID: bundle, objectID: UInt32(pid), isRunningInput: input, isRunningOutput: output)
}

private final class ScriptedListing: AudioProcessListing, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [[AudioProcessInfo]]
    private var _calls = 0

    init(_ script: [[AudioProcessInfo]]) { self.script = script }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func processes() throws -> [AudioProcessInfo] {
        lock.lock()
        defer { lock.unlock() }
        _calls += 1
        return script.count > 1 ? script.removeFirst() : (script.first ?? [])
    }
}

@Suite struct CallDiffTests {
    let watch = ["us.zoom.xos", "com.google.Chrome"]

    @Test func startEventForWatchedApp() {
        let result = CallDiff.events(previous: [], current: [proc("us.zoom.xos", pid: 42)], watchList: watch)
        #expect(result.events == [.started(bundleID: "us.zoom.xos", pid: 42)])
        #expect(result.inputBundles == ["us.zoom.xos"])
    }

    @Test func helperBundleMatchesPrefix() {
        let result = CallDiff.events(previous: [], current: [proc("com.google.Chrome.helper", pid: 7)], watchList: watch)
        #expect(result.events == [.started(bundleID: "com.google.Chrome", pid: 7)])
        #expect(result.inputBundles == ["com.google.Chrome"])
    }

    @Test func similarPrefixWithoutDotDoesNotMatch() {
        let result = CallDiff.events(previous: [], current: [proc("com.google.ChromeX")], watchList: watch)
        #expect(result.events.isEmpty)
        #expect(result.inputBundles.isEmpty)
    }

    @Test func unwatchedIgnored() {
        let result = CallDiff.events(previous: [], current: [proc("com.apple.Safari")], watchList: watch)
        #expect(result.events.isEmpty)
        #expect(result.inputBundles.isEmpty)
    }

    @Test func outputOnlyIgnored() {
        let result = CallDiff.events(previous: [], current: [proc("us.zoom.xos", input: false, output: true)], watchList: watch)
        #expect(result.events.isEmpty)
    }

    @Test func endEventWhenInputStops() {
        let result = CallDiff.events(previous: ["us.zoom.xos"], current: [proc("us.zoom.xos", input: false)], watchList: watch)
        #expect(result.events == [.ended(bundleID: "us.zoom.xos")])
        #expect(result.inputBundles.isEmpty)
    }

    @Test func endEventWhenProcessDisappears() {
        let result = CallDiff.events(previous: ["us.zoom.xos"], current: [], watchList: watch)
        #expect(result.events == [.ended(bundleID: "us.zoom.xos")])
    }

    @Test func noEventWhileStillRunning() {
        let result = CallDiff.events(previous: ["us.zoom.xos"], current: [proc("us.zoom.xos")], watchList: watch)
        #expect(result.events.isEmpty)
        #expect(result.inputBundles == ["us.zoom.xos"])
    }

    @Test func emptyEntryMatchesNothing() {
        let result = CallDiff.events(previous: [], current: [proc("us.zoom.xos"), proc("")], watchList: ["", "  "])
        #expect(result.events.isEmpty)
        #expect(result.inputBundles.isEmpty)
    }

    @Test func entryIsTrimmedAndCaseInsensitive() {
        let result = CallDiff.events(
            previous: [],
            current: [proc("com.microsoft.teams2", pid: 3)],
            watchList: [" COM.MICROSOFT.TEAMS2 "]
        )
        #expect(result.events == [.started(bundleID: "COM.MICROSOFT.TEAMS2", pid: 3)])
    }

    @Test func ownProcessIgnored() {
        let result = CallDiff.events(
            previous: [],
            current: [proc("be.netronix.muninn"), proc("be.netronix.muninn.helper")],
            watchList: ["be.netronix.muninn", "be.netronix"]
        )
        #expect(result.events.isEmpty)
        #expect(result.inputBundles.isEmpty)
    }

    @Test func firstMatchingProcessSuppliesPid() {
        let result = CallDiff.events(
            previous: [],
            current: [proc("com.google.Chrome.helper", pid: 5), proc("com.google.Chrome", pid: 9)],
            watchList: watch
        )
        #expect(result.events == [.started(bundleID: "com.google.Chrome", pid: 5)])
    }
}

@Suite struct CallDetectorTests {
    @Test(.timeLimit(.minutes(1))) func emitsStartedThenEnded() async throws {
        let listing = ScriptedListing([[proc("us.zoom.xos", pid: 42)], []])
        let detector = CallDetector(listing: listing, watchList: { ["us.zoom.xos"] }, interval: 0.05)
        var iterator = detector.events.makeAsyncIterator()
        detector.start()
        let first = await iterator.next()
        let second = await iterator.next()
        detector.stop()
        #expect(first == .started(bundleID: "us.zoom.xos", pid: 42))
        #expect(second == .ended(bundleID: "us.zoom.xos"))
        #expect(await iterator.next() == nil)
    }

    @Test(.timeLimit(.minutes(1))) func startIsIdempotent() async throws {
        let listing = ScriptedListing([[]])
        let detector = CallDetector(listing: listing, watchList: { [] }, interval: 0.1)
        detector.start()
        detector.start()
        detector.start()
        try await Task.sleep(for: .milliseconds(550))
        detector.stop()
        let calls = listing.calls
        #expect((4...8).contains(calls), "expected a single timer (~6 polls), got \(calls)")
    }

    @Test(.timeLimit(.minutes(1))) func startAfterStopIsNoOp() async throws {
        let listing = ScriptedListing([[]])
        let detector = CallDetector(listing: listing, watchList: { [] }, interval: 0.05)
        detector.start()
        detector.stop()
        try await Task.sleep(for: .milliseconds(100))
        let before = listing.calls
        detector.start()
        try await Task.sleep(for: .milliseconds(250))
        #expect(listing.calls == before)
        var iterator = detector.events.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test(.timeLimit(.minutes(1))) func failingListingSkipsTickAndRecovers() async throws {
        struct Boom: Error {}
        final class Flaky: AudioProcessListing, @unchecked Sendable {
            let lock = NSLock()
            var n = 0
            func processes() throws -> [AudioProcessInfo] {
                lock.lock()
                defer { lock.unlock() }
                n += 1
                if n <= 2 { throw Boom() }
                return [proc("us.zoom.xos", pid: 9)]
            }
        }
        let detector = CallDetector(listing: Flaky(), watchList: { ["us.zoom.xos"] }, interval: 0.05)
        var iterator = detector.events.makeAsyncIterator()
        detector.start()
        let event = await iterator.next()
        detector.stop()
        #expect(event == .started(bundleID: "us.zoom.xos", pid: 9))
    }
}

@Suite struct TapResolverTests {
    private func resolve(_ entry: String, _ processes: [AudioProcessInfo], ownPID: pid_t = 999) -> ResolvedTap {
        TapResolver.resolve(entry: entry, processes: processes, ownPID: ownPID, ignoredBundleIDs: ["be.netronix.muninn"])
    }

    @Test func includesInputOnlyAndOutputOnlyHelpersOfTheApp() {
        let result = resolve("com.microsoft.teams2", [
            proc("com.microsoft.teams2", pid: 10, input: true, output: false),
            proc("com.microsoft.teams2.helper", pid: 11, input: false, output: true),
            proc("com.microsoft.teams2.helper.renderer", pid: 12, input: false, output: false),
        ])
        #expect(result.objectIDs == [10, 11, 12])
        #expect(result.bundleIDs == ["com.microsoft.teams2", "com.microsoft.teams2.helper", "com.microsoft.teams2.helper.renderer"])
    }

    @Test func leavesOtherAppsOut() {
        let result = resolve("com.microsoft.teams2", [
            proc("com.microsoft.teams2", pid: 10),
            proc("com.apple.Safari", pid: 20, input: false, output: true),
            proc("com.microsoft.teams2x", pid: 21, input: false, output: true),
            proc("com.spotify.client", pid: 22, input: false, output: true),
        ])
        #expect(result.objectIDs == [10])
        #expect(result.bundleIDs == ["com.microsoft.teams2"])
    }

    @Test func leavesMuninnOut() {
        let result = resolve("be.netronix", [
            proc("be.netronix.muninn", pid: 30, input: true),
            proc("be.netronix.other", pid: 31, input: true),
        ])
        #expect(result.objectIDs == [31])

        let byPID = resolve("com.google.Chrome", [
            proc("com.google.Chrome", pid: 999, input: true),
            proc("com.google.Chrome.helper", pid: 40, input: false, output: true),
        ])
        #expect(byPID.objectIDs == [40])
    }

    @Test func matchesCaseInsensitivelyAndKeepsEachObjectOnce() {
        let result = resolve("COM.Google.chrome", [
            proc("com.google.Chrome", pid: 50),
            proc("com.google.Chrome", pid: 50),
            proc("com.google.Chrome.helper", pid: 51, input: false),
        ])
        #expect(result.objectIDs == [50, 51])
        #expect(result.bundleIDs == ["com.google.Chrome", "com.google.Chrome.helper"])
    }

    @Test func emptyEntryOrNoMatchResolvesNothing() {
        #expect(resolve("", [proc("com.google.Chrome")]) == ResolvedTap(objectIDs: [], bundleIDs: []))
        #expect(resolve("us.zoom.xos", [proc("com.google.Chrome")]).objectIDs.isEmpty)
    }
}
