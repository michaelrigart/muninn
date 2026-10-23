import Foundation
import Testing
@testable import MuninnCore

@Suite struct CallAudioMonitorTests {
    func step(_ monitor: inout CallAudioMonitor, elapsed: TimeInterval, micDB: Float, systemDB: Float, paused: Bool) -> Bool {
        monitor.update(elapsed: elapsed, micDB: micDB, systemDB: systemDB, paused: paused)
    }

    @Test func warnsAfterAMinuteOfSilentCallAudioWithLiveMic() {
        var monitor = CallAudioMonitor()
        #expect(!step(&monitor, elapsed: 10, micDB: -20, systemDB: -80, paused: false))
        #expect(!step(&monitor, elapsed: 69, micDB: -20, systemDB: -80, paused: false))
        #expect(step(&monitor, elapsed: 70, micDB: -20, systemDB: -80, paused: false))
    }

    @Test func staysQuietWhenTheMicIsSilentToo() {
        var monitor = CallAudioMonitor()
        #expect(!step(&monitor, elapsed: 0, micDB: -90, systemDB: -90, paused: false))
        #expect(!step(&monitor, elapsed: 120, micDB: -90, systemDB: -90, paused: false))
    }

    @Test func callAudioResetsTheWindow() {
        var monitor = CallAudioMonitor()
        _ = step(&monitor, elapsed: 0, micDB: -20, systemDB: -80, paused: false)
        #expect(step(&monitor, elapsed: 61, micDB: -20, systemDB: -80, paused: false))
        #expect(!step(&monitor, elapsed: 62, micDB: -20, systemDB: -30, paused: false))
        #expect(!step(&monitor, elapsed: 100, micDB: -20, systemDB: -80, paused: false))
        #expect(step(&monitor, elapsed: 162, micDB: -20, systemDB: -80, paused: false))
    }

    @Test func aPauseResetsTheWindow() {
        var monitor = CallAudioMonitor()
        _ = step(&monitor, elapsed: 0, micDB: -20, systemDB: -80, paused: false)
        #expect(!step(&monitor, elapsed: 61, micDB: -20, systemDB: -80, paused: true))
        #expect(!step(&monitor, elapsed: 62, micDB: -20, systemDB: -80, paused: false))
    }
}

@Suite struct LaunchRecoveryTests {
    @Test func deletesOnlyWhenEveryExistingTrackIsEmpty() {
        #expect(LaunchRecovery.decide([.frames(0), .missing]) == .delete)
        #expect(LaunchRecovery.decide([.frames(0), .frames(0)]) == .delete)
        #expect(LaunchRecovery.decide([.missing, .missing]) == .delete)
    }

    @Test func keepsAndTranscribesAudio() {
        #expect(LaunchRecovery.decide([.frames(48_000), .missing]) == .transcribe)
        #expect(LaunchRecovery.decide([.frames(0), .frames(10)]) == .transcribe)
    }

    @Test func anUnreadableTrackIsNeverDeleted() {
        #expect(LaunchRecovery.decide([.unreadable, .missing]) == .markUnreadable)
        #expect(LaunchRecovery.decide([.unreadable, .frames(0)]) == .markUnreadable)
        #expect(LaunchRecovery.decide([.unreadable, .frames(500)]) == .markUnreadable)
    }
}

@Suite struct InstanceArbiterTests {
    @Test func takesAFreeLockWithoutWaiting() {
        var sleeps = 0
        let got = InstanceArbiter.acquire(tryLock: { true }, sleep: { _ in sleeps += 1 })
        #expect(got)
        #expect(sleeps == 0)
    }

    @Test func waitsForAHolderThatIsQuitting() {
        var attempts = 0
        var slept: TimeInterval = 0
        let got = InstanceArbiter.acquire(tryLock: { attempts += 1; return attempts == 5 }, sleep: { slept += $0 })
        #expect(got)
        #expect(attempts == 5)
        #expect(slept == 4 * InstanceArbiter.pollInterval)
    }

    @Test func givesUpAfterTheLimitWhenTheLockStaysHeld() {
        var attempts = 0
        var slept: TimeInterval = 0
        let got = InstanceArbiter.acquire(tryLock: { attempts += 1; return false }, sleep: { slept += $0 })
        #expect(!got)
        #expect(slept == InstanceArbiter.waitLimit)
        #expect(attempts == Int(InstanceArbiter.waitLimit / InstanceArbiter.pollInterval) + 1)
    }

    @Test func aLockFreedAtTheLastPollStillCounts() {
        var attempts = 0
        let last = Int(InstanceArbiter.waitLimit / InstanceArbiter.pollInterval) + 1
        let got = InstanceArbiter.acquire(tryLock: { attempts += 1; return attempts == last }, sleep: { _ in })
        #expect(got)
    }

    @Test func aZeroLimitTriesOnce() {
        var attempts = 0
        #expect(!InstanceArbiter.acquire(limit: 0, tryLock: { attempts += 1; return false }, sleep: { _ in }))
        #expect(attempts == 1)
    }
}

@Suite struct MeetingGuardTests {
    func meeting(_ status: ProcessingStatus) -> Meeting {
        Meeting(
            id: MeetingID(rawValue: "m"), title: "t", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, captureMode: .micOnly,
            language: nil, accountID: nil, association: nil, client: nil, candidateEvents: [], attendees: [], recipients: [],
            flags: [], speakerNames: [:], status: status, summaryEngine: nil, engineNotice: nil, exportedNotePath: nil,
            draftWebLink: nil, metrics: ProcessingMetrics()
        )
    }

    @Test func deleteIsRefusedWhileRecordingOrProcessing() {
        for status in [ProcessingStatus.recording, .transcribing, .diarizing, .cleaning, .summarizing] {
            #expect(!MeetingActions.canDelete(meeting(status)))
        }
        for status in [ProcessingStatus.ready, .waiting(.studioUnreachable), .waiting(.recording), .failed("x")] {
            #expect(MeetingActions.canDelete(meeting(status)))
        }
    }

    @Test func eventCanChangeUntilADraftOrExportExists() {
        var m = meeting(.ready)
        #expect(MeetingActions.canChangeEvent(m))
        m.draftID = "d"
        #expect(!MeetingActions.canChangeEvent(m))
        m.draftID = nil
        m.draftWebLink = "https://x"
        #expect(!MeetingActions.canChangeEvent(m))
        m.draftWebLink = nil
        m.exportedNotePath = "a.md"
        #expect(!MeetingActions.canChangeEvent(m))
    }

    @Test func unsourcedItemsAreCountedAcrossBulletsAndActions() {
        let summary = Summary(
            language: "en",
            subjects: [
                Subject(
                    title: "A",
                    bullets: [Bullet(text: "sourced", sources: [1]), Bullet(text: "loose", sources: [])],
                    actions: [ActionPoint(owner: "Ada", text: "loose", due: nil, sources: []), ActionPoint(owner: "Bo", text: "ok", due: nil, sources: [2])]
                ),
                Subject(title: "B", bullets: [Bullet(text: "loose", sources: [])], actions: []),
                Subject(title: "C", bullets: [], actions: []),
            ],
            engine: .macbook, generatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(MeetingActions.unsourcedItemCount(in: summary) == 3)
        #expect(MeetingActions.unsourcedItemCount(in: Summary(language: "en", subjects: [], engine: .macbook, generatedAt: Date(timeIntervalSince1970: 0))) == 0)
    }
}
