import Foundation

/// What opening one audio track of an interrupted recording showed.
public enum TrackProbe: Equatable, Sendable {
    case missing
    case frames(Int64)
    case unreadable
}

public enum RecoveryAction: Equatable, Sendable {
    /// Every existing track opens and is empty: nothing to keep.
    case delete
    /// At least one track holds audio and none is unreadable.
    case transcribe
    /// A track exists but could not be opened: keep the meeting and say so.
    case markUnreadable
}

public enum LaunchRecovery {
    public static let unreadableMessage = "The recording couldn't be read after the app quit unexpectedly."

    /// Deletes only when every existing track opened with length 0, so an unreadable file is never thrown away.
    public static func decide(_ tracks: [TrackProbe]) -> RecoveryAction {
        if tracks.contains(.unreadable) { return .markUnreadable }
        if tracks.contains(where: { if case .frames(let n) = $0 { return n > 0 } else { return false } }) { return .transcribe }
        return .delete
    }
}
