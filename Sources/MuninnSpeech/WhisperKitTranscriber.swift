import Foundation
import MuninnCore
import WhisperKit

public struct WhisperKitTranscriber: Transcribing {
    /// WhisperKit keeps only this many prompt tokens, the last ones (`Constants.maxTokenContext / 2 - 1`).
    static let promptTokenLimit = Constants.maxTokenContext / 2 - 1

    private let engine: Engine

    public init(model: String = "large-v3-v20240930_turbo") {
        engine = Engine(model: model)
    }

    public func transcribe(audio: URL, track: Track, vocabulary: [String]) async throws -> [Segment] {
        let pieces = try await engine.recognise(audio, vocabulary: vocabulary)
        let wordless = pieces.filter { $0.words.isEmpty && !$0.text.isEmpty }.count
        if wordless > 0 {
            SpeechLog.logger.error("WhisperKit returned \(wordless) segment(s) without word timings; keeping them as segments without words")
        }
        return SegmentBuilder.segments(from: pieces, track: track)
    }
}

extension WhisperKitTranscriber {
    actor Engine {
        private static let kits = KeyedLoadOnce<String, WhisperKit>()
        private static let gate = SerialGate()

        private let model: String

        init(model: String) {
            self.model = model
        }

        func recognise(_ audio: URL, vocabulary: [String]) async throws -> [SegmentBuilder.Piece] {
            let model = model
            let kit = try await Self.kits.value(for: model) {
                try await WhisperKit(WhisperKitConfig(model: model, verbose: false, logLevel: .none, load: true, download: true))
            }
            var options = DecodingOptions(
                task: .transcribe,
                language: nil,
                detectLanguage: true,
                skipSpecialTokens: true,
                wordTimestamps: true,
                chunkingStrategy: .vad
            )
            if !vocabulary.isEmpty, let tokenizer = kit.tokenizer {
                let (tokens, dropped) = PromptBuilder.tokens(for: vocabulary, limit: WhisperKitTranscriber.promptTokenLimit) {
                    tokenizer.encode(text: $0).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                }
                if dropped > 0 {
                    SpeechLog.logger.warning("WhisperKit prompt holds \(WhisperKitTranscriber.promptTokenLimit) tokens; dropped \(dropped) of \(vocabulary.count) vocabulary entries")
                }
                if !tokens.isEmpty { options.promptTokens = tokens }
            }

            let results = try await Self.gate.run {
                try await kit.transcribe(audioPath: audio.path, decodeOptions: options)
            }
            return results.flatMap(\.segments).map { segment in
                let words: [Word] = (segment.words ?? []).compactMap { timing in
                    let text = timing.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : Word(text: text, start: TimeInterval(timing.start), end: TimeInterval(timing.end))
                }
                return SegmentBuilder.Piece(
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end),
                    words: words
                )
            }
        }
    }
}
