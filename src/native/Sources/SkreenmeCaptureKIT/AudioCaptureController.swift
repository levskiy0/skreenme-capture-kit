import Foundation
import AVFoundation

final class AudioCaptureController: NSObject {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "skreen.record.audio.queue")

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    private(set) var activeDeviceId: String?

    func start(deviceId: String) throws {
        stop()

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )

        guard let device = discovery.devices.first(where: { $0.uniqueID == deviceId }) else {
            throw AudioError.deviceNotFound
        }

        session.beginConfiguration()

        guard let input = try? AVCaptureDeviceInput(device: device) else {
            throw AudioError.inputFailure
        }

        if session.canAddInput(input) {
            session.addInput(input)
        } else {
            throw AudioError.inputFailure
        }

        output.setSampleBufferDelegate(self, queue: queue)

        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            throw AudioError.outputFailure
        }

        session.commitConfiguration()
        session.startRunning()
        activeDeviceId = deviceId
    }

    func stop() {
        if session.isRunning {
            session.stopRunning()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
        }
        activeDeviceId = nil
    }
}

extension AudioCaptureController: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSampleBuffer?(sampleBuffer)
    }
}

extension AudioCaptureController {
    enum AudioError: LocalizedError {
        case deviceNotFound
        case inputFailure
        case outputFailure

        var errorDescription: String? {
            switch self {
            case .deviceNotFound:
                return "Audio device not found."
            case .inputFailure:
                return "Failed to configure audio input."
            case .outputFailure:
                return "Failed to configure audio output."
            }
        }
    }
}
