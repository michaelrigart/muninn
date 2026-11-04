public enum WaitRetry {
    public static let interval: Duration = .seconds(15)
    public static let quickReasons: Set<WaitReason> = [.thisMacUnreachable, .studioUnreachable, .queued]

    /// Every fourth tick re-checks every waiting meeting (nil); the others only those that can clear on their own.
    public static func reasons(forTick tick: Int) -> Set<WaitReason>? {
        tick % 4 == 0 ? nil : quickReasons
    }
}
