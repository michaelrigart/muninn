import Foundation

public enum WordAlignment {
    /// The most table cells (n × m) the exact alignment of a segment's middle may use; beyond it, `pairs` aligns in windows.
    static let exactCellBudget = 1_000_000

    /// The side of a window when `pairs` aligns in windows; a window's table is far below `exactCellBudget`.
    static let windowSize = 500

    /// For each whitespace-separated token of `text`, the index of its timed word, or nil.
    public static func tokenWords(text: String, words: [Word]) -> [Int?] {
        let forms = text.split(whereSeparator: \.isWhitespace).map { Tokenizer.normalize(String($0)) }
        if forms.count == words.count { return forms.indices.map { $0 } }
        var result = [Int?](repeating: nil, count: forms.count)
        for (tokenIndex, wordIndex) in pairs(forms, words.map { Tokenizer.normalize($0.text) }) {
            result[tokenIndex] = wordIndex
        }
        return result
    }

    /// Matched index pairs of equal normalised forms, in order, with both indices strictly increasing.
    /// Empty forms never match. The result is a longest common subsequence whenever the lists, after
    /// trimming their common prefix and suffix, hold at most `exactCellBudget` table cells; beyond that
    /// it is found window by window, in time and memory linear in the input, and may be shorter than the
    /// longest.
    public static func pairs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let left = a.indices.filter { !a[$0].isEmpty }
        let right = b.indices.filter { !b[$0].isEmpty }
        var ids: [String: Int] = [:]
        func id(_ form: String) -> Int {
            if let known = ids[form] { return known }
            ids[form] = ids.count
            return ids.count - 1
        }
        let x = left.map { id(a[$0]) }
        let y = right.map { id(b[$0]) }
        let n = x.count
        let m = y.count

        var prefix = 0
        while prefix < min(n, m), x[prefix] == y[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(n, m) - prefix, x[n - 1 - suffix] == y[m - 1 - suffix] { suffix += 1 }

        var matched: [(Int, Int)] = (0..<prefix).map { ($0, $0) }
        let middleX = prefix..<(n - suffix)
        let middleY = prefix..<(m - suffix)
        if middleX.count * middleY.count <= exactCellBudget {
            matched += exact(x, y, middleX, middleY)
        } else {
            matched += windowed(x, y, middleX, middleY)
        }
        matched += (0..<suffix).map { (n - suffix + $0, m - suffix + $0) }
        return matched.map { (left[$0.0], right[$0.1]) }
    }

    /// A longest common subsequence of `x[xRange]` and `y[yRange]`, as indices into `x` and `y`.
    private static func exact(_ x: [Int], _ y: [Int], _ xRange: Range<Int>, _ yRange: Range<Int>) -> [(Int, Int)] {
        let n = xRange.count
        let m = yRange.count
        guard n > 0, m > 0 else { return [] }
        let xs = Array(x[xRange])
        let ys = Array(y[yRange])
        let stride = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * stride)
        table.withUnsafeMutableBufferPointer { cells in
            for i in Swift.stride(from: n - 1, through: 0, by: -1) {
                let row = i * stride
                let below = row + stride
                for j in Swift.stride(from: m - 1, through: 0, by: -1) {
                    cells[row + j] = xs[i] == ys[j] ? cells[below + j + 1] + 1 : max(cells[below + j], cells[row + j + 1])
                }
            }
        }

        var matched: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if xs[i] == ys[j] {
                matched.append((xRange.lowerBound + i, yRange.lowerBound + j))
                i += 1
                j += 1
            } else if table[(i + 1) * stride + j] >= table[i * stride + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return matched
    }

    /// Aligns `x[xRange]` and `y[yRange]` one window at a time. Each window is aligned exactly, but
    /// only the pairs in the first half of both sides are kept, because the window extends past them,
    /// and the first pair after those; the next window starts after the last kept pair.
    private static func windowed(_ x: [Int], _ y: [Int], _ xRange: Range<Int>, _ yRange: Range<Int>) -> [(Int, Int)] {
        let half = windowSize / 2
        var matched: [(Int, Int)] = []
        var i = xRange.lowerBound
        var j = yRange.lowerBound
        while i < xRange.upperBound, j < yRange.upperBound {
            let iEnd = min(xRange.upperBound, i + windowSize)
            let jEnd = min(yRange.upperBound, j + windowSize)
            let found = exact(x, y, i..<iEnd, j..<jEnd)
            if iEnd == xRange.upperBound, jEnd == yRange.upperBound {
                matched += found
                break
            }
            let reliable = found.prefix { $0.0 < i + half && $0.1 < j + half }
            // The first pair past the first half too, so a window with any pair moves on by more than half.
            let kept = found.prefix(reliable.count + 1)
            if let last = kept.last {
                matched += kept
                i = last.0 + 1
                j = last.1 + 1
            } else {
                i += half
                j += half
            }
        }
        return matched
    }
}
