import Foundation
import AVFoundation
import CoreImage

final class CameraController: NSObject {
    enum Format {
        case square
        case wide
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "skreen.record.camera.queue")
    private let ciContext = CIContext(options: nil)

    var onFrame: ((CGImage) -> Void)?
    private(set) var activeDeviceId: String?

    private var targetWidth: CGFloat = 640
    private var targetHeight: CGFloat = 640
    private var format: Format = .square

    func start(deviceId: String, targetWidth: Int = 640, targetHeight: Int = 640, format: Format = .square) throws {
        self.targetWidth = CGFloat(targetWidth)
        self.targetHeight = CGFloat(targetHeight)
        self.format = format
        stop()

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )

        guard let device = discovery.devices.first(where: { $0.uniqueID == deviceId }) else {
            throw CameraError.deviceNotFound
        }

        session.beginConfiguration()

        guard let input = try? AVCaptureDeviceInput(device: device) else {
            throw CameraError.inputFailure
        }

        if session.canAddInput(input) {
            session.addInput(input)
        } else {
            throw CameraError.inputFailure
        }

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)

        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            throw CameraError.outputFailure
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

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        autoreleasepool {
            let ciImage = CIImage(cvPixelBuffer: buffer)
            let sourceSize = ciImage.extent.size

            var processedImage: CIImage

            if format == .square {
                // For square format, crop to center square first
                let minDimension = min(sourceSize.width, sourceSize.height)
                let cropX = (sourceSize.width - minDimension) / 2
                let cropY = (sourceSize.height - minDimension) / 2
                let cropRect = CGRect(x: cropX, y: cropY, width: minDimension, height: minDimension)
                let croppedImage = ciImage.cropped(to: cropRect)

                // Translate to origin after crop to avoid black borders
                processedImage = croppedImage.transformed(by: CGAffineTransform(translationX: -croppedImage.extent.origin.x, y: -croppedImage.extent.origin.y))

                // Then scale to target size
                let scale = targetWidth / minDimension
                if scale != 1.0 {
                    processedImage = processedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                }
            } else {
                // For wide format, scale proportionally to fit target dimensions
                let scaleX = targetWidth / sourceSize.width
                let scaleY = targetHeight / sourceSize.height
                let scale = min(scaleX, scaleY)

                if scale < 1.0 {
                    processedImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                } else {
                    processedImage = ciImage
                }
            }

            // Render the final image using the actual extent
            guard let image = ciContext.createCGImage(processedImage, from: processedImage.extent) else {
                return
            }
            onFrame?(image)
        }
    }
}

private extension CIContext {
    func createCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(origin: .zero, size: ciImage.extent.size)
        return createCGImage(ciImage, from: rect)
    }
}

extension CameraController {
    enum CameraError: LocalizedError {
        case deviceNotFound
        case inputFailure
        case outputFailure

        var errorDescription: String? {
            switch self {
            case .deviceNotFound:
                return "Camera not found."
            case .inputFailure:
                return "Failed to configure camera input."
            case .outputFailure:
                return "Failed to configure camera output."
            }
        }
    }
}
