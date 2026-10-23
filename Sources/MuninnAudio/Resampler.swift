import AVFoundation

final class MonoResampler {
    static let targetRate = 16_000.0

    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var inputRate = 0.0

    func convert(_ mono: [Float], sampleRate: Double) -> [Float] {
        guard !mono.isEmpty, sampleRate > 0 else { return [] }
        if sampleRate == Self.targetRate { return mono }
        if converter == nil || inputRate != sampleRate {
            let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
            converter = AVAudioConverter(from: input, to: output)
            inputRate = sampleRate
        }
        guard let converter,
            let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(mono.count)),
            let result = AVAudioPCMBuffer(
                pcmFormat: output,
                frameCapacity: AVAudioFrameCount(Double(mono.count) * Self.targetRate / sampleRate) + 64
            )
        else { return [] }
        input.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        var supplied = false
        var error: NSError?
        converter.convert(to: result, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let data = result.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(result.frameLength)))
    }
}

public enum Resampler {
    public static func toMono16k(_ buffer: AVAudioPCMBuffer) -> [Float] {
        MonoResampler().convert(AudioSamples.mono(buffer), sampleRate: buffer.format.sampleRate)
    }
}
