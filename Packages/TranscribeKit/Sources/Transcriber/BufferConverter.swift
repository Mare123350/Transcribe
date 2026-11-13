@preconcurrency import AVFoundation

/// Converts captured audio (any sample rate, any channel count) into the format the speech model wants.
/// Multichannel interfaces are mixed down to mono.
final class BufferConverter {
    private var converter: AVAudioConverter?
    let outputFormat: AVAudioFormat

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == outputFormat { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.primeMethod = .none
            converter?.downmix = true
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        let feeder = Feeder(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            feeder.next(inputStatus)
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// Hands the converter one buffer, then reports that no more data is available yet.
    private final class Feeder: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let buffer else {
                status.pointee = .noDataNow
                return nil
            }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }
}
