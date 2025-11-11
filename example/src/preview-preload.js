const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('previewAPI', {
  onSetCamera: (callback) => ipcRenderer.on('set-camera', (event, cameraId) => callback(cameraId)),
  onUpdateCamera: (callback) => ipcRenderer.on('update-camera', (event, cameraId) => callback(cameraId))
});
