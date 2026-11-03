import Testing
@testable import MuninnCore

struct EngineSelectorTests {
    struct Row: Sendable, CustomTestStringConvertible {
        var preferred: EngineKind
        var forced: EngineKind?
        var studioReachable: Bool
        var pressure: MemoryPressureLevel
        var claudeKey: Bool
        var expected: EngineDecision

        var testDescription: String { "\(preferred) forced \(String(describing: forced)) -> \(expected)" }
    }

    static let rows: [Row] = [
        Row(preferred: .macbook, forced: nil, studioReachable: false, pressure: .normal, claudeKey: false, expected: .run(.macbook, fallbackFrom: nil)),
        Row(preferred: .macbook, forced: nil, studioReachable: false, pressure: .warning, claudeKey: false, expected: .wait(.memoryPressure)),
        Row(preferred: .studio, forced: nil, studioReachable: true, pressure: .critical, claudeKey: false, expected: .run(.studio, fallbackFrom: nil)),
        Row(preferred: .studio, forced: nil, studioReachable: false, pressure: .normal, claudeKey: false, expected: .run(.macbook, fallbackFrom: .studio, because: .studioUnreachable)),
        Row(preferred: .studio, forced: nil, studioReachable: false, pressure: .warning, claudeKey: false, expected: .wait(.studioUnreachable)),
        Row(preferred: .claude, forced: nil, studioReachable: false, pressure: .critical, claudeKey: true, expected: .run(.claude, fallbackFrom: nil)),
        Row(preferred: .claude, forced: nil, studioReachable: false, pressure: .normal, claudeKey: false, expected: .wait(.claudeKeyMissing)),
        Row(preferred: .studio, forced: .macbook, studioReachable: false, pressure: .critical, claudeKey: false, expected: .run(.macbook, fallbackFrom: nil)),
        Row(preferred: .macbook, forced: .claude, studioReachable: false, pressure: .critical, claudeKey: true, expected: .run(.claude, fallbackFrom: nil)),
        Row(preferred: .macbook, forced: .studio, studioReachable: false, pressure: .normal, claudeKey: false, expected: .wait(.studioUnreachable)),
    ]

    @Test(arguments: rows)
    func decisionTable(row: Row) {
        let environment = EngineEnvironment(
            studioConfigured: true,
            studioReachable: row.studioReachable,
            memoryPressure: row.pressure,
            claudeKeyPresent: row.claudeKey
        )
        #expect(EngineSelector.decide(preferred: row.preferred, forced: row.forced, environment: environment) == row.expected)
    }

    @Test func unconfiguredStudioIsNotConfigured() {
        let environment = EngineEnvironment(studioConfigured: false, studioReachable: true, memoryPressure: .normal, claudeKeyPresent: false)
        #expect(EngineSelector.decide(preferred: .studio, forced: nil, environment: environment) == .run(.macbook, fallbackFrom: .studio, because: .studioNotConfigured))
        #expect(EngineSelector.decide(preferred: .macbook, forced: .studio, environment: environment) == .wait(.studioNotConfigured))
        let pressured = EngineEnvironment(studioConfigured: false, studioReachable: false, memoryPressure: .warning, claudeKeyPresent: false)
        #expect(EngineSelector.decide(preferred: .studio, forced: nil, environment: pressured) == .wait(.studioNotConfigured))
    }

    @Test func recordingHoldsOnlyTheMacbookEngine() {
        func decide(_ preferred: EngineKind, forced: EngineKind? = nil, studioUp: Bool = true) -> EngineDecision {
            let environment = EngineEnvironment(
                studioConfigured: true, studioReachable: studioUp, memoryPressure: .normal, claudeKeyPresent: true, isRecording: true
            )
            return EngineSelector.decide(preferred: preferred, forced: forced, environment: environment)
        }
        #expect(decide(.macbook) == .wait(.recording))
        #expect(decide(.studio, forced: .macbook) == .wait(.recording))
        #expect(decide(.studio, studioUp: false) == .wait(.recording))
        #expect(decide(.studio) == .run(.studio, fallbackFrom: nil))
        #expect(decide(.claude) == .run(.claude, fallbackFrom: nil))
        #expect(decide(.macbook, forced: .claude) == .run(.claude, fallbackFrom: nil))
    }

    private func environment(
        studioConfigured: Bool = true, studioReachable: Bool = false, pressure: MemoryPressureLevel = .normal, claudeKey: Bool = true,
        isRecording: Bool = false, thisMacReachable: Bool = true, claudeKeyUnreadable: Bool = false
    ) -> EngineEnvironment {
        EngineEnvironment(
            studioConfigured: studioConfigured, studioReachable: studioReachable, memoryPressure: pressure, claudeKeyPresent: claudeKey,
            isRecording: isRecording, thisMacReachable: thisMacReachable, claudeKeyUnreadable: claudeKeyUnreadable
        )
    }

    @Test func thisMacDownWaits() {
        let down = environment(thisMacReachable: false)
        #expect(EngineSelector.decide(preferred: .macbook, forced: nil, environment: down) == .wait(.thisMacUnreachable))
        #expect(EngineSelector.decide(preferred: .claude, forced: .macbook, environment: down) == .wait(.thisMacUnreachable))
        #expect(EngineSelector.decide(preferred: .studio, forced: nil, environment: down) == .wait(.studioUnreachable))
        #expect(EngineSelector.decide(preferred: .studio, forced: .macbook, environment: down) == .wait(.thisMacUnreachable))
        #expect(EngineSelector.decide(preferred: .claude, forced: nil, environment: down) == .run(.claude, fallbackFrom: nil))
        let unconfigured = environment(studioConfigured: false, thisMacReachable: false)
        #expect(EngineSelector.decide(preferred: .studio, forced: nil, environment: unconfigured) == .wait(.studioNotConfigured))
    }

    @Test func aReachableThisMacStillRunsAsTheStudioFallback() {
        #expect(EngineSelector.decide(preferred: .studio, forced: nil, environment: environment()) == .run(.macbook, fallbackFrom: .studio, because: .studioUnreachable))
    }

    @Test func reachabilityComesBeforeMemoryPressure() {
        let down = environment(pressure: .critical, thisMacReachable: false)
        #expect(EngineSelector.decide(preferred: .macbook, forced: nil, environment: down) == .wait(.thisMacUnreachable))
        let up = environment(pressure: .critical)
        #expect(EngineSelector.decide(preferred: .macbook, forced: nil, environment: up) == .wait(.memoryPressure))
    }

    @Test func unreadableKeyWaits() {
        let unreadable = environment(claudeKey: false, claudeKeyUnreadable: true)
        #expect(EngineSelector.decide(preferred: .claude, forced: nil, environment: unreadable) == .wait(.claudeKeyUnreadable))
        #expect(EngineSelector.decide(preferred: .macbook, forced: .claude, environment: unreadable) == .wait(.claudeKeyUnreadable))
        #expect(EngineSelector.decide(preferred: .macbook, forced: nil, environment: unreadable) == .run(.macbook, fallbackFrom: nil))
    }

    @Test func recordingStillHoldsThisMac() {
        let recording = environment(isRecording: true)
        #expect(EngineSelector.decide(preferred: .macbook, forced: nil, environment: recording) == .wait(.recording))
        let down = environment(isRecording: true, thisMacReachable: false)
        #expect(EngineSelector.decide(preferred: .macbook, forced: nil, environment: down) == .wait(.thisMacUnreachable))
    }
}
