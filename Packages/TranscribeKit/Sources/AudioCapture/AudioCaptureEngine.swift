@preconcurrency import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// One block of captured audio, copied out of the engine's tap so it can safely cross threads.
public struct AudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    /// Loudness from 0 (silence) to 1 (very loud), for a level meter.
    public let level: Float

    public init(buffer: AVAudioPCMBuffer, level: Float = 0) {
        self.buffer = buffer
        self.level = level
    }
}

public enum AudioCaptureError: LocalizedError, Sendable {
    case microphoneDenied
    case deviceUnavailable
    case noInput
    case engineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Transcribe doesn't have permission to use the microphone."
        case .deviceUnavailable:
            "The selected audio input couldn't be opened. Check that it's connected, or pick another input."
        case .noInput:
            "No audio input was found. Connect a microphone or audio interface."
        case .engineFailed(let message):
            "Audio capture failed: \(message)"
        }
    }
}

/// Captures audio from the chosen input with AVAudioEngine and delivers it as an async stream.
public actor AudioCaptureEngine {
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    /// An engine whose input is already connected, so Record starts quickly.
    private var prepared: AVAudioEngine?

    public init() {}

    public static func microphoneAuthorization() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// Connects to the audio hardware ahead of time (a few hundred milliseconds the first time).
    /// Doesn't start capturing or turn on the microphone indicator.
    public func prepare() {
        _ = AVCaptureDevice.authorizationStatus(for: .audio)
        guard engine == nil, prepared == nil else { return }
        let engine = AVAudioEngine()
        _ = engine.inputNode.outputFormat(forBus: 0)
        prepared = engine
    }

    /// Starts capturing. `deviceID` nil means the system default input.
    public func start(deviceID: AudioDeviceID?) throws -> AsyncStream<AudioChunk> {
        stop()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw AudioCaptureError.microphoneDenied }

        let engine = prepared ?? AVAudioEngine()
        prepared = nil
        let input = engine.inputNode
        if let deviceID {
            guard let unit = input.audioUnit else { throw AudioCaptureError.deviceUnavailable }
            var id = deviceID
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw AudioCaptureError.deviceUnavailable }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.noInput }

        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(256))
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tapBlock(continuation))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            throw AudioCaptureError.engineFailed(error.localizedDescription)
        }
        self.engine = engine
        self.continuation = continuation
        return stream
    }

    public func pause() {
        engine?.pause()
    }

    public func resume() throws {
        guard let engine else { return }
        do { try engine.start() } catch { throw AudioCaptureError.engineFailed(error.localizedDescription) }
    }

    /// Stops capturing and ends the stream.
    public func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        continuation?.finish()
        continuation = nil
    }

    // Built outside the actor: the tap runs on a real-time audio thread, not on this actor.
    private nonisolated static func tapBlock(_ continuation: AsyncStream<AudioChunk>.Continuation) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let copy = copy(buffer) else { return }
            continuation.yield(AudioChunk(buffer: copy, level: level(of: buffer)))
        }
    }

    private nonisolated static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let src = from.mData, let dst = to.mData else { continue }
            memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    private nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(data[0], 1, &rms, vDSP_Length(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (decibels + 60) / 60))
    }
}
