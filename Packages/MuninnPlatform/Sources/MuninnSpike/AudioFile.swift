import AVFoundation

enum AudioFile {
    static func duration(_ url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Reads the whole file as 16 kHz mono. Channels are averaged block by block and one converter
    /// resamples the whole stream, so there is no seam where a block ends.
    static func mono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoFormat, to: outputFormat)
        else { throw SpikeError("Cannot convert \(url.lastPathComponent) to 16 kHz mono") }

        let blockFrames = AVAudioFrameCount(rate * 10)
        let outputCapacity = AVAudioFrameCount(Double(blockFrames) * 16_000 / rate) + 1024
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) / rate * 16_000))

        func drain(_ input: AVAudioPCMBuffer?) throws {
            var supplied = false
            while true {
                guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                    throw SpikeError("Cannot allocate an audio buffer")
                }
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, inputStatus in
                    if supplied || input == nil {
                        inputStatus.pointee = input == nil ? .endOfStream : .noDataNow
                        return nil
                    }
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                if let error { throw error }
                if let data = output.floatChannelData, output.frameLength > 0 {
                    samples += UnsafeBufferPointer(start: data[0], count: Int(output.frameLength))
                }
                if status != .haveData || output.frameLength == 0 { break }
            }
        }

        while file.framePosition < file.length {
            guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames),
                  let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: blockFrames)
            else { throw SpikeError("Cannot allocate an audio buffer for \(url.lastPathComponent)") }
            try file.read(into: block, frameCount: blockFrames)
            let frames = Int(block.frameLength)
            if frames == 0 { break }
            guard let source = block.floatChannelData, let target = mono.floatChannelData?[0] else { continue }
            let scale = 1 / Float(channels)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += source[channel][frame] }
                target[frame] = sum * scale
            }
            mono.frameLength = AVAudioFrameCount(frames)
            try drain(mono)
        }
        try drain(nil)
        return samples
    }
}
