const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
const fs = require('fs');
const SkreenmeCaptureKIT = require('@levskiy0/skreenme-capture-kit').default;

let mainWindow;
let previewWindow;
let capturer;
let currentSession = null;

const recordingsDir = path.join(__dirname, '..', 'videos');
if (!fs.existsSync(recordingsDir)) {
  fs.mkdirSync(recordingsDir, { recursive: true });
}
console.log('[Main] Recordings directory:', recordingsDir);

function createMainWindow() {
  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, 'preload.js')
    }
  });

  mainWindow.loadFile('src/index.html');

  if (process.env.NODE_ENV === 'development') {
    mainWindow.webContents.openDevTools();
  }

  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

function createPreviewWindow(cameraId = null) {
  if (previewWindow) {
    previewWindow.focus();
    if (cameraId) {
      previewWindow.webContents.send('update-camera', cameraId);
    }
    return;
  }

  previewWindow = new BrowserWindow({
    width: 480,
    height: 480,
    alwaysOnTop: true,
    frame: true,
    resizable: true,
    minimizable: true,
    closable: true,
    title: 'Camera Preview',
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, 'preview-preload.js')
    }
  });

  previewWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  previewWindow.setAlwaysOnTop(true, 'screen-saver');

  try {
    previewWindow.setContentProtection(true);
  } catch (err) {
    console.log('[Main] Content protection not supported:', err);
  }

  previewWindow.loadFile('src/preview.html');

  if (process.env.NODE_ENV === 'development') {
    previewWindow.webContents.openDevTools();
  }

  previewWindow.webContents.on('did-finish-load', () => {
    if (cameraId) {
      previewWindow.webContents.send('set-camera', cameraId);
    }
  });

  previewWindow.on('closed', () => {
    previewWindow = null;
    mainWindow?.webContents.send('preview-closed');
  });
}

async function initializeCapturer() {
  if (capturer) {
    return;
  }

  capturer = new SkreenmeCaptureKIT();

  capturer.on('ready', () => {
    console.log('[Main] Capturer ready');
    mainWindow?.webContents.send('capturer-ready');
  });

  capturer.on('error', (err) => {
    console.error('[Main] Capturer error:', err);
    mainWindow?.webContents.send('capturer-error', err.message);
  });

  capturer.on('session-started', (data) => {
    console.log('[Main] Session started:', data);
    mainWindow?.webContents.send('session-started', data);
  });

  capturer.on('session-stopped', (data) => {
    console.log('[Main] Session stopped:', data);
    currentSession = null;
    mainWindow?.webContents.send('session-stopped', data);
  });

  capturer.on('stderr', (message) => {
    console.log('[Main] Swift stderr:', message);
  });

  try {
    await capturer.initialize();
  } catch (err) {
    console.error('[Main] Failed to initialize capturer:', err);
    throw err;
  }
}

ipcMain.handle('list-sources', async () => {
  if (!capturer) {
    await initializeCapturer();
  }
  const sources = await capturer.listSources();
  console.log('[Main] Cameras from Swift:', JSON.stringify(sources.cameras, null, 2));
  return sources;
});

ipcMain.handle('check-permissions', async () => {
  if (!capturer) {
    await initializeCapturer();
  }
  return await capturer.checkPermissions();
});

ipcMain.handle('request-permissions', async () => {
  if (!capturer) {
    await initializeCapturer();
  }
  return await capturer.requestPermissions();
});

ipcMain.handle('start-recording', async (event, params) => {
  if (!capturer) {
    await initializeCapturer();
  }

  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const outputPath = path.join(recordingsDir, `recording-${timestamp}.mp4`);

  params.outputPath = outputPath;

  const session = await capturer.startSession(params);
  currentSession = session.sessionId;

  return {
    ...session,
    outputPath
  };
});

ipcMain.handle('stop-recording', async () => {
  if (!capturer || !currentSession) {
    throw new Error('No active recording session');
  }

  const result = await capturer.stopSession(currentSession);
  currentSession = null;
  return result;
});

ipcMain.handle('open-preview', (event, cameraId) => {
  console.log('[Main] Opening preview for camera:', cameraId);
  createPreviewWindow(cameraId);
  return { success: true };
});

ipcMain.handle('close-preview', () => {
  if (previewWindow) {
    previewWindow.close();
  }
  return { success: true };
});

ipcMain.handle('update-preview-camera', (event, cameraId) => {
  console.log('[Main] Updating preview camera to:', cameraId);
  if (previewWindow) {
    previewWindow.webContents.send('update-camera', cameraId);
    return { success: true };
  }
  return { success: false, error: 'Preview window not open' };
});

ipcMain.handle('get-recordings-dir', () => {
  return recordingsDir;
});

ipcMain.handle('open-recordings-folder', () => {
  require('electron').shell.openPath(recordingsDir);
  return { success: true };
});

ipcMain.handle('get-preview-window-id', () => {
  if (!previewWindow) {
    return null;
  }
  return previewWindow.getMediaSourceId();
});

app.whenReady().then(async () => {
  createMainWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createMainWindow();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

app.on('will-quit', async () => {
  if (capturer) {
    try {
      if (currentSession) {
        await capturer.stopSession(currentSession);
      }
      await capturer.shutdown();
    } catch (err) {
      console.error('[Main] Error during cleanup:', err);
    }
  }
});
