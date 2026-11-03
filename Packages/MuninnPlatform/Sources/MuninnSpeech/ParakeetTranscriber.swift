import FluidAudio
import Foundation
import MuninnCore

public struct ParakeetTranscriber: Transcribing {
    private let model: SpeechModelID
    private let engine: Engine?

    public init(model: SpeechModelID) {
        self.model = model
        engine = model.parakeetVersion.map(Engine.init(version:))
    }

    public func transcribe(audio: URL, track: Track, vocabulary: [String]) async throws -> [Segment] {
        guard let engine else { throw SpeechError.unsupportedModel(model) }
        let recognised: Engine.Recognition
        do {
            recognised = try await engine.recognise(audio)
        } catch ASRError.invalidAudioData {
            return []
        }

        let words = SegmentBuilder.words(from: recognised.tokens.map {
            TimedToken(text: $0.token, start: $0.startTime, end: $0.endTime)
        })
        guard !words.isEmpty else {
            let pieces = [SegmentBuilder.Piece(text: recognised.text, start: 0, end: recognised.duration, words: [])]
            let segments = SegmentBuilder.segments(from: pieces, track: track)
            if !segments.isEmpty {
                SpeechLog.logger.error("Parakeet returned text without token timings; keeping one segment without words")
            }
            return segments
        }

        let segments = SegmentBuilder.segments(from: words, track: track)
        guard !vocabulary.isEmpty else { return segments }
        return await engine.boost(segments, tokens: recognised.tokens, audio: audio, vocabulary: vocabulary)
    }
}

extension ParakeetTranscriber {
    actor Engine {
        struct Recognition {
            var tokens: [TokenTiming]
            var text: String
            var duration: TimeInterval
        }

        /// Context around a segment so the CTC pass hears the word edges.
        private static let padding: TimeInterval = 0.25
        private static let sampleRate = 16_000

        private let version: AsrModelVersion
        private var boosting: (vocabulary: [String], session: VocabularyBoostingSession)?

        init(version: AsrModelVersion) {
            self.version = version
        }

        func recognise(_ audio: URL) async throws -> Recognition {
            let manager = try await ParakeetModels.manager(for: version)
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(audio, decoderState: &state)
            return Recognition(tokens: result.tokenTimings ?? [], text: result.text, duration: result.duration)
        }

        /// Rescores one segment at a time against 16 kHz slices read from a disk-backed copy of
        /// the file, so memory stays bounded and a correction only ever touches its own segment.
        /// Boosting never breaks transcription: on failure the segments transcribed so far stand.
        func boost(_ segments: [Segment], tokens: [TokenTiming], audio: URL, vocabulary: [String]) async -> [Segment] {
            var result = segments
            do {
                let session = try await boostingSession(for: vocabulary)
                let (source, _) = try AudioSourceFactory().makeDiskBackedSource(from: audio, targetSampleRate: Self.sampleRate)
                defer { source.cleanup() }

                var cursor = 0
                for (index, segment) in segments.enumerated() {
                    let next = index + 1 < segments.count ? segments[index + 1].start : .infinity
                    var local: [TokenTiming] = []
                    while cursor < tokens.count, tokens[cursor].startTime < next - 1e-6 {
                        local.append(tokens[cursor])
                        cursor += 1
                    }
                    guard !local.isEmpty else { continue }

                    let origin = max(0, segment.start - Self.padding)
                    let from = Int(origin * Double(Self.sampleRate))
                    let to = min(source.sampleCount, Int((segment.end + Self.padding) * Double(Self.sampleRate)))
                    guard to > from else { continue }
                    var failure: Error?
                    let samples = [Float](unsafeUninitializedCapacity: to - from) { buffer, count in
                        do {
                            try source.copySamples(into: buffer.baseAddress!, offset: from, count: to - from)
                            count = to - from
                        } catch {
                            failure = error
                            count = 0
                        }
                    }
                    if let failure { throw failure }

                    let shifted = local.map {
                        TokenTiming(
                            token: $0.token,
                            tokenId: $0.tokenId,
                            startTime: $0.startTime - origin,
                            endTime: $0.endTime - origin,
                            confidence: $0.confidence
                        )
                    }
                    guard let output = await session.rescore(text: segment.text, tokenTimings: shifted, audioSamples: samples),
                          output.wasModified
                    else { continue }
                    let words = SegmentBuilder.realign(segment.words, to: output.text)
                    result[index].words = words
                    result[index].text = words.map(\.text).joined(separator: " ")
                }
            } catch {
                SpeechLog.logger.error("Vocabulary boosting failed, keeping the transcript as is: \(String(describing: error), privacy: .public)")
            }
            return result
        }

        private func boostingSession(for vocabulary: [String]) async throws -> VocabularyBoostingSession {
            if let boosting, boosting.vocabulary == vocabulary { return boosting.session }
            let context = CustomVocabularyContext(terms: vocabulary.map { CustomVocabularyTerm(text: $0) })
            let session = try await VocabularyBoostingSession(vocabulary: context, ctcModels: try await ParakeetModels.ctcModels())
            boosting = (vocabulary, session)
            return session
        }
    }
}
