import AVFoundation
import MuninnCore
import os

/// One composition of a meeting's recorded tracks, all starting at time zero, so a single player plays them in sync.
public final class PlaybackComposition: @unchecked Sendable {
    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "playback")

    public let composition: AVComposition
    public let duration: TimeInterval
    public let tracks: [Track]
    /// The tracks whose file exists but could not be played.
    public let skipped: [Track]
    let trackIDs: [Track: CMPersistentTrackID]

    private init(composition: AVComposition, duration: TimeInterval, tracks: [Track], skipped: [Track], trackIDs: [Track: CMPersistentTrackID]) {
        self.composition = composition
        self.duration = duration
        self.tracks = tracks
        self.skipped = skipped
        self.trackIDs = trackIDs
    }

    /// Nil when neither file holds audio. A file without an audio track or without duration counts as missing; one
    /// that cannot be read is skipped and listed in `skipped`, and the first such error is thrown when no file could be used.
    public static func load(mic: URL?, system: URL?) async throws -> PlaybackComposition? {
        let composition = AVMutableComposition()
        var kept: [Track] = []
        var skipped: [Track] = []
        var trackIDs: [Track: CMPersistentTrackID] = [:]
        var longest = CMTime.zero
        var firstError: Error?

        for (track, url) in [(Track.mic, mic), (Track.system, system)] {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let asset = AVURLAsset(url: url)
                let audio = try await asset.loadTracks(withMediaType: .audio)
                let duration = try await asset.load(.duration)
                guard let source = audio.first, duration.isValid, duration > .zero else { continue }
                guard let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    logger.error("Skipped the \(track.rawValue, privacy: .public) track: no composition track")
                    skipped.append(track)
                    continue
                }
                do {
                    try destination.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
                } catch {
                    composition.removeTrack(destination)
                    throw error
                }
                kept.append(track)
                trackIDs[track] = destination.trackID
                longest = max(longest, duration)
            } catch {
                logger.error("Skipped the \(track.rawValue, privacy: .public) track: \(error.localizedDescription, privacy: .public)")
                skipped.append(track)
                firstError = firstError ?? error
            }
        }

        if kept.isEmpty {
            if let firstError { throw firstError }
            return nil
        }
        return PlaybackComposition(composition: composition, duration: longest.seconds, tracks: kept, skipped: skipped, trackIDs: trackIDs)
    }

    public func audioMix(_ mix: PlaybackMix) -> AVAudioMix {
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = tracks.compactMap { track in
            guard let id = trackIDs[track] else { return nil }
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = id
            parameters.setVolume(mix.volume(for: track), at: .zero)
            return parameters
        }
        return audioMix
    }
}
