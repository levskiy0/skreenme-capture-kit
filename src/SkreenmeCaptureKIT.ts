import { EventEmitter } from 'events';
import { spawn, ChildProcess } from 'child_process';
import * as path from 'path';
import type {
  SourcesData,
  StartSessionParams,
  StartSessionResponse,
  StopSessionResponse,
  ConfigureCameraParams,
  ConfigureAudioParams,
  PermissionsStatus,
  SkreenmeCaptureKITOptions,
  PreviewResponse,
  SkreenmeCaptureKITEvents
} from './types';

interface PendingCommand {
  resolve: (value: any) => void;
  reject: (error: Error) => void;
  timeoutHandle?: NodeJS.Timeout;
}

/**
 * SkreenmeCaptureKIT - Powerful library for screen recording via Swift backend
 *
 * Events:
 * - 'ready': Emitted when Swift process is ready
 * - 'error': Emitted on errors (err)
 * - 'process-exit': Emitted when Swift process exits (code)
 * - 'session-started': Emitted when recording session starts (data)
 * - 'session-stopped': Emitted when recording session stops (data)
 * - 'stderr': Emitted for Swift stderr output (data)
 * - 'cursor-update': Emitted when cursor position updates
 *
 * @example
 * ```typescript
 * const capturer = new SkreenmeCaptureKIT();
 *
 * capturer.on('ready', () => {
 *   console.log('Capturer ready');
 * });
 *
 * capturer.on('session-started', (data) => {
 *   console.log('Recording started:', data);
 * });
 *
 * await capturer.initialize();
 * const sources = await capturer.listSources();
 * await capturer.startSession({ mode: 'display', displayId: sources.displays[0].id });
 * ```
 */
export default class SkreenmeCaptureKIT extends EventEmitter {
  private options: Required<SkreenmeCaptureKITOptions>;
  private process: ChildProcess | null = null;
  private commandId = 1;
  private pendingCommands = new Map<string, PendingCommand>();
  private buffer = '';
  private isReady = false;

  constructor(options: SkreenmeCaptureKITOptions = {}) {
    super();

    this.options = {
      binaryPath: options.binaryPath || this._getDefaultBinaryPath(),
      timeout: options.timeout || 30000
    };
  }

  /**
   * Get default Swift binary path based on environment
   */
  private _getDefaultBinaryPath(): string {
    const isDev = process.env.NODE_ENV === 'development';
    const buildType = isDev ? 'debug' : 'release';

    // Try to find the binary in multiple locations
    const possiblePaths = [
      // When installed as npm package
      path.join(__dirname, `../bin/SkreenmeCaptureKIT`),
      // When running from source
      path.join(__dirname, `../src/native/.build/${buildType}/SkreenmeCaptureKIT`),
      // Legacy path for compatibility
      path.join(__dirname, `../../native/.build/${buildType}/SkreenmeCaptureKIT`)
    ];

    return possiblePaths[0];
  }

  /**
   * Initialize and start the Swift process
   */
  async initialize(): Promise<void> {
    if (this.process) {
      throw new Error('SkreenmeCaptureKIT already initialized');
    }

    return new Promise((resolve, reject) => {
      try {
        console.log('[SkreenmeCaptureKIT] Starting Swift process:', this.options.binaryPath);

        this.process = spawn(this.options.binaryPath, [], {
          stdio: ['pipe', 'pipe', 'pipe']
        });

        this._setupProcessHandlers();

        this.isReady = true;
        this.emit('ready');
        resolve();
      } catch (err) {
        const error = err instanceof Error ? err : new Error(String(err));
        this.emit('error', error);
        reject(error);
      }
    });
  }

  /**
   * Setup process event handlers
   */
  private _setupProcessHandlers(): void {
    if (!this.process) return;

    this.process.stdout?.on('data', (data: Buffer) => {
      this.buffer += data.toString();

      // Process JSON responses line by line
      const lines = this.buffer.split('\n');
      this.buffer = lines.pop() || '';

      for (const line of lines) {
        if (line.trim()) {
          try {
            const response = JSON.parse(line);
            this._handleResponse(response);
          } catch (err) {
            console.error('[SkreenmeCaptureKIT] Failed to parse response:', line, err);
            this.emit('error', new Error(`Failed to parse response: ${err instanceof Error ? err.message : String(err)}`));
          }
        }
      }
    });

    this.process.stderr?.on('data', (data: Buffer) => {
      const message = data.toString();
      console.error('[SkreenmeCaptureKIT] stderr:', message);
      this.emit('stderr', message);
    });

    this.process.on('close', (code: number | null) => {
      console.log('[SkreenmeCaptureKIT] Process exited with code:', code);
      this.isReady = false;
      this.process = null;

      // Reject all pending commands
      for (const [id, { reject, timeoutHandle }] of this.pendingCommands.entries()) {
        if (timeoutHandle) clearTimeout(timeoutHandle);
        reject(new Error('Swift process terminated'));
      }
      this.pendingCommands.clear();

      this.emit('process-exit', code);
    });

    this.process.on('error', (err: Error) => {
      console.error('[SkreenmeCaptureKIT] Process error:', err);
      this.emit('error', err);
    });
  }

  /**
   * Handle response from Swift process
   */
  private _handleResponse(response: any): void {
    console.log('[SkreenmeCaptureKIT] Response:', response);

    const { id, success, payload, error, event } = response;

    // Handle events from Swift (like cursor updates)
    if (event === 'cursorUpdate' && payload?.cursor) {
      this.emit('cursor-update', payload.cursor);
      return;
    }

    if (this.pendingCommands.has(id)) {
      const command = this.pendingCommands.get(id)!;
      const { resolve, reject, timeoutHandle } = command;

      if (timeoutHandle) clearTimeout(timeoutHandle);
      this.pendingCommands.delete(id);

      if (!success || error) {
        reject(new Error(error || 'Unknown error'));
      } else {
        resolve(payload || {});
      }
    }
  }

  /**
   * Send command to Swift process
   */
  async sendCommand<T = any>(method: string, params: any = null, options: { timeout?: number } = {}): Promise<T> {
    if (!this.process || !this.isReady) {
      throw new Error('SkreenmeCaptureKIT not initialized');
    }

    return new Promise((resolve, reject) => {
      const id = String(this.commandId++);
      const command = {
        id,
        command: method,
        payload: params
      };

      const timeoutMs = options.timeout || this.options.timeout;
      const timeoutHandle = setTimeout(() => {
        if (this.pendingCommands.has(id)) {
          this.pendingCommands.delete(id);
          reject(new Error(`Command timeout: ${method}`));
        }
      }, timeoutMs);

      this.pendingCommands.set(id, { resolve, reject, timeoutHandle });

      const commandStr = JSON.stringify(command) + '\n';
      this.process!.stdin!.write(commandStr);
    });
  }

  /**
   * List available sources (displays, windows, cameras, audio devices)
   */
  async listSources(): Promise<SourcesData> {
    return await this.sendCommand<SourcesData>('listSources');
  }

  /**
   * Start recording session
   */
  async startSession(params: StartSessionParams): Promise<StartSessionResponse> {
    const result = await this.sendCommand<StartSessionResponse>('startSession', params);
    this.emit('session-started', result);
    return result;
  }

  /**
   * Stop recording session
   * @param sessionId - Session ID to stop
   */
  async stopSession(sessionId: string): Promise<StopSessionResponse> {
    if (!sessionId) {
      throw new Error('Session ID is required');
    }
    const result = await this.sendCommand<StopSessionResponse>('stopSession', { sessionId });
    this.emit('session-stopped', result);
    return result;
  }

  /**
   * Check permissions
   */
  async checkPermissions(): Promise<PermissionsStatus> {
    return await this.sendCommand<PermissionsStatus>('checkPermissions');
  }

  /**
   * Request permissions
   */
  async requestPermissions(): Promise<PermissionsStatus> {
    return await this.sendCommand<PermissionsStatus>('requestPermissions');
  }

  /**
   * Configure camera
   */
  async configureCamera(params: ConfigureCameraParams): Promise<{ success: boolean }> {
    return await this.sendCommand<{ success: boolean }>('configureCamera', params);
  }

  /**
   * Configure audio
   */
  async configureAudio(params: ConfigureAudioParams): Promise<{ success: boolean }> {
    return await this.sendCommand<{ success: boolean }>('configureAudio', params);
  }

  /**
   * Shutdown the Swift process
   */
  async shutdown(): Promise<void> {
    if (!this.process) {
      return;
    }

    console.log('[SkreenmeCaptureKIT] Shutting down...');

    // Kill process
    this.process.kill('SIGTERM');

    // Wait a bit for graceful shutdown
    await new Promise(resolve => setTimeout(resolve, 1000));

    // Force kill if still running
    if (this.process) {
      this.process.kill('SIGKILL');
    }

    this.isReady = false;
    this.process = null;
  }

  /**
   * Check if capturer is ready
   */
  get ready(): boolean {
    return this.isReady && this.process !== null;
  }

  // EventEmitter type-safe overrides
  on<K extends keyof SkreenmeCaptureKITEvents>(event: K, listener: SkreenmeCaptureKITEvents[K]): this {
    return super.on(event, listener as any);
  }

  once<K extends keyof SkreenmeCaptureKITEvents>(event: K, listener: SkreenmeCaptureKITEvents[K]): this {
    return super.once(event, listener as any);
  }

  off<K extends keyof SkreenmeCaptureKITEvents>(event: K, listener: SkreenmeCaptureKITEvents[K]): this {
    return super.off(event, listener as any);
  }

  emit<K extends keyof SkreenmeCaptureKITEvents>(event: K, ...args: Parameters<SkreenmeCaptureKITEvents[K]>): boolean {
    return super.emit(event, ...args);
  }
}
