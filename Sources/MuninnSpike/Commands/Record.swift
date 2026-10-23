import ArgumentParser
import Foundation

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Record the mic and a system audio track into mic.caf and system.caf. Ctrl-C stops early and keeps the files.")

    @Option(help: "How long to record.")
    var seconds: Int

    @OptionGroup var options: CaptureOptions

    @Option(help: "Output directory.")
    var out: String

    func validate() throws {
        guard options.chosen == 1 else {
            throw ValidationError("Choose exactly one of --app <bundleID>, --all-system or --mic-only.")
        }
        guard seconds > 0 else { throw ValidationError("--seconds must be positive.") }
    }

    func run() async throws {
        let directory = try Spike.outputDirectory(out)
        let capture = try CaptureRun.make(options, in: directory)
        let session = capture.session
        let drain = Task { () -> Int in
            var chunks = 0
            for await _ in session.liveAudio { chunks += 1 }
            return chunks
        }

        try await capture.start()
        let stop = StopSignal()
        print("Recording for \(seconds) s into \(directory.path) (Ctrl-C stops early)")
        try await capture.wait(seconds: seconds, stop: stop) { print(capture.levels($0)) }
        let duration = try await session.stop()
        capture.report(duration: duration, deliveredChunks: await drain.value)
        withExtendedLifetime(stop) {}
    }
}
