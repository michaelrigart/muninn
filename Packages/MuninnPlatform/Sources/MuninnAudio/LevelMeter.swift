import Foundation

public enum LevelMeter {
    public static let floor: Float = -160

    public static func dbfs(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return floor }
        var sum = 0.0
        for sample in samples { sum += Double(sample) * Double(sample) }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms > 1e-8 else { return floor }
        return max(floor, Float(20 * log10(rms)))
    }
}
