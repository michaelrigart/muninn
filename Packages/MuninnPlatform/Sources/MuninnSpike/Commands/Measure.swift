import ArgumentParser
import Foundation

struct Measure: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Sample memory pressure, swap and CPU every second into a CSV file.")

    @Option(help: "How long to sample.")
    var seconds: Int

    @Option(help: "CSV file to write.")
    var out: String

    func validate() throws {
        guard seconds > 0 else { throw ValidationError("--seconds must be positive.") }
    }

    func run() async throws {
        let url = Spike.fileURL(out)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sampler = LoadSampler()
        for _ in 0..<seconds {
            try await Task.sleep(for: .seconds(1))
            sampler.sample()
        }
        try sampler.write(to: url)
        sampler.printSummary()
        print("Wrote:          \(url.path)")
    }
}
