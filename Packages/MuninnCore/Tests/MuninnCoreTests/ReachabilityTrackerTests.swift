import Foundation
import Testing
@testable import MuninnCore

struct ReachabilityTrackerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entries(
        _ tracker: inout ReachabilityTracker,
        thisMac: Bool? = true,
        networkMac: Bool? = nil,
        keyReadable: Bool = true,
        api: EndpointAPI = .ollama
    ) -> [ActivityEntry] {
        tracker.entries(thisMac: thisMac, networkMac: networkMac, keyReadable: keyReadable, api: api, time: now)
    }

    @Test func firstDownIsRecordedFirstUpIsNot() {
        var tracker = ReachabilityTracker()
        #expect(entries(&tracker, thisMac: true).isEmpty)

        var other = ReachabilityTracker()
        let down = entries(&other, thisMac: false)
        #expect(down.count == 1)
        #expect(down.first?.level == .warning)
        #expect(down.first?.area == .engines)
        #expect(down.first?.time == now)
        #expect(down.first?.message == "Ollama isn't running on This Mac")
    }

    @Test func onlyChangesAreRecorded() {
        var tracker = ReachabilityTracker()
        let steps = [false, false, true, true, false]
        let recorded = steps.flatMap { entries(&tracker, thisMac: $0) }
        #expect(recorded.map(\.level) == [.warning, .info, .warning])
        #expect(recorded.map(\.message) == [
            "Ollama isn't running on This Mac",
            "Ollama on This Mac is answering again",
            "Ollama isn't running on This Mac",
        ])
    }

    @Test func otherModelServersAreNamedGenerically() {
        var tracker = ReachabilityTracker()
        let down = entries(&tracker, thisMac: false, api: .openAICompatible)
        let up = entries(&tracker, thisMac: true, api: .openAICompatible)
        #expect(down.map(\.message) == ["The model server on This Mac isn't running"])
        #expect(up.map(\.message) == ["The model server on This Mac is answering again"])
    }

    @Test func networkMacChangesAreRecorded() {
        var tracker = ReachabilityTracker()
        let recorded = [false, true].flatMap { entries(&tracker, networkMac: $0) }
        #expect(recorded.map(\.level) == [.warning, .info])
        #expect(recorded.map(\.message) == ["The Network Mac isn't answering", "The Network Mac is answering again"])
        #expect(recorded.allSatisfy { $0.area == .engines })
    }

    @Test func unconfiguredNetworkMacRecordsNothing() {
        var tracker = ReachabilityTracker()
        #expect(entries(&tracker, networkMac: nil).isEmpty)
        #expect(entries(&tracker, networkMac: nil).isEmpty)
    }

    @Test func keyReadFailuresAreRecordedOnChange() {
        var tracker = ReachabilityTracker()
        let recorded = [false, false, true, true].flatMap { entries(&tracker, keyReadable: $0) }
        #expect(recorded.map(\.level) == [.warning, .info])
        #expect(recorded.map(\.message) == ["Muninn couldn't read its saved key", "Muninn can read its saved key again"])
    }

    @Test func eachSignalIsTrackedOnItsOwn() {
        var tracker = ReachabilityTracker()
        let first = entries(&tracker, thisMac: false, networkMac: true, keyReadable: true)
        let second = entries(&tracker, thisMac: false, networkMac: false, keyReadable: false)
        #expect(first.count == 1)
        #expect(second.map(\.message) == ["The Network Mac isn't answering", "Muninn couldn't read its saved key"])
    }

    @Test func anUntrackedThisMacRecordsNothingAndKeepsNoState() {
        var tracker = ReachabilityTracker()
        #expect(entries(&tracker, thisMac: nil).isEmpty)
        #expect(entries(&tracker, thisMac: nil).isEmpty)
        #expect(entries(&tracker, thisMac: true).isEmpty)
        #expect(entries(&tracker, thisMac: false).count == 1)
    }

    @Test func goingUntrackedAndBackDoesNotInventAChange() {
        var tracker = ReachabilityTracker()
        _ = entries(&tracker, thisMac: false)
        _ = entries(&tracker, thisMac: nil)
        #expect(entries(&tracker, thisMac: false).isEmpty)
    }
}
