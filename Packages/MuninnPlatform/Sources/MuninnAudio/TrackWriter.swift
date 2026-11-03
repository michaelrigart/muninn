import AVFoundation

public enum TrackWriterError: Error, Equatable {
    case unsupportedFormat
}

public final class TrackWriter {
    public private(set) var framesWritten = 0

    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?

    /// The file holds 16-bit integer PCM; `AVAudioFile` converts from the Float32 processing format on write and back on read.
    public init(url: URL, sampleRate: Double, channels: Int, interleaved: Bool = false) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVAudioFileTypeKey: Int(kAudioFileCAFType),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: interleaved)
        self.file = file
        self.format = file.processingFormat
    }

    /// Writes the buffer, converting its channel count, interleaving and sample rate to the file's. Returns the frames written.
    @discardableResult
    public func append(_ buffer: AVAudioPCMBuffer) throws -> Int {
        guard let file else { return 0 }
        guard buffer.format.commonFormat == .pcmFormatFloat32, buffer.frameLength > 0 else {
            if buffer.frameLength == 0 { return 0 }
            throw TrackWriterError.unsupportedFormat
        }
        var output = buffer
        if !matches(buffer.format) {
            output = try remap(buffer)
            if output.format.sampleRate != format.sampleRate {
                output = try resample(output)
            }
        }
        guard output.frameLength > 0 else { return 0 }
        try file.write(from: output)
        framesWritten += Int(output.frameLength)
        return Int(output.frameLength)
    }

    public func appendSilence(frames: Int) throws {
        guard let file, frames > 0 else { return }
        let chunk = 48_000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(frames, chunk))) else {
            throw TrackWriterError.unsupportedFormat
        }
        let planes = format.isInterleaved ? 1 : Int(format.channelCount)
        let count = Int(buffer.frameCapacity) * (format.isInterleaved ? Int(format.channelCount) : 1)
        for plane in 0..<planes { buffer.floatChannelData![plane].update(repeating: 0, count: count) }
        var remaining = frames
        while remaining > 0 {
            buffer.frameLength = AVAudioFrameCount(min(remaining, chunk))
            try file.write(from: buffer)
            framesWritten += Int(buffer.frameLength)
            remaining -= Int(buffer.frameLength)
        }
    }

    public func close() {
        file?.close()
        file = nil
    }

    private func matches(_ other: AVAudioFormat) -> Bool {
        other.commonFormat == format.commonFormat && other.sampleRate == format.sampleRate
            && other.channelCount == format.channelCount && other.isInterleaved == format.isInterleaved
    }

    private func remap(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let inputChannels = Int(buffer.format.channelCount)
        let outputChannels = Int(format.channelCount)
        guard inputChannels > 0, outputChannels > 0,
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                channels: format.channelCount, interleaved: format.isInterleaved
            ),
            let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buffer.frameLength)
        else { throw TrackWriterError.unsupportedFormat }
        output.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let data = output.floatChannelData!
        for channel in 0..<outputChannels {
            let source = AudioSamples.channel(buffer, outputChannels == 1 ? 0 : min(channel, inputChannels - 1))
            let destination = format.isInterleaved ? data[0] + channel : data[channel]
            let step = format.isInterleaved ? outputChannels : 1
            for frame in 0..<frames { destination[frame * step] = source.data[frame * source.stride] }
        }
        return output
    }

    private func resample(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if converter == nil || converterInput?.sampleRate != buffer.format.sampleRate {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converterInput = buffer.format
        }
        guard let converter,
            let output = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
            )
        else { throw TrackWriterError.unsupportedFormat }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return output
    }
}
