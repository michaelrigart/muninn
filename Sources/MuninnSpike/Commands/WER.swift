import ArgumentParser
import Foundation
import MuninnCore

struct WER: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the word error rate of a hypothesis against a reference text.")

    @Argument(help: "Reference text file (the hand-corrected transcript).")
    var reference: String

    @Argument(help: "Hypothesis text file.")
    var hypothesis: String

    func run() throws {
        let reference = try String(contentsOf: Spike.fileURL(reference), encoding: .utf8)
        let hypothesis = try String(contentsOf: Spike.fileURL(hypothesis), encoding: .utf8)
        let result = WordErrorRate.compute(reference: reference, hypothesis: hypothesis)
        print(String(format: "WER:            %.2f %%", result.wer * 100))
        print("Reference words: \(result.referenceWords)")
        print("Substitutions:   \(result.substitutions)")
        print("Deletions:       \(result.deletions)")
        print("Insertions:      \(result.insertions)")
    }
}
