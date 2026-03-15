import AVFoundation
import Foundation

protocol AudioPipelineDelegate: AnyObject {
    func audioPipeline(_ pipeline: AudioPipeline, didUpdateRMS rms: Float)
    func audioPipelineDidDetectSilence(_ pipeline: AudioPipeline)
}

final class AudioPipeline {
    weak var delegate: AudioPipelineDelegate?
    let ringBuffer: RingBuffer

    private let engine = AVAudioEngine()
    private let sampleRate: Double = 16000.0
    private let maxDurationSeconds: Int = 60
    private var isCapturing = false

    // VAD
    private var silenceThreshold: Float = 0.01
    private var noiseFloor: Float = 0.0
    private var calibrationSamples: Int = 0
    private var calibrationAccumulator: Float = 0.0
    private let calibrationDuration: Int = 8000 // 500ms at 16kHz
    private var silentFrameCount: Int = 0
    private let silenceTimeoutFrames: Int = 32000 // 2 seconds at 16kHz
    private var isCalibrated = false

    init() {
        let capacity = Int(sampleRate) * maxDurationSeconds
        self.ringBuffer = RingBuffer(capacity: capacity)
    }

    var hasMicPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestMicPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func startCapture() throws {
        guard !isCapturing else { return }
        ringBuffer.reset()
        silentFrameCount = 0
        isCalibrated = false
        calibrationSamples = 0
        calibrationAccumulator = 0.0

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw AudioPipelineError.formatError }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioPipelineError.converterError
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        try engine.start()
        isCapturing = true
    }

    func stopCapture() -> [Float] {
        guard isCapturing else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        return ringBuffer.readAll()
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        let frameCount = AVAudioFrameCount(
            Double(buffer.frameLength) * sampleRate / buffer.format.sampleRate
        )
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

        var error: NSError?
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, let channelData = convertedBuffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))

        if !isCalibrated {
            for sample in samples {
                calibrationAccumulator += sample * sample
                calibrationSamples += 1
            }
            if calibrationSamples >= calibrationDuration {
                noiseFloor = sqrt(calibrationAccumulator / Float(calibrationSamples))
                silenceThreshold = max(0.01, noiseFloor * 3.0)
                isCalibrated = true
            }
        }

        ringBuffer.write(samples)

        let rms = ringBuffer.currentRMS
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.audioPipeline(self, didUpdateRMS: rms)
        }

        if isCalibrated {
            if rms < silenceThreshold {
                silentFrameCount += samples.count
                if silentFrameCount >= silenceTimeoutFrames {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.delegate?.audioPipelineDidDetectSilence(self)
                    }
                }
            } else {
                silentFrameCount = 0
            }
        }
    }
}

enum AudioPipelineError: Error {
    case formatError
    case converterError
}
