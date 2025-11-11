let sources = null;
let selectedDisplay = null;
let selectedCamera = null;
let selectedAudio = null;
let isRecording = false;
let recordingStartTime = null;
let timerInterval = null;
let previewOpen = false;
let permissions = { screenRecording: false, camera: 'unknown', microphone: 'unknown', accessibility: false };

function log(message, type = 'info') {
  const logDiv = document.getElementById('log');
  const entry = document.createElement('div');
  entry.className = `log-entry ${type}`;
  const timestamp = new Date().toLocaleTimeString();
  entry.textContent = `[${timestamp}] ${message}`;
  logDiv.appendChild(entry);
  logDiv.scrollTop = logDiv.scrollHeight;
}

function updateStatus(text, ready = false, recording = false) {
  document.getElementById('statusText').textContent = text;
  const dot = document.getElementById('statusDot');
  dot.className = 'status-dot';
  if (recording) {
    dot.classList.add('recording');
  } else if (ready) {
    dot.classList.add('ready');
  }
}

function updatePermissionsUI(perms) {
  permissions = perms;

  const screenCard = document.getElementById('screenPermission');
  const screenStatus = document.getElementById('screenStatus');
  screenCard.className = 'permission-card';
  screenStatus.className = 'permission-status';

  if (perms.screenRecording) {
    screenCard.classList.add('granted');
    screenStatus.classList.add('granted');
    screenStatus.textContent = 'Granted ✓';
  } else {
    screenCard.classList.add('denied');
    screenStatus.classList.add('denied');
    screenStatus.textContent = 'Denied ✗';
  }

  const cameraCard = document.getElementById('cameraPermission');
  const cameraStatus = document.getElementById('cameraStatus');
  cameraCard.className = 'permission-card';
  cameraStatus.className = 'permission-status';

  if (perms.camera === 'granted') {
    cameraCard.classList.add('granted');
    cameraStatus.classList.add('granted');
    cameraStatus.textContent = 'Granted ✓';
  } else if (perms.camera === 'denied') {
    cameraCard.classList.add('denied');
    cameraStatus.classList.add('denied');
    cameraStatus.textContent = 'Denied ✗';
  } else {
    cameraStatus.classList.add('unknown');
    cameraStatus.textContent = perms.camera === 'prompt' ? 'Not Asked' : 'Unknown';
  }

  const micCard = document.getElementById('micPermission');
  const micStatus = document.getElementById('micStatus');
  micCard.className = 'permission-card';
  micStatus.className = 'permission-status';

  if (perms.microphone === 'granted') {
    micCard.classList.add('granted');
    micStatus.classList.add('granted');
    micStatus.textContent = 'Granted ✓';
  } else if (perms.microphone === 'denied') {
    micCard.classList.add('denied');
    micStatus.classList.add('denied');
    micStatus.textContent = 'Denied ✗';
  } else {
    micStatus.classList.add('unknown');
    micStatus.textContent = perms.microphone === 'prompt' ? 'Not Asked' : 'Unknown';
  }

  log(`Permissions - Screen: ${perms.screenRecording}, Camera: ${perms.camera}, Mic: ${perms.microphone}`, 'info');
}

function startTimer() {
  recordingStartTime = Date.now();
  timerInterval = setInterval(() => {
    const elapsed = Date.now() - recordingStartTime;
    const hours = Math.floor(elapsed / 3600000);
    const minutes = Math.floor((elapsed % 3600000) / 60000);
    const seconds = Math.floor((elapsed % 60000) / 1000);
    document.getElementById('timer').textContent =
      `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
  }, 1000);
}

function stopTimer() {
  if (timerInterval) {
    clearInterval(timerInterval);
    timerInterval = null;
  }
}

function updateSelectionIndicators() {
  const displayIndicator = document.getElementById('displayIndicator');
  displayIndicator.style.display = selectedDisplay !== null ? 'inline-block' : 'none';
  if (selectedDisplay !== null && sources) {
    displayIndicator.textContent = `${sources.displays[selectedDisplay].name}`;
  }

  const cameraIndicator = document.getElementById('cameraIndicator');
  cameraIndicator.style.display = selectedCamera !== null ? 'inline-block' : 'none';
  if (selectedCamera !== null && sources) {
    cameraIndicator.textContent = `${sources.cameras[selectedCamera].name}`;
  }

  const audioIndicator = document.getElementById('audioIndicator');
  audioIndicator.style.display = selectedAudio !== null ? 'inline-block' : 'none';
  if (selectedAudio !== null && sources) {
    audioIndicator.textContent = `${sources.audio[selectedAudio].name}`;
  }

  const previewBtn = document.getElementById('previewBtn');
  previewBtn.disabled = selectedCamera === null;
}

async function refreshSources() {
  try {
    log('Refreshing sources...');
    sources = await window.electronAPI.listSources();

    const displaysList = document.getElementById('displaysList');
    displaysList.innerHTML = '';
    sources.displays.forEach((display, index) => {
      const card = document.createElement('div');
      card.className = 'card';
      if (selectedDisplay === index) card.classList.add('selected');
      card.onclick = () => selectDisplay(index);
      card.innerHTML = `
        <div class="card-title">${display.name}</div>
        <div class="card-subtitle">ID: ${display.id}</div>
        ${display.frame ? `<div class="card-subtitle">${display.frame.width}x${display.frame.height}</div>` : ''}
      `;
      displaysList.appendChild(card);
    });

    const camerasList = document.getElementById('camerasList');
    camerasList.innerHTML = '';
    sources.cameras.forEach((camera, index) => {
      const card = document.createElement('div');
      card.className = 'card';
      if (selectedCamera === index) card.classList.add('selected');
      card.onclick = () => selectCamera(index);
      card.innerHTML = `
        <div class="card-title">${camera.name}</div>
        <div class="card-subtitle">ID: ${camera.id}</div>
      `;
      camerasList.appendChild(card);
    });

    const audioList = document.getElementById('audioList');
    audioList.innerHTML = '';
    sources.audio.forEach((audio, index) => {
      const card = document.createElement('div');
      card.className = 'card';
      if (selectedAudio === index) card.classList.add('selected');
      card.onclick = () => selectAudio(index);
      card.innerHTML = `
        <div class="card-title">${audio.name}</div>
        <div class="card-subtitle">${audio.type}</div>
      `;
      audioList.appendChild(card);
    });

    log(`Found ${sources.displays.length} displays, ${sources.cameras.length} cameras, ${sources.audio.length} audio devices`, 'success');
    updateStartButton();
    updateSelectionIndicators();
  } catch (err) {
    log(`Error: ${err.message}`, 'error');
  }
}

function selectDisplay(index) {
  selectedDisplay = index;
  document.querySelectorAll('#displaysList .card').forEach((card, i) => {
    card.classList.toggle('selected', i === index);
  });
  log(`Selected display: ${sources.displays[index].name}`);
  updateStartButton();
  updateSelectionIndicators();
}

function selectCamera(index) {
  selectedCamera = index;
  document.querySelectorAll('#camerasList .card').forEach((card, i) => {
    card.classList.toggle('selected', i === index);
  });
  log(`Selected camera: ${sources.cameras[index].name}`);
  updateStartButton();
  updateSelectionIndicators();

  if (previewOpen) {
    const cameraName = sources.cameras[index].name;
    window.electronAPI.updatePreviewCamera(cameraName);
    log(`Preview updated to ${cameraName}`);
  }
}

function selectAudio(index) {
  selectedAudio = index;
  document.querySelectorAll('#audioList .card').forEach((card, i) => {
    card.classList.toggle('selected', i === index);
  });
  log(`Selected audio: ${sources.audio[index].name}`);
  updateStartButton();
  updateSelectionIndicators();
}

function updateStartButton() {
  const startBtn = document.getElementById('startBtn');
  startBtn.disabled = selectedDisplay === null || isRecording;
}

async function requestAllPermissions() {
  try {
    log('Requesting permissions...', 'info');
    const perms = await window.electronAPI.requestPermissions();
    updatePermissionsUI(perms);

    const allGranted = perms.screenRecording &&
                       perms.camera === 'granted' &&
                       perms.microphone === 'granted';

    if (allGranted) {
      log('All permissions granted!', 'success');
    } else {
      log('Some permissions need attention. Check System Preferences if needed.', 'error');
    }
  } catch (err) {
    log(`Permission error: ${err.message}`, 'error');
  }
}

async function refreshPermissions() {
  try {
    log('Refreshing permissions status...', 'info');
    const perms = await window.electronAPI.checkPermissions();
    updatePermissionsUI(perms);
  } catch (err) {
    log(`Failed to refresh permissions: ${err.message}`, 'error');
  }
}

async function togglePreview() {
  if (selectedCamera === null) {
    log('Please select a camera first', 'error');
    return;
  }

  try {
    if (previewOpen) {
      await window.electronAPI.closePreview();
      previewOpen = false;
      document.getElementById('previewBtn').textContent = 'Camera Preview';
      log('Preview closed');
    } else {
      const cameraName = sources.cameras[selectedCamera].name;
      await window.electronAPI.openPreview(cameraName);
      previewOpen = true;
      document.getElementById('previewBtn').textContent = 'Close Preview';
      log(`Preview opened for ${cameraName}`);
    }
  } catch (err) {
    log(`Preview error: ${err.message}`, 'error');
  }
}

async function openRecordingsFolder() {
  try {
    await window.electronAPI.openRecordingsFolder();
    log('Opened recordings folder');
  } catch (err) {
    log(`Error: ${err.message}`, 'error');
  }
}

async function startRecording() {
  if (!sources || selectedDisplay === null) {
    log('Please select a display first', 'error');
    return;
  }

  if (isRecording) {
    log('Recording already in progress', 'error');
    return;
  }

  try {
    const params = {
      mode: 'display',
      displayId: sources.displays[selectedDisplay].id,
      showCursor: document.getElementById('showCursor').checked,
      frameRate: parseInt(document.getElementById('frameRate').value)
    };

    if (selectedCamera !== null) {
      params.cameraSourceId = sources.cameras[selectedCamera].id;
      params.cameraFormat = document.getElementById('cameraFormat').value;
      params.cameraWidth = params.cameraFormat === 'square' ? 640 : 1280;
      params.cameraHeight = params.cameraFormat === 'square' ? 640 : 720;
    }

    if (selectedAudio !== null) {
      params.audioSourceId = sources.audio[selectedAudio].id;
    }

    log('Starting recording...', 'info');

    document.getElementById('startBtn').disabled = true;

    const session = await window.electronAPI.startRecording(params);

    isRecording = true;
    document.getElementById('stopBtn').disabled = false;
    document.getElementById('recordingInfo').classList.add('active');
    updateStatus('Recording...', false, true);
    startTimer();

    log(`Recording started! Session ID: ${session.sessionId}`, 'success');
    log(`Output: ${session.outputPath}`, 'info');
  } catch (err) {
    log(`Failed to start recording: ${err.message}`, 'error');

    isRecording = false;
    document.getElementById('startBtn').disabled = false;
    document.getElementById('stopBtn').disabled = true;
    document.getElementById('recordingInfo').classList.remove('active');
    updateStatus('Ready', true, false);
    stopTimer();
  }
}

async function stopRecording() {
  if (!isRecording) {
    return;
  }

  try {
    log('Stopping recording...');
    const result = await window.electronAPI.stopRecording();

    isRecording = false;
    document.getElementById('startBtn').disabled = false;
    document.getElementById('stopBtn').disabled = true;
    document.getElementById('recordingInfo').classList.remove('active');
    updateStatus('Ready', true, false);
    stopTimer();

    log(`Recording stopped!`, 'success');
    log(`Duration: ${result.recording.duration.toFixed(2)}s`, 'info');
    log(`Output: ${result.recording.outputPath}`, 'info');
    log(`Mouse events captured: ${result.events.length}`, 'info');

    if (result.recording.screen) {
      log(`Screen: ${result.recording.screen.resolution.width}x${result.recording.screen.resolution.height} @ ${result.recording.screen.fps}fps`, 'info');
    }
    if (result.recording.camera) {
      log(`Camera: ${result.recording.camera.resolution.width}x${result.recording.camera.resolution.height}`, 'info');
    }
  } catch (err) {
    log(`Failed to stop recording: ${err.message}`, 'error');
  }
}

window.electronAPI.onCapturerReady(() => {
  log('Capturer ready!', 'success');
  updateStatus('Ready', true);
  refreshSources();
});

window.electronAPI.onCapturerError((message) => {
  log(`Capturer error: ${message}`, 'error');
});

window.electronAPI.onSessionStarted((data) => {
  log(`Session started event: ${data.sessionId}`, 'success');
});

window.electronAPI.onSessionStopped((data) => {
  log('Session stopped event', 'success');
});

window.electronAPI.onPreviewClosed(() => {
  previewOpen = false;
  document.getElementById('previewBtn').textContent = 'Camera Preview';
  log('Preview window closed');
});

log('Application started', 'info');

window.electronAPI.checkPermissions().then(perms => {
  updatePermissionsUI(perms);
}).catch(err => {
  log(`Failed to check permissions: ${err.message}`, 'error');
});
