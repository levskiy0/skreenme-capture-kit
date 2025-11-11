import Foundation
import CoreGraphics

enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON element")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let encoder = JSONEncoder()
        let data = try encoder.encode(self)
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }
}

struct CommandEnvelope: Decodable {
    let id: String
    let command: String
    let payload: JSONValue?
}

struct ResponseEnvelope<Payload: Encodable>: Encodable {
    let id: String
    let success: Bool
    let payload: Payload?
    let error: String?

    init(id: String, success: Bool, payload: Payload? = nil, error: String? = nil) {
        self.id = id
        self.success = success
        self.payload = payload
        self.error = error
    }
}

struct EmptyPayload: Encodable {}

struct SourceListingPayload: Encodable {
    struct Display: Encodable {
        let id: String
        let name: String
        let frame: CGRect
        let scaleFactor: Double
    }

    struct Window: Encodable {
        let id: String
        let name: String
        let ownerName: String
        let frame: CGRect
    }

    struct AudioDevice: Encodable {
        let id: String
        let name: String
        let type: String
    }

    struct Camera: Encodable {
        let id: String
        let name: String
    }

    let displays: [Display]
    let windows: [Window]
    let audio: [AudioDevice]
    let cameras: [Camera]
}

struct StartSessionPayload: Decodable {
    enum Mode: String, Decodable {
        case display
        case window
        case region
    }

    enum CameraFormat: String, Decodable {
        case square
        case wide
    }

    struct Region: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    let mode: Mode
    let displayId: String?
    let windowId: String?
    let region: Region?
    let audioSourceId: String?
    let cameraSourceId: String?
    let cameraWidth: Int?
    let cameraHeight: Int?
    let cameraFormat: CameraFormat?
    let frameRate: Int?  // 30 or 60 FPS
    let outputPath: String?
    let excludedWindowId: UInt32?
    let excludedWindowTitle: [String]?
    let showCursor: Bool?
}

struct StopSessionPayload: Decodable {
    let sessionId: String
}

struct StartSessionResponse: Encodable {
    let sessionId: String
    let outputPath: String
}

struct RecordingSource: Encodable {
    struct Resolution: Encodable {
        let width: Double
        let height: Double
    }

    let file: String
    let size: Int64
    let resolution: Resolution
    let fps: Int
    let pixelDensity: Double
}

struct StopSessionResponse: Encodable {
    struct RecordingMetadata: Encodable {
        let status: String  // "completed" | "failed"
        let outputPath: String
        let duration: Double
        let screen: RecordingSource?
        let camera: RecordingSource?
    }

    let recording: RecordingMetadata
    let events: [JSONValue]
}

struct PreviewResponse: Encodable {
    let videoFrame: String?
    let cameraFrame: String?
}

struct ConfigureCameraPayload: Decodable {
    let cameraSourceId: String?
}

struct ConfigureAudioPayload: Decodable {
    let audioSourceId: String?
}

struct PermissionsResponse: Encodable {
    let screenRecording: Bool
    let camera: String  // "granted" | "denied" | "prompt" | "unknown"
    let microphone: String  // "granted" | "denied" | "prompt" | "unknown"
    let accessibility: Bool
}
