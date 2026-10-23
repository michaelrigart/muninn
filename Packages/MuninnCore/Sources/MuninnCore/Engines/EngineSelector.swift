public enum MemoryPressureLevel: Int, Codable, Hashable, Sendable {
    case normal = 1, warning = 2, critical = 4
}

public struct EngineEnvironment: Sendable {
    public var studioConfigured: Bool
    public var studioReachable: Bool
    public var memoryPressure: MemoryPressureLevel
    public var claudeKeyPresent: Bool
    public var isRecording: Bool

    public init(studioConfigured: Bool, studioReachable: Bool, memoryPressure: MemoryPressureLevel, claudeKeyPresent: Bool, isRecording: Bool = false) {
        self.studioConfigured = studioConfigured
        self.studioReachable = studioReachable
        self.memoryPressure = memoryPressure
        self.claudeKeyPresent = claudeKeyPresent
        self.isRecording = isRecording
    }
}

public enum EngineDecision: Equatable, Sendable {
    /// `because` says why a fallback was taken: the Network Mac was unreachable or has no address.
    case run(EngineKind, fallbackFrom: EngineKind?, because: WaitReason? = nil)
    case wait(WaitReason)
}

public enum EngineSelector {
    /// The This Mac engine never starts while a recording is running; the Network Mac and Claude are unaffected.
    public static func decide(preferred: EngineKind, forced: EngineKind?, environment: EngineEnvironment) -> EngineDecision {
        let decision = choose(preferred: preferred, forced: forced, environment: environment)
        if environment.isRecording, case .run(.macbook, _, _) = decision { return .wait(.recording) }
        return decision
    }

    private static func choose(preferred: EngineKind, forced: EngineKind?, environment: EngineEnvironment) -> EngineDecision {
        let studioUp = environment.studioConfigured && environment.studioReachable
        let studioWait: WaitReason = environment.studioConfigured ? .studioUnreachable : .studioNotConfigured
        let macbookAllowed = environment.memoryPressure == .normal

        if let forced {
            switch forced {
            case .macbook: return .run(.macbook, fallbackFrom: nil)
            case .studio: return studioUp ? .run(.studio, fallbackFrom: nil) : .wait(studioWait)
            case .claude: return environment.claudeKeyPresent ? .run(.claude, fallbackFrom: nil) : .wait(.claudeKeyMissing)
            }
        }

        switch preferred {
        case .macbook:
            return macbookAllowed ? .run(.macbook, fallbackFrom: nil) : .wait(.memoryPressure)
        case .studio:
            if studioUp { return .run(.studio, fallbackFrom: nil) }
            return macbookAllowed ? .run(.macbook, fallbackFrom: .studio, because: studioWait) : .wait(studioWait)
        case .claude:
            return environment.claudeKeyPresent ? .run(.claude, fallbackFrom: nil) : .wait(.claudeKeyMissing)
        }
    }
}
