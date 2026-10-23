import ArgumentParser
import Foundation
import MuninnCore
import MuninnSpeech

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Transcribe one audio file and write transcript.json and transcript.md.")

    @Argument(help: "Audio file.")
    var audio: String

    @Option(help: "Model: \(SpeechModelID.allCases.map(\.rawValue).joined(separator: ", ")).")
    var model: SpeechModelID

    @Option(help: "Track the audio belongs to (mic or system).")
    var track: Track = .mic

    @Option(help: "Output directory.")
    var out: String

    func run() async throws {
        let url = Spike.fileURL(audio)
        let directory = try Spike.outputDirectory(out)
        let settings = Spike.settings()
        let audioSeconds = try AudioFile.duration(url)

        print("Transcribing \(url.lastPathComponent) (\(Spike.seconds(audioSeconds)) of audio) with \(model.rawValue); the first run downloads the model")
        let started = Date()
        let segments = try await TranscriberFactory.make(model).transcribe(audio: url, track: track, vocabulary: settings.dictionary)
        let elapsed = Date().timeIntervalSince(started)

        let transcript = Transcript(segments: segments, language: nil)
        try Spike.writeJSON(transcript, to: directory.appendingPathComponent("transcript.json"))
        let lines = segments.map { (id: $0.id, start: $0.start, speaker: $0.speaker.isEmpty ? track.rawValue : $0.speaker, text: $0.text) }
        try Spike.write(TranscriptMarkdown.render(segments: lines, title: url.lastPathComponent), to: directory.appendingPathComponent("transcript.md"))

        print("Segments:  \(segments.count)")
        print("Elapsed:   \(Spike.seconds(elapsed)) (includes model load)")
        if audioSeconds > 0 { print(String(format: "RTF:       %.3f (elapsed / audio; below 1 is faster than real time)", elapsed / audioSeconds)) }
        print("Wrote:     \(directory.path)/transcript.json, transcript.md")
    }
}
