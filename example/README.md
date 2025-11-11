# SkreenmeCaptureKIT - Electron Example

This is a complete Electron application demonstrating how to use `@levskiy0/skreenme-capture-kit` for screen and camera recording.

## Features

- 🖥️ **Screen Recording** - Capture any display or window
- 📹 **Camera Recording** - Record camera with screen (optional)
- 🎤 **Audio Recording** - Capture microphone audio
- 👁️ **Live Camera Preview** - Preview window that's excluded from recording
- ⚙️ **Recording Settings** - Customize frame rate, cursor visibility, camera format
- 📁 **Auto-save** - Recordings saved to user data directory
- 🎨 **Modern UI** - Clean, responsive interface

## Installation

```bash
cd example
npm install
```

## Usage

### Development Mode

```bash
npm run dev
```

This runs Electron in development mode with DevTools open.

### Production Mode

```bash
npm start
```

## How It Works

### 1. Main Window

The main window provides:
- Source selection (displays, cameras, audio devices)
- Recording controls (start/stop)
- Recording settings (FPS, cursor, camera format)
- Real-time console log
- Access to recordings folder

### 2. Camera Preview Window

A separate always-on-top window showing live camera feed:
- Can be moved and resized
- Excluded from screen recording
- Switch between multiple cameras
- Close anytime without affecting recording

### 3. Recording Flow

1. **Select Sources**: Choose display, camera (optional), and audio device (optional)
2. **Configure Settings**: Set frame rate, cursor visibility, camera format
3. **Open Preview** (optional): View camera feed in real-time
4. **Start Recording**: Click "Start Recording" button
5. **Record**: Interface shows recording timer and status
6. **Stop Recording**: Click "Stop Recording" when done
7. **Access Files**: Recordings saved to user data folder

### 4. File Structure

```
example/
├── package.json
├── README.md
└── src/
    ├── main.js              # Electron main process
    ├── preload.js           # Main window preload script
    ├── index.html           # Main window UI
    ├── renderer.js          # Main window logic
    ├── preview.html         # Preview window UI
    ├── preview-preload.js   # Preview window preload script
    └── preview-renderer.js  # Preview window logic
```

## Key Features Explained

### Preview Window Exclusion

The preview window is configured to be excluded from screen recording:
```javascript
previewWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
previewWindow.setAlwaysOnTop(true, 'screen-saver');
```

### Recordings Directory

All recordings are automatically saved to:
```
~/Library/Application Support/skreenme-capture-kit-example/recordings/
```

You can open this folder directly from the app using the "Open Recordings Folder" button.

### Recording Settings

- **Frame Rate**: 30 or 60 FPS
- **Show Cursor**: Toggle cursor capture
- **Camera Format**: Square (1:1) or Wide (16:9)

### Event Handling

The app uses IPC (Inter-Process Communication) to communicate between:
- Main process (handles SkreenmeCaptureKIT)
- Renderer process (UI)
- Preview window (camera feed)

## Troubleshooting

### Camera Not Working

Make sure to grant camera permissions when prompted by macOS.

### Screen Recording Permission

On first use, macOS will ask for screen recording permission. Go to:
`System Preferences > Security & Privacy > Screen Recording`

### Microphone Permission

If using audio recording, grant microphone permission in:
`System Preferences > Security & Privacy > Microphone`

### Preview Window Not Showing

Try these steps:
1. Close the preview window
2. Click "Toggle Camera Preview" again
3. Check macOS camera permissions

## API Integration

The example shows how to:

1. **Initialize SkreenmeCaptureKIT**:
```javascript
const capturer = new SkreenmeCaptureKIT();
await capturer.initialize();
```

2. **List Available Sources**:
```javascript
const sources = await capturer.listSources();
// { displays, windows, cameras, audio }
```

3. **Start Recording Session**:
```javascript
const session = await capturer.startSession({
  mode: 'display',
  displayId: selectedDisplay.id,
  cameraSourceId: selectedCamera?.id,
  audioSourceId: selectedAudio?.id,
  frameRate: 30,
  showCursor: true,
  cameraFormat: 'square',
  outputPath: './recording.mp4'
});
```

4. **Stop Recording**:
```javascript
const result = await capturer.stopSession(sessionId);
// Returns: { recording, events }
```

## Development

To modify the example:

1. Edit UI in `src/index.html` and `src/preview.html`
2. Modify logic in `src/renderer.js` and `src/preview-renderer.js`
3. Update main process in `src/main.js`
4. Restart Electron to see changes

## License

MIT
