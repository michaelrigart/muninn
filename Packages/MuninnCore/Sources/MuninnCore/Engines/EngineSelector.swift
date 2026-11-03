public enum MemoryPressureLevel: Int, Codable, Hashable, Sendable {
    case normal = 1, warning = 2, critical = 4
}

public struct EngineEnvironment: Sendable {
    public var studioConfigured: Bool
    public var studioReachable: Bool
    public var memoryPressure: MemoryPressureLevel
    public var claudeKeyPresent: Bool
    public var isRecording: Bool
    public var thisMacReachable: Bool
    public var claudeKeyUnreadable: Bool

    public init(
        studioConfigured: Bool, studioReachable: Bool, memoryPressure: MemoryPressureLevel, claudeKeyPresent: Bool, isRecording: Bool = false,
        thisMacReachable: Bool = true, claudeKeyUnreadable: Bool = false
    ) {
        self.studioConfigured = studioConfigured
        self.studioReachable = studioReachable
        self.memoryPressure = memoryPressure
        self.claudeKeyPresent = claudeKeyPresent
        self.isRecording = isRecording
        self.thisMacReachable = thisMacReachable
        self.claudeKeyUnreadable = claudeKeyUnreadable
    }
}

public enum EngineDecision: Equatable, Sendable {
    /// `because` says why a fallback was taken: the Network Mac was unreachable or has no address.
    case run(EngineKind, fallbackFrom: EngineKind?, because: WaitReason? = nil)
    case wait(WaitReason)
}

public enum EngineSelector {
    /// The This Mac engine never starts while a recording is running or its model server is down; the Network Mac and Claude are unaffected.
    /// The selector never returns `.wait(.queued)`: that reason is only stored once a wait has cleared.
    public static func decide(preferred: EngineKind, forced: EngineKind?, environment: EngineEnvironment) -> EngineDecision {
        let decision = choose(preferred: preferred, forced: forced, environment: environment)
        if environment.isRecording, case .run(.macbook, _, _) = decision { return .wait(.recording) }
        return decision
    }

    private static func choose(preferred: EngineKind, forced: EngineKind?, environment: EngineEnvironment) -> EngineDecision {
        let studioUp = environment.studioConfigured && environment.studioReachable
        let studioWait: WaitReason = environment.studioConfigured ? .studioUnreachable : .studioNotConfigured
        let macbookAllowed = environment.memoryPressure == .normal
        let claudeDecision: EngineDecision = environment.claudeKeyUnreadable
            ? .wait(.claudeKeyUnreadable)
            : environment.claudeKeyPresent ? .run(.claude, fallbackFrom: nil) : .wait(.claudeKeyMissing)

        if let forced {
            switch forced {
            case .macbook: return environment.thisMacReachable ? .run(.macbook, fallbackFrom: nil) : .wait(.thisMacUnreachable)
            case .studio: return studioUp ? .run(.studio, fallbackFrom: nil) : .wait(studioWait)
            case .claude: return claudeDecision
            }
        }

        switch preferred {
        case .macbook:
            if !environment.thisMacReachable { return .wait(.thisMacUnreachable) }
            return macbookAllowed ? .run(.macbook, fallbackFrom: nil) : .wait(.memoryPressure)
        case .studio:
            if studioUp { return .run(.studio, fallbackFrom: nil) }
            return macbookAllowed && environment.thisMacReachable ? .run(.macbook, fallbackFrom: .studio, because: studioWait) : .wait(studioWait)
        case .claude:
            return claudeDecision
        }
    }
}
