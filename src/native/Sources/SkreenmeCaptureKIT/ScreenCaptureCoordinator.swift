import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreImage
import CoreVideo
import AppKit
import Darwin

private let axHitTestAttribute: CFString = "AXHitTest" as CFString
private let axEditableAttribute: CFString = "AXEditable" as CFString

private enum CursorKind: String {
    case arrow = "arrow"
    case ibeam = "ibeam"
    case pointer = "pointer"
    case crosshair = "crosshair"
    case openHand = "open-hand"
    case closedHand = "closed-hand"
    case ewResize = "ew-resize"
    case nsResize = "ns-resize"
    case nwseResize = "nwse-resize"
    case notAllowed = "not-allowed"
    case copy = "copy"
    case alias = "alias"
    case contextMenu = "context-menu"
    case zoomIn = "zoom-in"
    case zoomOut = "zoom-out"

    static let arrowLike: [CursorKind] = [.arrow]

    var value: String { rawValue }
}

final class ScreenCaptureCoordinator: NSObject {
    private static let timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t(numer: 0, denom: 0)
        mach_timebase_info(&info)
        return info
    }()
    private static let nanosecondsPerSecond = 1_000_000_000.0

    private let captureQueue = DispatchQueue(label: "skreen.record.capture.queue")
    private let writerQueue = DispatchQueue(label: "skreen.record.writer.queue")
    private let ciContext = CIContext(options: [CIContextOption.useSoftwareRenderer: false])
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()

    // Callback for cursor updates
    var onCursorUpdate: ((String) -> Void)?
    private var lastSentCursorType: String?

    private var stream: SCStream?
    private var streamOutput: StreamSampleHandler?

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    // Separate writer for camera
    private var cameraAssetWriter: AVAssetWriter?
    private var cameraVideoInput: AVAssetWriterInput?
    private var cameraPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var currentSessionId: String?
    private var outputURL: URL?
    private var cameraOutputURL: URL?
    private var projectDirURL: URL?

    // Mouse and keyboard event tracking
    private var mouseEvents: [[String: Any]] = []
    private var keyboardEvents: [[String: Any]] = []
    private var eventTap: CFMachPort?

    private var latestVideoImage: CGImage?
    private var latestCameraImage: CGImage?

    private var cachedVideoBase64: String?
    private var cachedCameraBase64: String?

    private var cameraController: CameraController?
    private var audioController: AudioCaptureController?

    private let mouseEventsQueue = DispatchQueue(label: "skreen.record.mouse-events")

    private var cachedContent: SCShareableContent?

    private var excludedWindowId: UInt32?
    private var excludedWindowTitle: [String]?

    private var sessionStarted = false
    private var firstFrameTime: CMTime?
    private var cameraSessionStarted = false
    private var cameraFirstFrameTime: CMTime?

    // Camera dimensions (set from parameters, no defaults)
    private var cameraWidth: Int = 0
    private var cameraHeight: Int = 0

    // Recording frame rate (set from parameters)
    private var recordingFrameRate: Int = 30

    // Session start time for relative timestamps
    private var sessionStartTime: CFAbsoluteTime?

    // Parameters for cursor coordinate transformation
    private var displayScaleFactor: CGFloat = 1.0  // Scale factor (Retina = 2.0)
    private var captureOffset: CGPoint = .zero      // Offset for window/region
    private var captureMode: String = "display"     // "display", "window", "region"
    private var captureSize: CGSize = .zero         // Physical pixel size of capture target

    private var lastPreviewUpdateTime: Date?
    private let previewUpdateInterval: TimeInterval = 1.0 / 30.0 // 30 fps max for preview

    // Cursor polling timer - records cursor position at fixed intervals
    private var cursorPollTimer: DispatchSourceTimer?
    private var lastCursorPosition: CGPoint = .zero
    private var recordingStartMediaTime: CFTimeInterval = 0.0
    private var recordingStartEventTime: CFTimeInterval?

    func setExcludedWindow(id: UInt32?) {
        excludedWindowId = id
    }

    func setExcludedWindow(title: [String]?) {
        excludedWindowTitle = title
    }

    private func isWindowExcludedByTitle(_ windowTitle: String?) -> Bool {
        guard let excludedWindowTitle = excludedWindowTitle,
              let windowTitle = windowTitle else {
            return false
        }
        return excludedWindowTitle.contains { excludedTitle in
            windowTitle.caseInsensitiveCompare(excludedTitle.trimmingCharacters(in: .whitespaces)) == .orderedSame
        }
    }

    func listSources() async throws -> SourceListingPayload {
        cachedContent = try await SCShareableContent.current
        guard let content = cachedContent else {
            throw ScreenCaptureError.shareableContentUnavailable
        }

        let displays = content.displays.map { display in
            let displayIdString = String(display.displayID)
            let fallbackName = "Display \(displayIdString)"
            let attributes = ScreenCaptureCoordinator.displayAttributes(for: display.displayID)
            let displayName = attributes.name ?? fallbackName
            return SourceListingPayload.Display(
                id: displayIdString,
                name: displayName,
                frame: CGRect(origin: .zero, size: display.frame.size),
                scaleFactor: attributes.scale
            )
        }

        let windows = content.windows.filter { window in
            if let excludedWindowId, window.windowID == excludedWindowId {
                return false
            }
            if isWindowExcludedByTitle(window.title) {
                return false
            }
            return true
        }.map { window in
            let ownerName = window.owningApplication?.applicationName ?? "Application"
            return SourceListingPayload.Window(
                id: "\(window.windowID)",
                name: window.title ?? "Window \(window.windowID)",
                ownerName: ownerName,
                frame: window.frame
            )
        }

        let audioDevices = ScreenCaptureCoordinator.microphoneDevices().map { device in
            SourceListingPayload.AudioDevice(
                id: device.uniqueID,
                name: device.localizedName,
                type: "input"
            )
        }

        let cameraDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        ).devices.map { device in
            SourceListingPayload.Camera(
                id: device.uniqueID,
                name: device.localizedName
            )
        }

        return SourceListingPayload(
            displays: displays,
            windows: windows,
            audio: audioDevices,
            cameras: cameraDevices
        )
    }

    func startSession(payload: StartSessionPayload) async throws -> StartSessionResponse {
        guard stream == nil else {
            throw ScreenCaptureError.sessionAlreadyRunning
        }

        cachedContent = try await SCShareableContent.current
        guard let content = cachedContent else {
            throw ScreenCaptureError.shareableContentUnavailable
        }
        let sessionId = UUID().uuidString
        let outputURL = try resolveOutputURL(for: payload)

        // Use frameRate from payload, default to 30 if not specified
        let frameRate = payload.frameRate ?? 30
        self.recordingFrameRate = frameRate
        fputs("[Swift] startSession frameRate from payload: \(payload.frameRate?.description ?? "nil")\n", stderr)
        fputs("[Swift] startSession using frameRate: \(frameRate)\n", stderr)

        let configuration = SCStreamConfiguration()
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.queueDepth = 8
        configuration.scalesToFit = true
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = payload.showCursor ?? true  // Capture actual visual cursor from screen

        captureSize = .zero
        let contentFilter = try makeContentFilter(for: payload, content: content, configuration: configuration)

        let streamOutput = StreamSampleHandler(coordinator: self)
        stream = SCStream(filter: contentFilter, configuration: configuration, delegate: streamOutput)
        self.streamOutput = streamOutput

        if let stream = stream {
            try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: captureQueue)
        }

        // Configure camera with format and dimensions if camera source is specified
        if payload.cameraSourceId != nil {
            guard let width = payload.cameraWidth, let height = payload.cameraHeight else {
                throw ScreenCaptureError.invalidRegion
            }
            let format: CameraController.Format = payload.cameraFormat == .wide ? .wide : .square
            try configureCamera(deviceId: payload.cameraSourceId, width: width, height: height, format: format)
        } else {
            try configureCamera(deviceId: nil)
        }

        try setupAssetWriter(url: outputURL, configuration: configuration, captureAudio: payload.audioSourceId != nil)
        try configureAudio(deviceId: payload.audioSourceId)

        // If camera is enabled, prepare camera dimensions and URL (but don't create writer yet)
        if payload.cameraSourceId != nil || cameraController != nil {
            // Set camera dimensions from payload (required, should be set from config)
            guard let width = payload.cameraWidth, let height = payload.cameraHeight else {
                throw ScreenCaptureError.invalidRegion
            }
            self.cameraWidth = width
            self.cameraHeight = height
            let cameraURL = try resolveCameraOutputURL(basedOn: outputURL)
            self.cameraOutputURL = cameraURL
            // Note: Camera asset writer will be lazily initialized when first frame arrives
        }

        try await stream?.startCapture()
        currentSessionId = sessionId
        self.outputURL = outputURL

        // Start mouse event tracking
        resetMouseEventsStorage()
        keyboardEvents = []
        sessionStartTime = CFAbsoluteTimeGetCurrent()
        recordingStartEventTime = nil
        startEventMonitoring()
        startCursorPolling()

        return StartSessionResponse(sessionId: sessionId, outputPath: outputURL.path)
    }

    func stopSession(sessionId: String) async throws -> StopSessionResponse {
        guard let stream else {
            throw ScreenCaptureError.sessionNotRunning
        }

        // Validate that sessionId matches current session
        guard let activeSessionId = self.currentSessionId, activeSessionId == sessionId else {
            throw ScreenCaptureError.sessionNotRunning
        }


        try await stream.stopCapture()
        streamOutput?.invalidate()
        self.stream = nil
        streamOutput = nil

        cameraController?.stop()
        cameraController = nil
        audioController?.stop()
        audioController = nil

        writerQueue.sync {
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            cameraVideoInput?.markAsFinished()
        }

        if let writer = assetWriter {
            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    continuation.resume()
                }
            }
        }

        // Close camera writer if it was created
        if let cameraWriter = cameraAssetWriter {
            await withCheckedContinuation { continuation in
                cameraWriter.finishWriting {
                    continuation.resume()
                }
            }
        }

        assetWriter = nil
        videoInput = nil
        audioInput = nil
        pixelBufferAdaptor = nil

        let savedCameraURL = cameraOutputURL
        cameraAssetWriter = nil
        cameraVideoInput = nil
        cameraPixelBufferAdaptor = nil
        cameraOutputURL = nil

        sessionStarted = false
        cameraSessionStarted = false
        firstFrameTime = nil
        cameraFirstFrameTime = nil
        sessionStartTime = nil
        cachedVideoBase64 = nil
        cachedCameraBase64 = nil
        lastPreviewUpdateTime = nil
        recordingStartMediaTime = 0.0
        recordingStartEventTime = nil

        guard let outputURL else {
            throw ScreenCaptureError.outputUnavailable
        }

        currentSessionId = nil
        excludedWindowId = nil
        excludedWindowTitle = nil
        cachedContent = nil

        // Stop event tracking
        stopEventMonitoring()
        stopCursorPolling()

        // Gather recording metadata
        let projectDir = projectDirURL ?? outputURL.deletingLastPathComponent()
        let duration = calculateRecordingDuration()

        // Collect screen recording metadata
        var screenSource: RecordingSource?
        if FileManager.default.fileExists(atPath: outputURL.path) {
            let screenSize = try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64 ?? 0
            fputs("[Swift] stopSession creating metadata: fps=\(recordingFrameRate), pixelDensity=\(displayScaleFactor)\n", stderr)
            screenSource = RecordingSource(
                file: outputURL.lastPathComponent,
                size: screenSize ?? 0,
                resolution: RecordingSource.Resolution(
                    width: Double(captureSize.width),
                    height: Double(captureSize.height)
                ),
                fps: recordingFrameRate,
                pixelDensity: Double(displayScaleFactor)
            )
        }

        // Collect camera recording metadata
        var cameraSource: RecordingSource?
        if let cameraURL = savedCameraURL, FileManager.default.fileExists(atPath: cameraURL.path) {
            let cameraSize = try? FileManager.default.attributesOfItem(atPath: cameraURL.path)[.size] as? Int64 ?? 0
            cameraSource = RecordingSource(
                file: cameraURL.lastPathComponent,
                size: cameraSize ?? 0,
                resolution: RecordingSource.Resolution(
                    width: Double(cameraWidth),
                    height: Double(cameraHeight)
                ),
                fps: recordingFrameRate,
                pixelDensity: 1.0  // Camera is always 1x density
            )
        }

        // Convert mouse events to JSONValue
        let eventsJSON = try convertEventsToJSON(snapshotMouseEvents())

        // Build response
        let metadata = StopSessionResponse.RecordingMetadata(
            status: "completed",
            outputPath: projectDir.path,
            duration: duration,
            screen: screenSource,
            camera: cameraSource
        )

        // Reset recording parameters AFTER creating metadata
        recordingFrameRate = 30
        displayScaleFactor = 1.0
        captureOffset = .zero
        captureMode = "display"

        return StopSessionResponse(recording: metadata, events: eventsJSON)
    }

    private func writeCameraFrame(_ cameraImage: CGImage) {
        // Lazy-initialize camera asset writer on first frame
        if cameraAssetWriter == nil, let cameraURL = cameraOutputURL {
            do {
                try setupCameraAssetWriter(url: cameraURL)
            } catch {
                print("[ScreenCaptureCoordinator] Failed to setup camera asset writer: \(error)")
                return
            }
        }

        guard let cameraVideoInput, cameraVideoInput.isReadyForMoreMediaData,
              let adaptor = cameraPixelBufferAdaptor,
              let writer = cameraAssetWriter else {
            return
        }

        writerQueue.async { [weak self] in
            guard let self else { return }

            // Create pixel buffer from camera image using configured dimensions
            let width = self.cameraWidth
            let height = self.cameraHeight

            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            )

            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                return
            }

            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

            // Render camera image to pixel buffer with aspect fill (cover mode)
            let ciImage = CIImage(cgImage: cameraImage)
            let imageSize = ciImage.extent.size
            let targetSize = CGSize(width: width, height: height)

            // Calculate scale to FILL the target (cover mode) - use MAX scale
            let scaleX = targetSize.width / imageSize.width
            let scaleY = targetSize.height / imageSize.height
            let scale = max(scaleX, scaleY)  // Use max to ensure image covers entire target

            // Calculate scaled size
            let scaledWidth = imageSize.width * scale
            let scaledHeight = imageSize.height * scale

            // Calculate offset to center the image
            let offsetX = (targetSize.width - scaledWidth) / 2.0
            let offsetY = (targetSize.height - scaledHeight) / 2.0

            // Transform: scale and center
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(x: offsetX / scale, y: offsetY / scale)

            let transformedImage = ciImage.transformed(by: transform)

            // Crop to target size (this cuts off the parts that overflow)
            let croppedImage = transformedImage.cropped(to: CGRect(origin: .zero, size: targetSize))

            // Render to buffer
            self.ciContext.render(croppedImage, to: buffer, bounds: CGRect(origin: .zero, size: targetSize), colorSpace: self.rgbColorSpace)

            // Get presentation time for camera (independent of main video)
            let now = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
            let presentationTime: CMTime

            if let cameraFirstTime = self.cameraFirstFrameTime {
                presentationTime = CMTimeSubtract(now, cameraFirstTime)
            } else {
                // First camera frame - initialize time
                self.cameraFirstFrameTime = now
                presentationTime = CMTime.zero
            }

            // Start camera session with first frame
            if !self.cameraSessionStarted {
                writer.startSession(atSourceTime: .zero)
                self.cameraSessionStarted = true
            }

            guard writer.status == .writing else {
                return
            }

            if !adaptor.append(buffer, withPresentationTime: presentationTime) {
            }
        }
    }

    func configureCamera(deviceId: String?, width: Int = 640, height: Int = 640, format: CameraController.Format = .square) throws {
        if let deviceId {
            if let controller = cameraController, controller.activeDeviceId == deviceId {
                return
            }
            cameraController?.stop()
            let controller = CameraController()
            try controller.start(deviceId: deviceId, targetWidth: width, targetHeight: height, format: format)
            controller.onFrame = { [weak self] image in
                self?.latestCameraImage = image
                self?.writeCameraFrame(image)
            }
            cameraController = controller
        } else {
            cameraController?.stop()
            cameraController = nil
            latestCameraImage = nil
        }
    }

    func configureAudio(deviceId: String?) throws {
        guard let deviceId else {
            audioController?.stop()
            audioController = nil
            return
        }

        guard audioInput != nil else {
            audioController?.stop()
            audioController = nil
            return
        }

        if let controller = audioController, controller.activeDeviceId == deviceId {
            return
        }

        audioController?.stop()
        let controller = AudioCaptureController()
        controller.onSampleBuffer = { [weak self] buffer in
            self?.appendAudioSampleBuffer(buffer)
        }
        try controller.start(deviceId: deviceId)
        audioController = controller
    }

    func checkPermissions() -> PermissionsResponse {
        // 1. Screen Recording (ScreenCaptureKit)
        let screenRecording = CGPreflightScreenCaptureAccess()

        // 2. Camera
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let camera: String
        switch cameraStatus {
        case .authorized:
            camera = "granted"
        case .denied, .restricted:
            camera = "denied"
        case .notDetermined:
            camera = "prompt"
        @unknown default:
            camera = "unknown"
        }

        // 3. Microphone
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let microphone: String
        switch micStatus {
        case .authorized:
            microphone = "granted"
        case .denied, .restricted:
            microphone = "denied"
        case .notDetermined:
            microphone = "prompt"
        @unknown default:
            microphone = "unknown"
        }

        // 4. Accessibility (for CGEventTap)
        let accessibility = AXIsProcessTrusted()

        return PermissionsResponse(
            screenRecording: screenRecording,
            camera: camera,
            microphone: microphone,
            accessibility: accessibility
        )
    }

    func requestPermissions() async -> PermissionsResponse {
        // Request screen recording permission
        _ = await withCheckedContinuation { continuation in
            CGRequestScreenCaptureAccess()
            continuation.resume(returning: ())
        }

        // Request camera permission
        _ = await AVCaptureDevice.requestAccess(for: .video)

        // Request microphone permission
        _ = await AVCaptureDevice.requestAccess(for: .audio)

        // For Accessibility, need to open System Preferences
        // This cannot be requested programmatically, only show user a hint

        return checkPermissions()
    }

    func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            handleVideoSampleBuffer(sampleBuffer)
        case .audio, .microphone:
            appendAudioSampleBuffer(sampleBuffer)
        @unknown default:
            break
        }
    }

    private func resolveOutputURL(for payload: StartSessionPayload) throws -> URL {
        if let outputPath = payload.outputPath {
            // Create project directory
            let projectDir = URL(fileURLWithPath: outputPath)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            // Save reference to project directory
            self.projectDirURL = projectDir
            // Return path to screen.mp4 inside directory
            return projectDir.appendingPathComponent("screen.mp4")
        }
        let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        let folderURL = moviesURL?.appendingPathComponent("SkreenRecord", isDirectory: true)

        if let folderURL {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let filename = "Recording-\(ISO8601DateFormatter().string(from: Date())).mp4"
            return folderURL.appendingPathComponent(filename)
        }

        let tempURL = FileManager.default.temporaryDirectory
        let filename = "Recording-\(UUID().uuidString).mp4"
        return tempURL.appendingPathComponent(filename)
    }

    private func resolveCameraOutputURL(basedOn baseURL: URL) throws -> URL {
        // baseURL is screen.mp4, take parent directory and add camera.mp4
        return baseURL.deletingLastPathComponent().appendingPathComponent("camera.mp4")
    }

    private func makeContentFilter(for payload: StartSessionPayload, content: SCShareableContent, configuration: SCStreamConfiguration) throws -> SCContentFilter {
        switch payload.mode {
        case .display:
            guard
                let displayId = payload.displayId,
            let display = content.displays.first(where: { String($0.displayID) == displayId })
            else {
                throw ScreenCaptureError.displayNotFound
            }

            let excludedWindows = resolveExcludedWindows(from: content)
            let attributes = ScreenCaptureCoordinator.displayAttributes(for: display.displayID)

            // Save parameters for cursor coordinate transformation
            captureMode = "display"
            displayScaleFactor = CGFloat(attributes.scale)
            captureOffset = display.frame.origin  // Display offset on screen

            fputs("[Swift] Display mode: displayScaleFactor = \(displayScaleFactor)\n", stderr)

            configuration.width = Int(display.frame.width * attributes.scale)
            configuration.height = Int(display.frame.height * attributes.scale)
            captureSize = CGSize(
                width: max(1.0, CGFloat(configuration.width)),
                height: max(1.0, CGFloat(configuration.height))
            )
            return SCContentFilter(display: display, excludingWindows: excludedWindows)

        case .window:
            guard
                let windowIdString = payload.windowId,
                let windowId = UInt32(windowIdString),
                let window = content.windows.first(where: { $0.windowID == windowId })
            else {
                throw ScreenCaptureError.windowNotFound
            }
            let scale = ScreenCaptureCoordinator.scale(for: window, content: content)

            // Save parameters for cursor coordinate transformation
            captureMode = "window"
            displayScaleFactor = CGFloat(scale)
            captureOffset = window.frame.origin  // Window offset on screen

            configuration.width = Int(window.frame.width * scale)
            configuration.height = Int(window.frame.height * scale)
            captureSize = CGSize(
                width: max(1.0, CGFloat(configuration.width)),
                height: max(1.0, CGFloat(configuration.height))
            )
            return SCContentFilter(desktopIndependentWindow: window)

        case .region:
            guard let region = payload.region else {
                throw ScreenCaptureError.invalidRegion
            }
            let rect = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
            let display = content.displays.first ?? {
                fatalError("No displays available")
            }()
            let excludedWindows = resolveExcludedWindows(from: content)
            let attributes = ScreenCaptureCoordinator.displayAttributes(for: display.displayID)

            // Save parameters for cursor coordinate transformation
            captureMode = "region"
            displayScaleFactor = CGFloat(attributes.scale)
            captureOffset = rect.origin  // Region offset

            configuration.sourceRect = rect
            configuration.width = Int(rect.width * attributes.scale)
            configuration.height = Int(rect.height * attributes.scale)
            captureSize = CGSize(
                width: max(1.0, CGFloat(configuration.width)),
                height: max(1.0, CGFloat(configuration.height))
            )
            return SCContentFilter(display: display, excludingWindows: excludedWindows)
        }
    }

    private func resolveExcludedWindows(from content: SCShareableContent) -> [SCWindow] {
        content.windows.filter { window in
            if let excludedWindowId, window.windowID == excludedWindowId {
                return true
            }
            if isWindowExcludedByTitle(window.title) {
                return true
            }
            return false
        }
    }

    private func setupCameraAssetWriter(url: URL) throws {
        cameraAssetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // Use configured camera dimensions
        let width = self.cameraWidth
        let height = self.cameraHeight

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: NSNumber(value: width),
                kCVPixelBufferHeightKey as String: NSNumber(value: height)
            ]
        )

        if cameraAssetWriter?.canAdd(videoInput) == true {
            cameraAssetWriter?.add(videoInput)
            cameraPixelBufferAdaptor = adaptor
            self.cameraVideoInput = videoInput
        }

        cameraAssetWriter?.startWriting()
        cameraSessionStarted = false
        cameraFirstFrameTime = nil

    }

    private func setupAssetWriter(url: URL, configuration: SCStreamConfiguration, captureAudio: Bool) throws {
        assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let targetWidth: Int
        let targetHeight: Int
        if configuration.width > 0, configuration.height > 0 {
            targetWidth = configuration.width
            targetHeight = configuration.height
        } else {
            targetWidth = 1920
            targetHeight = 1080
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: targetWidth,
            AVVideoHeightKey: targetHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: NSNumber(value: targetWidth),
                kCVPixelBufferHeightKey as String: NSNumber(value: targetHeight)
            ]
        )

        if assetWriter?.canAdd(videoInput) == true {
            assetWriter?.add(videoInput)
            pixelBufferAdaptor = adaptor
            self.videoInput = videoInput
        }

        if captureAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 256000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true

            if assetWriter?.canAdd(audioInput) == true {
                assetWriter?.add(audioInput)
                self.audioInput = audioInput
            }
        }

        assetWriter?.startWriting()
        // Session will be started with the first frame's timestamp in handleVideoSampleBuffer
        sessionStarted = false
        firstFrameTime = nil

        if captureAudio {
        }
    }

    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        autoreleasepool {
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

            let baseImage = CIImage(cvPixelBuffer: pixelBuffer)
            // Camera is NO longer overlaid on main video during recording
            // Composition will be done during export
            let finalImage: CIImage = baseImage

            ciContext.render(finalImage, to: pixelBuffer, bounds: finalImage.extent, colorSpace: rgbColorSpace)
            latestVideoImage = ciContext.createCGImage(finalImage, from: finalImage.extent)
        }

        guard let videoInput, videoInput.isReadyForMoreMediaData else {
            return
        }

        writerQueue.async { [weak self] in
            guard
                let self,
                let adaptor = self.pixelBufferAdaptor,
                let writer = self.assetWriter
            else { return }

            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Start the session with the timestamp of the first frame
            if !self.sessionStarted {
                writer.startSession(atSourceTime: time)
                self.sessionStarted = true
                self.firstFrameTime = time
                // Store media time for cursor event synchronization
                self.recordingStartMediaTime = CACurrentMediaTime()
            }

            guard writer.status == .writing else {
                return
            }

            if !adaptor.append(pixelBuffer, withPresentationTime: time) {
            }
        }
    }

    private func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let audioInput, audioInput.isReadyForMoreMediaData else {
            if audioInput == nil {
            }
            return
        }
        writerQueue.async { [weak self] in
            guard
                let self,
                let writer = self.assetWriter
            else { return }

            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Start the session with the timestamp of the first sample (audio or video)
            if !self.sessionStarted {
                writer.startSession(atSourceTime: time)
                self.sessionStarted = true
                self.firstFrameTime = time
                // Store media time for cursor event synchronization
                self.recordingStartMediaTime = CACurrentMediaTime()
            }

            guard writer.status == .writing else {
                return
            }

            if !audioInput.append(sampleBuffer) {
            }
        }
    }
}

extension ScreenCaptureCoordinator {
    private static func displayAttributes(for displayID: CGDirectDisplayID) -> (name: String?, scale: Double) {
        var attributes: (String?, Double) = (nil, 1.0)
        let work = {
            if let screen = NSScreen.screens.first(where: { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                    return false
                }
                return number == displayID
            }) {
                attributes = (screen.localizedName, Double(screen.backingScaleFactor))
            }
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }

        return attributes
    }

    private static func microphoneDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    private static func scale(for window: SCWindow, content: SCShareableContent) -> Double {
        if let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) {
            return displayAttributes(for: display.displayID).scale
        }
        if let display = content.displays.first {
            return displayAttributes(for: display.displayID).scale
        }
        return 1.0
    }
}

extension ScreenCaptureCoordinator {
    enum ScreenCaptureError: LocalizedError {
        case shareableContentUnavailable
        case sessionAlreadyRunning
        case sessionNotRunning
        case displayNotFound
        case windowNotFound
        case invalidRegion
        case outputUnavailable

        var errorDescription: String? {
            switch self {
            case .shareableContentUnavailable:
                return "Failed to get device list."
            case .sessionAlreadyRunning:
                return "Session already running."
            case .sessionNotRunning:
                return "Session not running."
            case .displayNotFound:
                return "Display not found."
            case .windowNotFound:
                return "Window not found."
            case .invalidRegion:
                return "Invalid capture region."
            case .outputUnavailable:
                return "No recording file."
            }
        }
    }

    // MARK: - Event Monitoring

    private func startEventMonitoring() {

        // Create event tap for mouse tracking
        let eventMask = (1 << CGEventType.mouseMoved.rawValue) |
                        (1 << CGEventType.leftMouseDown.rawValue) |
                        (1 << CGEventType.leftMouseUp.rawValue) |
                        (1 << CGEventType.leftMouseDragged.rawValue) |
                        (1 << CGEventType.rightMouseDown.rawValue) |
                        (1 << CGEventType.rightMouseUp.rawValue) |
                        (1 << CGEventType.rightMouseDragged.rawValue) |
                        (1 << CGEventType.otherMouseDown.rawValue) |
                        (1 << CGEventType.otherMouseUp.rawValue) |
                        (1 << CGEventType.otherMouseDragged.rawValue) |
                        (1 << CGEventType.scrollWheel.rawValue) |
                        (1 << CGEventType.keyDown.rawValue)

        // Use cghidEventTap for better event capture (requires Accessibility permission)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                if let coordinator = Unmanaged<ScreenCaptureCoordinator>.fromOpaque(refcon!).takeUnretainedValue() as ScreenCaptureCoordinator? {
                    coordinator.handleCGEvent(type: type, event: event)
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        eventTap = tap

        // Add to MAIN run loop (not current!)
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

    }

    private func stopEventMonitoring() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    private func startCursorPolling() {
        // Poll cursor position every 16ms (60 fps) synchronized with video framerate
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            self?.pollCursorPosition()
        }
        timer.resume()
        cursorPollTimer = timer
    }

    private func stopCursorPolling() {
        cursorPollTimer?.cancel()
        cursorPollTimer = nil
    }

    private func pollCursorPosition() {
        // Get current cursor position
        let location = CGEvent(source: nil)?.location ?? .zero

        // Only record if position changed
        guard location != lastCursorPosition else { return }
        lastCursorPosition = location

        // Transform global coordinates to local capture coordinates
        let relativeX = location.x - captureOffset.x
        let relativeY = location.y - captureOffset.y

        let scaledX = relativeX * displayScaleFactor
        let scaledY = relativeY * displayScaleFactor

        let width = captureSize.width > 0 ? captureSize.width : 1.0
        let height = captureSize.height > 0 ? captureSize.height : 1.0
        let normalizedX = max(0.0, min(1.0, Double(scaledX / width)))
        let normalizedY = max(0.0, min(1.0, Double(scaledY / height)))

        // Calculate timestamp using CACurrentMediaTime for stable sync
        guard recordingStartMediaTime > 0 else {
            // Video hasn't started yet - don't record
            return
        }
        let t = CACurrentMediaTime() - recordingStartMediaTime

        // Get cursor type
        let cursor = getCurrentCursorType()

        // Record cursor move event
        recordMouseEvent([
            "type": "move",
            "x": normalizedX,
            "y": normalizedY,
            "t": t,
            "cursor": cursor.value
        ])
    }

    private func mainThreadValue<T>(_ block: () -> T) -> T {
        if Thread.isMainThread {
            return block()
        }
        var result: T!
        DispatchQueue.main.sync {
            result = block()
        }
        return result
    }

    private func currentSystemCursorType() -> CursorKind? {
        if #available(macOS 12.0, *) {
            return mainThreadValue {
                guard let systemCursor = NSCursor.currentSystem else {
                    return nil
                }
                return cursorType(from: systemCursor)
            }
        }
        return nil
    }

    private func currentMouseLocation() -> CGPoint {
        mainThreadValue {
            NSEvent.mouseLocation
        }
    }

    private func mainScreenHeight() -> CGFloat? {
        mainThreadValue {
            NSScreen.main?.frame.height
        }
    }

    private func accessibilityElement(at point: CGPoint) -> AXUIElement? {
        mainThreadValue {
            let systemWideElement = AXUIElementCreateSystemWide()

            var mutablePoint = point
            if let value = AXValueCreate(.cgPoint, &mutablePoint) {
                var hitTestResult: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    systemWideElement,
                    axHitTestAttribute,
                    value,
                    &hitTestResult
                ) == .success, let hitTestResult, CFGetTypeID(hitTestResult) == AXUIElementGetTypeID() {
                    return unsafeBitCast(hitTestResult, to: AXUIElement.self)
                }
            }

            var elementRef: AXUIElement?
            if AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &elementRef) == .success,
               let elementRef {
                return elementRef
            }

            return nil
        }
    }

    private func axString(_ attribute: CFString, element: AXUIElement) -> String? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
           let value = value {
            if CFGetTypeID(value) == CFStringGetTypeID() {
                return value as? String
            }
            if CFGetTypeID(value) == CFURLGetTypeID(),
               let url = value as? URL {
                return url.absoluteString
            }
        }
        return nil
    }

    private func axBool(_ attribute: CFString, element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
           let value = value {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return CFBooleanGetValue((value as! CFBoolean))
            }
            if CFGetTypeID(value) == CFNumberGetTypeID(),
               let number = value as? NSNumber {
                return number.boolValue
            }
        }
        return nil
    }

    private func axAttributeContains(_ attribute: CFString, element: AXUIElement, substring: String) -> Bool {
        guard let value = axString(attribute, element: element) else { return false }
        return value.lowercased().contains(substring)
    }

    private func axParent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
           let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        return nil
    }

    private func axChildren(of element: AXUIElement, limit: Int) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let value = value else {
            return []
        }

        let array = unsafeBitCast(value, to: CFArray.self)
        let count = min(limit, CFArrayGetCount(array))
        var children: [AXUIElement] = []
        children.reserveCapacity(count)
        for index in 0..<count {
            if let pointer = CFArrayGetValueAtIndex(array, index) {
                let cfValue = unsafeBitCast(pointer, to: CFTypeRef.self)
                if CFGetTypeID(cfValue) == AXUIElementGetTypeID() {
                    children.append(unsafeBitCast(pointer, to: AXUIElement.self))
                }
            }
        }
        return children
    }

    private func inferCursorType(from element: AXUIElement, depth: Int = 0) -> CursorKind? {
        if depth > 4 {
            return nil
        }

        if let editable = axBool(axEditableAttribute, element: element), editable {
            return .ibeam
        }

        if let role = axString(kAXRoleAttribute as CFString, element: element) {
            switch role {
            case "AXTextField", "AXTextArea", "AXStaticText", "AXTextAttachment":
                return .ibeam
            case "AXLink":
                return .pointer
            case "AXScrollBar", "AXScrollArea":
                return .arrow
            case "AXSplitter":
                return .ewResize
            case "AXGrowArea", "AXIncrementor":
                return .nwseResize
            default:
                if role.contains("Text") || role.contains("Search") {
                    return .ibeam
                }
                if role.contains("Link") {
                    return .pointer
                }
            }
        }

        if let subrole = axString(kAXSubroleAttribute as CFString, element: element) {
            switch subrole {
            case "AXTextLink":
                return .pointer
            case "AXSecureTextField":
                return .ibeam
            default:
                if subrole.contains("Text") {
                    return .ibeam
                }
                if subrole.contains("Link") {
                    return .pointer
                }
            }
        }

        if axAttributeContains(kAXDescriptionAttribute as CFString, element: element, substring: "text") ||
            axAttributeContains(kAXRoleDescriptionAttribute as CFString, element: element, substring: "text") {
            return .ibeam
        }

        if axAttributeContains(kAXDescriptionAttribute as CFString, element: element, substring: "link") ||
            axAttributeContains(kAXRoleDescriptionAttribute as CFString, element: element, substring: "link") {
            return .pointer
        }

        if axAttributeContains(kAXDescriptionAttribute as CFString, element: element, substring: "resize") ||
            axAttributeContains(kAXRoleDescriptionAttribute as CFString, element: element, substring: "resize") {
            if axAttributeContains(kAXDescriptionAttribute as CFString, element: element, substring: "horizontal") ||
                axAttributeContains(kAXRoleDescriptionAttribute as CFString, element: element, substring: "horizontal") {
                return .ewResize
            }
            if axAttributeContains(kAXDescriptionAttribute as CFString, element: element, substring: "vertical") ||
                axAttributeContains(kAXRoleDescriptionAttribute as CFString, element: element, substring: "vertical") {
                return .nsResize
            }
            return .nwseResize
        }

        if axAttributeContains(kAXURLAttribute as CFString, element: element, substring: "://") {
            return .pointer
        }

        if depth < 3 {
            for child in axChildren(of: element, limit: 3) {
                if let inferred = inferCursorType(from: child, depth: depth + 1) {
                    return inferred
                }
            }
        }

        return nil
    }

    private func cursorType(from cursor: NSCursor) -> CursorKind? {
        func matches(_ cursor: NSCursor, _ reference: NSCursor) -> Bool {
            if cursor === reference {
                return true
            }
            if cursor.isEqual(reference) {
                return true
            }
            if cursor.image === reference.image {
                return true
            }
            if cursor.image.isEqual(to: reference.image) {
                return true
            }
            if let name = cursor.image.name(), let refName = reference.image.name(), name == refName {
                return true
            }
            if cursor.hotSpot == reference.hotSpot,
               cursor.image.size == reference.image.size,
               let data = cursor.image.tiffRepresentation,
               let refData = reference.image.tiffRepresentation,
               data == refData {
                return true
            }
            return false
        }

        let mappings: [(NSCursor, CursorKind)] = [
            (NSCursor.arrow, .arrow),
            (NSCursor.iBeam, .ibeam),
            (NSCursor.pointingHand, .pointer),
            (NSCursor.crosshair, .crosshair),
            (NSCursor.openHand, .openHand),
            (NSCursor.closedHand, .closedHand),
            (NSCursor.resizeLeft, .ewResize),
            (NSCursor.resizeRight, .ewResize),
            (NSCursor.resizeLeftRight, .ewResize),
            (NSCursor.resizeUp, .nsResize),
            (NSCursor.resizeDown, .nsResize),
            (NSCursor.resizeUpDown, .nsResize)
        ]

        for (reference, value) in mappings {
            if matches(cursor, reference) {
                return value
            }
        }

        if cursor === NSCursor.operationNotAllowed || cursor.isEqual(NSCursor.operationNotAllowed) {
            return .notAllowed
        }

        if #available(macOS 10.13, *) {
            if matches(cursor, NSCursor.dragCopy) {
                return .copy
            }
            if matches(cursor, NSCursor.dragLink) {
                return .alias
            }
            if matches(cursor, NSCursor.contextualMenu) {
                return .contextMenu
            }
        }

        if #available(macOS 15.0, *) {
            if matches(cursor, NSCursor.zoomIn) {
                return .zoomIn
            }
            if matches(cursor, NSCursor.zoomOut) {
                return .zoomOut
            }
            if matches(cursor, NSCursor.columnResize) {
                return .ewResize
            }
            if matches(cursor, NSCursor.rowResize) {
                return .nsResize
            }
        }

        if let name = cursor.image.name()?.lowercased() {
            if name.contains("ibeam") || name.contains("text") {
                return .ibeam
            }
            if name.contains("point") || name.contains("link") || name.contains("hand") {
                return .pointer
            }
            if name.contains("resize") || name.contains("drag") {
                if name.contains("horiz") || name.contains("left") || name.contains("right") {
                    return .ewResize
                }
                if name.contains("vert") || name.contains("up") || name.contains("down") {
                    return .nsResize
                }
                if name.contains("diag") || name.contains("corner") {
                    return .nwseResize
                }
            }
        }

        return nil
    }

    // Get current cursor type by examining the element under the cursor
    private func getCurrentCursorType() -> CursorKind {
        let systemCursorType = currentSystemCursorType()
        if let mapped = systemCursorType, mapped != .arrow {
            return mapped
        }

        // Get current mouse location
        let mouseLocation = currentMouseLocation()

        // Convert from screen coordinates (origin bottom-left) to CG coordinates (origin top-left)
        var cgPoint = CGPoint(x: mouseLocation.x, y: mouseLocation.y)
        if let screenHeight = mainScreenHeight() {
            cgPoint.y = screenHeight - mouseLocation.y
        }

        guard let element = accessibilityElement(at: cgPoint) else {
            return systemCursorType ?? .arrow
        }

        return mainThreadValue {
            var currentElement: AXUIElement? = element
            var depth = 0
            while let target = currentElement, depth < 6 {
                if let inferred = inferCursorType(from: target) {
                    // When the system reports an arrow cursor, avoid overriding it with pointer/text heuristics.
                    if systemCursorType == .arrow && (inferred == .pointer || inferred == .ibeam) {
                        // Keep walking up the hierarchy in case a parent implies a stronger cursor type.
                        currentElement = axParent(of: target)
                        depth += 1
                        continue
                    }
                    return inferred
                }
                currentElement = axParent(of: target)
                depth += 1
            }

            return systemCursorType ?? .arrow
        }
    }

    private func seconds(fromEventTimestamp timestamp: CGEventTimestamp) -> CFTimeInterval {
        let info = ScreenCaptureCoordinator.timebaseInfo
        let nanos = Double(timestamp) * Double(info.numer) / Double(info.denom)
        return nanos / ScreenCaptureCoordinator.nanosecondsPerSecond
    }

    private func recordMouseEvent(_ event: [String: Any]) {
        mouseEventsQueue.async { [weak self] in
            self?.mouseEvents.append(event)
        }
    }

    private func resetMouseEventsStorage() {
        mouseEventsQueue.sync {
            mouseEvents.removeAll(keepingCapacity: false)
        }
    }

    private func snapshotMouseEvents() -> [[String: Any]] {
        mouseEventsQueue.sync {
            mouseEvents
        }
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) {
        let location = event.location

        // Transform global coordinates to local capture coordinates
        // 1. Subtract offset (for window/region)
        let relativeX = location.x - captureOffset.x
        let relativeY = location.y - captureOffset.y

        // 2. Multiply by scale factor (for physical pixels)
        let scaledX = relativeX * displayScaleFactor
        let scaledY = relativeY * displayScaleFactor

        let width = captureSize.width > 0 ? captureSize.width : 1.0
        let height = captureSize.height > 0 ? captureSize.height : 1.0
        let normalizedX = max(0.0, min(1.0, Double(scaledX / width)))
        let normalizedY = max(0.0, min(1.0, Double(scaledY / height)))

        // Calculate timestamp using CGEvent host-time for tighter sync with video frames
        guard recordingStartMediaTime > 0 else {
            // Video hasn't started yet - don't record cursor events
            return
        }
        let currentMediaTime = CACurrentMediaTime()
        let eventTimeSeconds = seconds(fromEventTimestamp: event.timestamp)

        if recordingStartEventTime == nil {
            let elapsedSinceStart = currentMediaTime - recordingStartMediaTime
            recordingStartEventTime = eventTimeSeconds - elapsedSinceStart
        }

        guard let eventStart = recordingStartEventTime else {
            return
        }

        let t = eventTimeSeconds - eventStart

        // Get cursor type
        let cursor = getCurrentCursorType()

        // Send cursor update if it changed (throttle updates)
        if cursor.value != lastSentCursorType {
            lastSentCursorType = cursor.value
            onCursorUpdate?(cursor.value)
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            recordMouseEvent([
                "type": "move",
                "x": normalizedX,
                "y": normalizedY,
                "t": t,
                "cursor": cursor.value
            ])

        case .leftMouseDown:
            recordMouseEvent([
                "type": "down",
                "x": normalizedX,
                "y": normalizedY,
                "t": t,
                "button": "left",
                "cursor": cursor.value
            ])

        case .leftMouseUp:
            recordMouseEvent([
                "type": "up",
                "x": normalizedX,
                "y": normalizedY,
                "t": t,
                "button": "left"
            ])

        case .rightMouseDown:
            recordMouseEvent([
                "type": "down",
                "x": normalizedX,
                "y": normalizedY,
                "t": t,
                "button": "right",
                "cursor": cursor.value
            ])

        case .rightMouseUp:
            recordMouseEvent([
                "type": "up",
                "x": normalizedX,
                "y": normalizedY,
                "t": t,
                "button": "right"
            ])

        case .otherMouseDown:
            recordMouseEvent([
                "type": "down",
                "x": normalizedX,
                "y": normalizedY,
                "t": t,
                "button": "middle",
                "cursor": cursor.value
            ])

        case .otherMouseUp:
            recordMouseEvent([
                "type": "up",
                "x": normalizedX,
                "y": normalizedY,
                "t": t,
                "button": "middle"
            ])

        case .scrollWheel:
            // Get scroll delta
            let delta = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            recordMouseEvent([
                "type": "wheel",
                "x": normalizedX,
                "y": normalizedY,
                "t": t,
                "delta": delta
            ])

        case .keyDown:
            // Get pressed key (track but don't save)
            if let nsEvent = NSEvent(cgEvent: event),
               let characters = nsEvent.characters {
                keyboardEvents.append([
                    "key": characters,
                    "keyCode": nsEvent.keyCode
                ])
            }

        default:
            break
        }
    }

    // MARK: - Recording Metadata Helpers

    private func calculateRecordingDuration() -> Double {
        guard let startTime = sessionStartTime else {
            return 0.0
        }
        return CFAbsoluteTimeGetCurrent() - startTime
    }

    private func convertEventsToJSON(_ events: [[String: Any]]) throws -> [JSONValue] {
        let data = try JSONSerialization.data(withJSONObject: events, options: [])
        let decoded = try JSONDecoder().decode([JSONValue].self, from: data)
        return decoded
    }
}

final class StreamSampleHandler: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var coordinator: ScreenCaptureCoordinator?
    private var isValid = true

    init(coordinator: ScreenCaptureCoordinator) {
        self.coordinator = coordinator
    }

    func invalidate() {
        isValid = false
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isValid else { return }
        coordinator?.handleSampleBuffer(sampleBuffer, outputType: type)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
    }
}

private extension CIContext {
    func createCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(origin: .zero, size: ciImage.extent.size)
        return createCGImage(ciImage, from: rect)
    }
}

private extension CGImage {
    func pngBase64(ciContext: CIContext) -> String? {
        // Using JPEG instead of PNG for much faster encoding (3-5x speedup)
        // Quality of 0.6 provides good balance between speed and visual quality
        guard let data = NSBitmapImageRep(cgImage: self).representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else {
            return nil
        }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }
}
