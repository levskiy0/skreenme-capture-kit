let videoStream = null;
let currentCameraId = null;
let availableCameras = [];

async function getCameras() {
  try {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: false });
      stream.getTracks().forEach(track => track.stop());
    } catch (permErr) {
      console.log('[Preview] Permission request failed, trying enumerateDevices anyway:', permErr);
    }

    const devices = await navigator.mediaDevices.enumerateDevices();
    availableCameras = devices.filter(device => device.kind === 'videoinput');
    console.log('[Preview] Available cameras:', availableCameras);
    console.log('[Preview] Camera labels:', availableCameras.map(c => c.label));
    return availableCameras;
  } catch (err) {
    console.error('[Preview] Error enumerating devices:', err);
    return [];
  }
}

async function startCamera(cameraName = null) {
  try {
    if (videoStream) {
      videoStream.getTracks().forEach(track => track.stop());
    }

    if (availableCameras.length === 0) {
      await getCameras();
    }

    let constraints;
    let selectedCamera = null;

    if (cameraName) {
      console.log('[Preview] Looking for camera:', cameraName);
      console.log('[Preview] Available cameras:', availableCameras.map(c => c.label));

      selectedCamera = availableCameras.find(cam => {
        const camLabel = cam.label.toLowerCase();
        const searchName = cameraName.toLowerCase();

        if (camLabel === searchName) return true;

        if (camLabel.includes(searchName)) return true;

        const cleanCamLabel = camLabel.replace(/\s*(camera|microphone|front|back|wide|ultra)/gi, '').trim();
        const cleanSearchName = searchName.replace(/\s*(camera|microphone|front|back|wide|ultra)/gi, '').trim();
        if (cleanCamLabel.includes(cleanSearchName) || cleanSearchName.includes(cleanCamLabel)) return true;

        return false;
      });

      if (selectedCamera) {
        console.log('[Preview] Found camera:', selectedCamera.label);
        constraints = {
          video: {
            deviceId: { exact: selectedCamera.deviceId },
            width: { ideal: 1280 },
            height: { ideal: 720 }
          },
          audio: false
        };
        currentCameraId = selectedCamera.deviceId;
      } else {
        console.log('[Preview] Camera not found by name, trying first available');
        selectedCamera = availableCameras[0];
        constraints = {
          video: {
            deviceId: { exact: selectedCamera.deviceId },
            width: { ideal: 1280 },
            height: { ideal: 720 }
          },
          audio: false
        };
        currentCameraId = selectedCamera.deviceId;
      }
    } else {
      constraints = {
        video: {
          width: { ideal: 1280 },
          height: { ideal: 720 }
        },
        audio: false
      };
    }

    videoStream = await navigator.mediaDevices.getUserMedia(constraints);
    const video = document.getElementById('video');
    video.srcObject = videoStream;

    const track = videoStream.getVideoTracks()[0];
    const settings = track.getSettings();
    const label = track.label || 'Unknown Camera';

    if (!currentCameraId) {
      currentCameraId = settings.deviceId;
    }

    updateStatus(`${label} (${settings.width}x${settings.height})`);
    updateCameraButtons();
  } catch (err) {
    console.error('[Preview] Error accessing camera:', err);
    showError(`Failed to access camera: ${err.message}`);
    if (cameraName) {
      console.log('[Preview] Trying default camera as fallback');
      await startCamera(null);
    }
  }
}

async function toggleCamera() {
  if (availableCameras.length === 0) {
    await getCameras();
  }

  if (availableCameras.length <= 1) {
    updateStatus('No other cameras available');
    return;
  }

  const currentIndex = availableCameras.findIndex(cam => cam.deviceId === currentCameraId);
  const nextIndex = (currentIndex + 1) % availableCameras.length;
  const nextCamera = availableCameras[nextIndex];

  updateStatus(`Switching to ${nextCamera.label || 'camera ' + (nextIndex + 1)}...`);
  await startCamera(nextCamera.label);
}

function updateCameraButtons() {
  const controls = document.querySelector('.controls');
  if (!controls) return;

  if (availableCameras.length > 1) {
    const currentIndex = availableCameras.findIndex(cam => cam.deviceId === currentCameraId);
    const cameraInfo = document.getElementById('cameraInfo');
    if (cameraInfo) {
      cameraInfo.textContent = `Camera ${currentIndex + 1} of ${availableCameras.length}`;
    }
  }
}

function updateStatus(message) {
  const statusEl = document.getElementById('status');
  if (statusEl) {
    statusEl.textContent = message;
  }
  console.log('[Preview]', message);
}

function showError(message) {
  const errorDiv = document.createElement('div');
  errorDiv.className = 'error';
  errorDiv.innerHTML = `
    <h3>⚠️ Error</h3>
    <p>${message}</p>
  `;
  document.body.appendChild(errorDiv);

  setTimeout(() => {
    errorDiv.remove();
  }, 5000);
}

async function initialize() {
  updateStatus('Requesting camera access...');

  await getCameras();

  if (availableCameras.length === 0) {
    showError('No cameras found. Please connect a camera and try again.');
    updateStatus('No cameras available');
    return;
  }

  await startCamera();
  updateStatus('Waiting for camera selection...');
}

if (window.previewAPI) {
  window.previewAPI.onSetCamera(async (cameraName) => {
    console.log('[Preview] Set camera:', cameraName);
    updateStatus(`Loading camera: ${cameraName}...`);
    await startCamera(cameraName);
  });

  window.previewAPI.onUpdateCamera(async (cameraName) => {
    console.log('[Preview] Update camera:', cameraName);
    updateStatus(`Switching to: ${cameraName}...`);
    await startCamera(cameraName);
  });
}

window.addEventListener('beforeunload', () => {
  if (videoStream) {
    videoStream.getTracks().forEach(track => track.stop());
  }
});

initialize();
