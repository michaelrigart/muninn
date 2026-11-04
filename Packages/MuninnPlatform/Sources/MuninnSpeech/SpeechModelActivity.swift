import Foundation
import MuninnCore

/// A speech model that could not be downloaded or loaded; the cause is kept as its error domain and code.
public struct SpeechModelError: ProblemConvertible, Equatable {
    public var model: String
    public var domain: String
    public var code: Int

    public init(model: String, domain: String, code: Int) {
        self.model = model
        self.domain = domain
        self.code = code
    }

    public func problem(in context: ProblemContext) -> Problem {
        Problems.speechModelUnavailable(model: model, details: ProblemDetails(errorDomain: domain, errorCode: code))
    }
}

/// Tracks the speech models being downloaded or loaded, and records each one's start, end and failure in the Activity log.
public final class SpeechModelActivity: @unchecked Sendable {
    public static let shared = SpeechModelActivity()

    private struct Preparation {
        var token: UUID
        var value: SpeechModelPreparation
    }

    /// Recursive so an observer may read `preparing`; held while the observer runs so snapshots arrive in order.
    private let lock = NSRecursiveLock()
    private var current: [Preparation] = []
    private var observer: (@Sendable ([SpeechModelPreparation]) -> Void)?
    private var activity: ActivityRecording = NoActivity()

    public init() {}

    public var preparing: [SpeechModelPreparation] {
        lock.withLock { current.map(\.value) }
    }

    public func setObserver(_ handler: (@Sendable ([SpeechModelPreparation]) -> Void)?) {
        lock.withLock { observer = handler }
    }

    public func setActivity(_ activity: ActivityRecording) {
        lock.withLock { self.activity = activity }
    }

    public func run<T>(_ model: String, _ load: (_ report: @escaping @Sendable (Double?) -> Void) async throws -> T) async throws -> T {
        let token = UUID()
        let start = Date()
        lock.withLock {
            current.append(Preparation(token: token, value: SpeechModelPreparation(model: model, fraction: nil)))
            notify()
        }
        record("Getting \(model) ready")
        defer {
            lock.withLock {
                current.removeAll { $0.token == token }
                notify()
            }
        }
        do {
            let result = try await load { [weak self] fraction in
                self?.update(token, fraction: fraction.map { min(max($0, 0), 1) })
            }
            record("\(model) is ready (\(DurationText.short(Date().timeIntervalSince(start))))")
            return result
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            let failure = SpeechModelError(model: model, domain: (error as NSError).domain, code: (error as NSError).code)
            let problem = failure.problem(in: ProblemContext(stage: .preparingSpeechModel))
            lock.withLock { activity }.record(.problem(problem, area: .transcription, meeting: nil, time: Date()))
            throw failure
        }
    }

    private func update(_ token: UUID, fraction: Double?) {
        lock.withLock {
            guard let index = current.firstIndex(where: { $0.token == token }) else { return }
            current[index].value.fraction = fraction
            notify()
        }
    }

    private func notify() {
        observer?(current.map(\.value))
    }

    private func record(_ message: String) {
        lock.withLock { activity }.record(ActivityEntry(time: Date(), level: .info, area: .transcription, message: message))
    }
}
