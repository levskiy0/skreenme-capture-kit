import Foundation

final class CommandServer {
    private let coordinator = ScreenCaptureCoordinator()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let queue = DispatchQueue(label: "skreen.record.command.queue")
    private var readSource: DispatchSourceRead?
    private var buffer = Data()

    init() {
        encoder.outputFormatting = [.withoutEscapingSlashes]

        // Set coordinator delegate for cursor updates
        coordinator.onCursorUpdate = { [weak self] cursorType in
            self?.sendCursorUpdate(cursorType: cursorType)
        }
    }

    func run() {
        let handle = FileHandle.standardInput
        let descriptor = handle.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                self.readSource?.cancel()
                return
            }
            self.buffer.append(chunk)
            self.consumeBuffer()
        }
        source.setCancelHandler {
            exit(EXIT_SUCCESS)
        }
        readSource = source
        source.resume()
    }

    private func consumeBuffer() {
        while let range = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0...range.lowerBound)
            guard !lineData.isEmpty else { continue }
            process(line: lineData)
        }
    }

    private func process(line: Data) {
        do {
            let command = try decoder.decode(CommandEnvelope.self, from: line)
            handleCommand(command)
        } catch {
            let message = ResponseEnvelope<EmptyPayload>(
                id: "unknown",
                success: false,
                payload: nil,
                error: "Invalid command: \(error.localizedDescription)"
            )
            emit(message)
        }
    }

    private func handleCommand(_ envelope: CommandEnvelope) {
        switch envelope.command {
        case "listSources":
            Task {
                do {
                    let payload = try await coordinator.listSources()
                    respond(id: envelope.id, payload: payload)
                } catch {
                    respond(id: envelope.id, error: error)
                }
            }

        case "startSession":
            Task {
                do {
                    guard let payloadValue = envelope.payload else {
                        throw CommandError.missingPayload
                    }
                    let payload = try payloadValue.decode(StartSessionPayload.self)
                    coordinator.setExcludedWindow(id: payload.excludedWindowId)
                    coordinator.setExcludedWindow(title: payload.excludedWindowTitle)
                    let response = try await coordinator.startSession(payload: payload)
                    respond(id: envelope.id, payload: response)
                } catch {
                    respond(id: envelope.id, error: error)
                }
            }

        case "stopSession":
            Task {
                do {
                    guard let payloadValue = envelope.payload else {
                        throw CommandError.missingPayload
                    }
                    let payload = try payloadValue.decode(StopSessionPayload.self)
                    let response = try await coordinator.stopSession(sessionId: payload.sessionId)
                    respond(id: envelope.id, payload: response)
                } catch {
                    respond(id: envelope.id, error: error)
                }
            }

        case "ping":
            respond(id: envelope.id, payload: ["pong"])

        case "configureCamera":
            Task {
                do {
                    let payload = try envelope.payload?.decode(ConfigureCameraPayload.self)
                    try coordinator.configureCamera(deviceId: payload?.cameraSourceId)
                    respond(id: envelope.id, payload: EmptyPayload())
                } catch {
                    respond(id: envelope.id, error: error)
                }
            }

        case "configureAudio":
            Task {
                do {
                    let payload = try envelope.payload?.decode(ConfigureAudioPayload.self)
                    try coordinator.configureAudio(deviceId: payload?.audioSourceId)
                    respond(id: envelope.id, payload: EmptyPayload())
                } catch {
                    respond(id: envelope.id, error: error)
                }
            }

        case "checkPermissions":
            let response = coordinator.checkPermissions()
            respond(id: envelope.id, payload: response)

        case "requestPermissions":
            Task {
                let response = await coordinator.requestPermissions()
                respond(id: envelope.id, payload: response)
            }

        default:
            respond(id: envelope.id, error: CommandError.unknownCommand(envelope.command))
        }
    }

    private func respond<Payload: Encodable>(id: String, payload: Payload) {
        let response = ResponseEnvelope(id: id, success: true, payload: payload, error: nil)
        emit(response)
    }

    private func respond(id: String, error: Error) {
        let response = ResponseEnvelope<EmptyPayload>(
            id: id,
            success: false,
            payload: nil,
            error: error.localizedDescription
        )
        emit(response)
    }

    private func emit<Payload: Encodable>(_ response: ResponseEnvelope<Payload>) {
        do {
            let data = try encoder.encode(response)
            if let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString, terminator: "\n")
                fflush(stdout)
            }
        } catch {
        }
    }

    private func sendCursorUpdate(cursorType: String) {
        // Send cursor update event
        let event: [String: Any] = [
            "event": "cursorUpdate",
            "payload": [
                "cursor": cursorType
            ]
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: event, options: [])
            if let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString, terminator: "\n")
                fflush(stdout)
            }
        } catch {
        }
    }
}

extension CommandServer {
    enum CommandError: LocalizedError {
        case missingPayload
        case unknownCommand(String)

        var errorDescription: String? {
            switch self {
            case .missingPayload:
                return "Command payload missing."
            case .unknownCommand(let command):
                return "Unknown command \(command)."
            }
        }
    }
}
