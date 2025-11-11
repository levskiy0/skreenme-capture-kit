// Source types
export type RecordingMode = 'display' | 'window' | 'region';

export interface Display {
  id: string;
  name: string;
  frame?: {
    x: number;
    y: number;
    width: number;
    height: number;
  };
  scaleFactor?: number;
}

export interface Window {
  id: string;
  name: string;
  ownerName: string;
  frame?: {
    x: number;
    y: number;
    width: number;
    height: number;
  };
}

export interface Camera {
  id: string;
  name: string;
}

export interface AudioDevice {
  id: string;
  name: string;
  type: string;
}

export interface SourcesData {
  displays: Display[];
  windows: Window[];
  cameras: Camera[];
  audio: AudioDevice[];
}

// Recording parameters
export interface RegionParams {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface StartSessionParams {
  mode: RecordingMode;
  displayId?: string;
  windowId?: string;
  region?: RegionParams;
  cameraSourceId?: string;
  audioSourceId?: string;
  cameraWidth?: number;  // Camera video width in pixels, defaults to 640
  cameraHeight?: number;  // Camera video height in pixels, defaults to 640 (square)
  cameraFormat?: 'wide' | 'square';  // Camera aspect ratio: 'square' (1:1) or 'wide' (16:9), defaults to 'square'
  frameRate?: number;  // Frame rate (FPS), 30 or 60, defaults to 30
  outputPath?: string;
  showCursor?: boolean;  // Whether to show cursor in video, defaults to true (captures actual visual cursor)
}

export interface StartSessionResponse {
  sessionId: string;
  outputPath: string;
}

export interface RecordingSource {
  file: string;
  size: number;
  resolution: {
    width: number;
    height: number;
  };
  fps: number;
}

export interface RecordingMetadata {
  status: 'completed' | 'failed';
  outputPath: string;
  duration: number;
  screen?: RecordingSource;
  camera?: RecordingSource;
}

export interface MouseEvent {
  type: 'move' | 'down' | 'up' | 'wheel';
  x: number;
  y: number;
  t: number;
  cursor?: string;
  button?: 'left' | 'right' | 'middle';
  delta?: number;
}

export interface StopSessionResponse {
  recording: RecordingMetadata;
  events: MouseEvent[];
}

// Camera parameters
export interface ConfigureCameraParams {
  cameraSourceId?: string;
}

export interface ConfigureAudioParams {
  audioSourceId?: string;
}

export interface PermissionsStatus {
  screenRecording: boolean;
  camera: string;  // "granted" | "denied" | "prompt" | "unknown"
  microphone: string;  // "granted" | "denied" | "prompt" | "unknown"
  accessibility: boolean;
}

export interface SkreenmeCaptureKITOptions {
  /**
   * Path to Swift binary. If not provided, uses default based on NODE_ENV
   */
  binaryPath?: string;

  /**
   * Default timeout for commands in milliseconds
   * @default 30000
   */
  timeout?: number;
}

export interface PreviewResponse {
  videoFrame?: string;
  cameraFrame?: string;
}

export interface SkreenmeCaptureKITEvents {
  /**
   * Emitted when Swift process is ready
   */
  ready: () => void;

  /**
   * Emitted on errors
   */
  error: (err: Error) => void;

  /**
   * Emitted when Swift process exits
   */
  'process-exit': (code: number | null) => void;

  /**
   * Emitted when recording session starts
   */
  'session-started': (data: StartSessionResponse) => void;

  /**
   * Emitted when recording session stops
   */
  'session-stopped': (data: StopSessionResponse) => void;

  /**
   * Emitted for Swift stderr output
   */
  stderr: (message: string) => void;

  /**
   * Emitted when cursor position updates
   */
  'cursor-update': (cursor: { x: number; y: number }) => void;
}
