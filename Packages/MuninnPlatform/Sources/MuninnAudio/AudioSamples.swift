import AVFoundation

enum MonoMode {
    case channelZero
    case average
}

enum AudioSamples {
    static func channel(_ buffer: AVAudioPCMBuffer, _ index: Int) -> (data: UnsafePointer<Float>, stride: Int) {
        let data = buffer.floatChannelData!
        if buffer.format.isInterleaved {
            return (UnsafePointer(data[0]) + index, buffer.stride)
        }
        return (UnsafePointer(data[index]), 1)
    }

    static func mono(_ buffer: AVAudioPCMBuffer, mode: MonoMode = .average) -> [Float] {
        guard buffer.format.commonFormat == .pcmFormatFloat32, buffer.floatChannelData != nil else { return [] }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return [] }
        var result = [Float](repeating: 0, count: frames)
        let used = mode == .channelZero ? 1 : channels
        for index in 0..<used {
            let source = channel(buffer, index)
            for frame in 0..<frames { result[frame] += source.data[frame * source.stride] }
        }
        if used > 1 {
            let scale = 1 / Float(used)
            for frame in 0..<frames { result[frame] *= scale }
        }
        return result
    }

    static func dropHead(_ buffer: AVAudioPCMBuffer, frames: Int) -> AVAudioPCMBuffer? {
        slice(buffer, from: frames, to: Int(buffer.frameLength))
    }

    /// The frames `from..<to` as a new buffer, or nil when the range is empty or the buffer isn't Float32.
    static func slice(_ buffer: AVAudioPCMBuffer, from: Int, to: Int) -> AVAudioPCMBuffer? {
        let count = min(to, Int(buffer.frameLength)) - from
        guard buffer.format.commonFormat == .pcmFormatFloat32, from >= 0, count > 0,
            let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
            let source = buffer.floatChannelData, let destination = output.floatChannelData
        else { return nil }
        output.frameLength = AVAudioFrameCount(count)
        let channels = Int(buffer.format.channelCount)
        if buffer.format.isInterleaved {
            destination[0].update(from: source[0] + from * channels, count: count * channels)
        } else {
            for channel in 0..<channels { destination[channel].update(from: source[channel] + from, count: count) }
        }
        return output
    }
}
