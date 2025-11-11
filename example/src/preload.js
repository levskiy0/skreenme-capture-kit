const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electronAPI', {
  listSources: () => ipcRenderer.invoke('list-sources'),
  checkPermissions: () => ipcRenderer.invoke('check-permissions'),
  requestPermissions: () => ipcRenderer.invoke('request-permissions'),
  startRecording: (params) => ipcRenderer.invoke('start-recording', params),
  stopRecording: () => ipcRenderer.invoke('stop-recording'),
  openPreview: (cameraId) => ipcRenderer.invoke('open-preview', cameraId),
  closePreview: () => ipcRenderer.invoke('close-preview'),
  updatePreviewCamera: (cameraId) => ipcRenderer.invoke('update-preview-camera', cameraId),
  getRecordingsDir: () => ipcRenderer.invoke('get-recordings-dir'),
  openRecordingsFolder: () => ipcRenderer.invoke('open-recordings-folder'),
  getPreviewWindowId: () => ipcRenderer.invoke('get-preview-window-id'),

  onCapturerReady: (callback) => ipcRenderer.on('capturer-ready', callback),
  onCapturerError: (callback) => ipcRenderer.on('capturer-error', (event, message) => callback(message)),
  onSessionStarted: (callback) => ipcRenderer.on('session-started', (event, data) => callback(data)),
  onSessionStopped: (callback) => ipcRenderer.on('session-stopped', (event, data) => callback(data)),
  onPreviewClosed: (callback) => ipcRenderer.on('preview-closed', callback)
});
