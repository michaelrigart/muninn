import Foundation

public struct WERResult: Equatable, Sendable {
    public var wer: Double
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    public var referenceWords: Int

    public init(wer: Double, substitutions: Int, deletions: Int, insertions: Int, referenceWords: Int) {
        self.wer = wer
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.referenceWords = referenceWords
    }
}

public enum WordErrorRate {
    public static func compute(reference: String, hypothesis: String) -> WERResult {
        let ref = Tokenizer.normalizedWords(reference)
        let hyp = Tokenizer.normalizedWords(hypothesis)
        let n = ref.count
        let m = hyp.count

        struct Cell { var cost = 0; var s = 0; var d = 0; var i = 0 }
        var previous = (0...m).map { Cell(cost: $0, s: 0, d: 0, i: $0) }
        if n > 0 {
            for i in 1...n {
                var current = [Cell(cost: i, s: 0, d: i, i: 0)]
                current.reserveCapacity(m + 1)
                for j in stride(from: 1, through: m, by: 1) {
                    let match = ref[i - 1] == hyp[j - 1]
                    var best = previous[j - 1]
                    best.cost += match ? 0 : 1
                    if !match { best.s += 1 }
                    var delete = previous[j]
                    delete.cost += 1
                    delete.d += 1
                    if delete.cost < best.cost { best = delete }
                    var insert = current[j - 1]
                    insert.cost += 1
                    insert.i += 1
                    if insert.cost < best.cost { best = insert }
                    current.append(best)
                }
                previous = current
            }
        }
        let last = previous[m]
        let substitutions = last.s
        let deletions = last.d
        let insertions = last.i

        let errors = substitutions + deletions + insertions
        let wer: Double = n == 0 ? (errors == 0 ? 0 : 1.0) : Double(errors) / Double(n)
        return WERResult(wer: wer, substitutions: substitutions, deletions: deletions,
                         insertions: insertions, referenceWords: n)
    }
}
