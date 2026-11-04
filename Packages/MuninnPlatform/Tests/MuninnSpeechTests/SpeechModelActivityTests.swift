import Foundation
import MuninnCore
import Testing
@testable import MuninnSpeech

private final class Snapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [[SpeechModelPreparation]] = []

    func add(_ snapshot: [SpeechModelPreparation]) {
        lock.lock()
        all.append(snapshot)
        lock.unlock()
    }

    var values: [[SpeechModelPreparation]] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }
}

private final class RecordingActivity: ActivityRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [ActivityEntry] = []

    func record(_ entry: ActivityEntry) {
        lock.lock()
        all.append(entry)
        lock.unlock()
    }

    var entries: [ActivityEntry] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }
}

@Suite struct SpeechModelActivityTests {
    private func makeActivity() -> (SpeechModelActivity, Snapshots, RecordingActivity) {
        let activity = SpeechModelActivity()
        let snapshots = Snapshots()
        let recorder = RecordingActivity()
        activity.setObserver { snapshots.add($0) }
        activity.setActivity(recorder)
        return (activity, snapshots, recorder)
    }

    @Test func runReportsProgressThenEnds() async throws {
        let (activity, snapshots, recorder) = makeActivity()
        _ = try await activity.run("Parakeet v3") { report in report(0.5); return 1 }
        #expect(snapshots.values == [
            [.init(model: "Parakeet v3", fraction: nil)],
            [.init(model: "Parakeet v3", fraction: 0.5)],
            [],
        ])
        #expect(activity.preparing.isEmpty)
        let entries = recorder.entries
        #expect(entries.map(\.message).first == "Getting Parakeet v3 ready")
        #expect(entries.last?.message.hasPrefix("Parakeet v3 is ready (") == true)
        #expect(entries.allSatisfy { $0.level == .info && $0.area == .transcription })
    }

    @Test func progressIsClampedAndNilForgetsTheFraction() async throws {
        let (activity, snapshots, _) = makeActivity()
        _ = try await activity.run("Parakeet v3") { report in
            report(1.7)
            report(-0.2)
            report(nil)
        }
        #expect(snapshots.values.map { $0.first?.fraction } == [nil, 1, 0, nil, nil])
    }

    @Test func observerHearsOnlyAChangeOfWholePercent() async throws {
        let (activity, snapshots, _) = makeActivity()
        let during = try await activity.run("Parakeet v3") { report in
            report(0.5)
            report(0.501)
            report(0.504)
            report(0.51)
            report(nil)
            report(nil)
            return activity.preparing
        }
        #expect(during == [.init(model: "Parakeet v3", fraction: nil)])
        #expect(snapshots.values.map { $0.first?.fraction } == [nil, 0.5, 0.51, nil, nil])
    }

    @Test func preparingListsEachModelBeingPreparedWhileTheLoadRuns() async throws {
        let (activity, _, _) = makeActivity()
        let during = try await activity.run("Parakeet v3") { report in
            report(0.25)
            return activity.preparing
        }
        #expect(during == [.init(model: "Parakeet v3", fraction: 0.25)])
    }

    @Test func failedLoadEndsAndBecomesAModelProblem() async {
        let (activity, snapshots, recorder) = makeActivity()
        var thrown: Error?
        do {
            _ = try await activity.run("Parakeet v3") { _ -> Int in throw URLError(.notConnectedToInternet) }
        } catch {
            thrown = error
        }
        #expect(thrown as? SpeechModelError == SpeechModelError(model: "Parakeet v3", domain: NSURLErrorDomain, code: -1009))
        #expect(activity.preparing.isEmpty)
        #expect(snapshots.values.last == [])
        let entries = recorder.entries
        #expect(entries.map(\.message) == ["Getting Parakeet v3 ready", "The speech model couldn't be downloaded"])
        #expect(entries.last?.level == .problem)
        #expect(entries.last?.area == .transcription)
        #expect(entries.last?.details?.errorDomain == NSURLErrorDomain)
        #expect(entries.last?.details?.errorCode == -1009)
    }

    @Test func cancellationPassesThroughWithoutAProblem() async {
        for cancellation in [CancellationError() as Error, URLError(.cancelled)] {
            let (activity, _, recorder) = makeActivity()
            var thrown: Error?
            do {
                _ = try await activity.run("Parakeet v3") { _ -> Int in throw cancellation }
            } catch {
                thrown = error
            }
            #expect(thrown != nil)
            #expect(thrown is SpeechModelError == false)
            #expect(activity.preparing.isEmpty)
            #expect(recorder.entries.map(\.message) == ["Getting Parakeet v3 ready"])
        }
    }

    @Test func theErrorKeepsItsDomainAndCodeInTheProblemDetails() {
        let error = SpeechModelError(model: "Whisper large v3 turbo", domain: "NSPOSIXErrorDomain", code: 28)
        let problem = error.problem(in: ProblemContext(stage: .preparingSpeechModel))
        #expect(problem.title == "The speech model couldn't be downloaded")
        #expect(problem.details.errorDomain == "NSPOSIXErrorDomain")
        #expect(problem.details.errorCode == 28)
        #expect(problem.explanation.contains("Whisper large v3 turbo"))
    }

    @Test func modelsHaveDisplayNames() {
        #expect(SpeechModelID.parakeetV3.displayName == "Parakeet v3")
        #expect(SpeechModelID.parakeetUltra.displayName == "Parakeet Ultra")
        #expect(SpeechModelID.whisperLargeV3Turbo.displayName == "Whisper large v3 turbo")
    }
}
