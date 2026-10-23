import Foundation
import Testing
@testable import MuninnCore

@Suite struct RecordingFlowTests {
    let call = CallIdentity(appName: "Teams", bundleID: "com.microsoft.teams2", pid: 42)

    func offering() -> RecordingFlowState {
        RecordingFlow.next(.idle, .callStarted(appName: "Teams", bundleID: "com.microsoft.teams2", pid: 42))
    }

    @Test func callStartedOffers() {
        #expect(offering() == .offering(call))
    }

    @Test func recordTappedTapsProcess() {
        #expect(RecordingFlow.next(offering(), .recordTapped) == .recording(.process(bundleID: "com.microsoft.teams2", pid: 42), call: call))
    }

    @Test func processTapFailureAsksBeforeAllAudio() {
        let recording = RecordingFlow.next(offering(), .recordTapped)
        let failed = RecordingFlow.next(recording, .processTapFailed)
        #expect(failed == .confirmAllAudio(call))
    }

    @Test func confirmStartsAllAudio() {
        let state = RecordingFlowState.confirmAllAudio(call)
        #expect(RecordingFlow.next(state, .confirmAllAudio) == .recording(.allSystemAudio, call: call))
    }

    @Test func cancelReturnsIdle() {
        #expect(RecordingFlow.next(.confirmAllAudio(call), .cancel) == .idle)
    }

    @Test func callEndedDismissesPrompt() {
        #expect(RecordingFlow.next(offering(), .callEnded(bundleID: call.bundleID)) == .idle)
        #expect(RecordingFlow.next(.confirmAllAudio(call), .callEnded(bundleID: call.bundleID)) == .idle)
    }

    @Test func otherAppEndingKeepsPrompt() {
        #expect(RecordingFlow.next(offering(), .callEnded(bundleID: "other")) == offering())
        #expect(RecordingFlow.next(.confirmAllAudio(call), .callEnded(bundleID: "other")) == .confirmAllAudio(call))
    }

    @Test func declinedReturnsIdle() {
        #expect(RecordingFlow.next(offering(), .declined) == .idle)
    }

    @Test func manualConversationIsMicOnly() {
        #expect(RecordingFlow.next(.idle, .manualConversation) == .recording(.micOnly, call: nil))
    }

    @Test func stoppedReturnsIdle() {
        #expect(RecordingFlow.next(.recording(.micOnly, call: nil), .stopped) == .idle)
    }

    @Test func confirmAllAudioNeverStartsWithoutPrompt() {
        #expect(RecordingFlow.next(offering(), .confirmAllAudio) == .offering(call))
        #expect(RecordingFlow.next(.idle, .confirmAllAudio) == .idle)
    }

    @Test func callEndedDoesNotStopRecording() {
        let recording = RecordingFlowState.recording(.process(bundleID: "com.microsoft.teams2", pid: 42), call: call)
        #expect(RecordingFlow.next(recording, .callEnded(bundleID: call.bundleID)) == recording)
    }

    @Test func irrelevantEventsLeaveStateUnchanged() {
        #expect(RecordingFlow.next(.idle, .recordTapped) == .idle)
        #expect(RecordingFlow.next(.recording(.allSystemAudio, call: call), .processTapFailed) == .recording(.allSystemAudio, call: call))
    }

    @Test func detectorFollowsTheWatchListOutsideARecording() {
        let old = ["com.a"]
        let new = ["com.a", "com.b"]
        for state in [RecordingFlowState.idle, .offering(call), .confirmAllAudio(call)] {
            #expect(RecordingFlow.detectorNeedsRestart(running: old, wanted: new, state: state))
            #expect(!RecordingFlow.detectorNeedsRestart(running: new, wanted: new, state: state))
        }
        #expect(RecordingFlow.detectorNeedsRestart(running: nil, wanted: new, state: .idle))
        #expect(!RecordingFlow.detectorNeedsRestart(running: nil, wanted: nil, state: .idle))
    }

    @Test func aRecordingKeepsItsDetectorUntilItReturnsToIdle() {
        let old = ["com.a"]
        let new = ["com.b"]
        let recording = RecordingFlow.next(offering(), .recordTapped)
        #expect(!RecordingFlow.detectorNeedsRestart(running: old, wanted: new, state: recording))
        for ending in [RecordingFlowEvent.stopped, .cancel] {
            let back = RecordingFlow.next(RecordingFlow.next(recording, .processTapFailed), ending)
            #expect(back == .idle)
            #expect(RecordingFlow.detectorNeedsRestart(running: old, wanted: new, state: back))
        }
        #expect(RecordingFlow.detectorNeedsRestart(running: old, wanted: new, state: RecordingFlow.next(recording, .stopped)))
    }
}
