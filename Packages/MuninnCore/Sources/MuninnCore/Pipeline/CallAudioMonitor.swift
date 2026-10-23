import Foundation

/// Spots a call track that has gone quiet while the microphone is live, which means the tap is no longer on the process playing the call, the call plays through another device, or Muninn may not record system audio.
public struct CallAudioMonitor: Sendable {
    public static let silenceDB: Float = -50
    public static let window: TimeInterval = 60

    private var quietSince: TimeInterval?
    private var micHeard = false

    public init() {}

    /// Returns true while the call track has been silent for a full window and the microphone had signal during it.
    public mutating func update(elapsed: TimeInterval, micDB: Float, systemDB: Float, paused: Bool) -> Bool {
        if paused || systemDB > Self.silenceDB {
            quietSince = nil
            micHeard = false
            return false
        }
        if quietSince == nil {
            quietSince = elapsed
            micHeard = false
        }
        if micDB > Self.silenceDB { micHeard = true }
        guard let quietSince else { return false }
        return micHeard && elapsed - quietSince >= Self.window
    }
}
