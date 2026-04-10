// FFI for Capture.App

// ============================================================================
// Audio recording + Whisper transcription
// ============================================================================

let _mediaRecorder = null;
let _audioChunks = [];

export const startRecording_ = () => {
  return new Promise((resolve) => {
    navigator.mediaDevices.getUserMedia({ audio: true })
      .then(stream => {
        _audioChunks = [];
        _mediaRecorder = new MediaRecorder(stream, { mimeType: "audio/webm" });
        _mediaRecorder.ondataavailable = (e) => {
          if (e.data.size > 0) _audioChunks.push(e.data);
        };
        _mediaRecorder.start();
        resolve(true);
      })
      .catch(() => resolve(false));
  });
};

export const stopAndTranscribe_ = () => {
  return new Promise((resolve, reject) => {
    if (!_mediaRecorder || _mediaRecorder.state !== "recording") {
      console.error("[capture] stopAndTranscribe: not recording");
      reject(new Error("Not recording"));
      return;
    }
    _mediaRecorder.onstop = async () => {
      const blob = new Blob(_audioChunks, { type: "audio/webm" });
      console.log("[capture] recorded blob:", blob.size, "bytes");
      _mediaRecorder.stream.getTracks().forEach(t => t.stop());
      _mediaRecorder = null;
      _audioChunks = [];

      const whisperUrl = window.location.origin + '/transcribe';
      console.log("[capture] POSTing to", whisperUrl);
      try {
        const resp = await fetch(whisperUrl, {
          method: "POST",
          body: blob,
          headers: { "Content-Type": "audio/webm" },
        });
        console.log("[capture] whisper response:", resp.status);
        const data = await resp.json();
        console.log("[capture] transcript:", JSON.stringify(data));
        resolve(data.text || "");
      } catch (e) {
        console.error("[capture] transcription error:", e);
        reject(e);
      }
    };
    _mediaRecorder.stop();
  });
};

export const isRecording_ = () => {
  return _mediaRecorder !== null && _mediaRecorder.state === "recording";
};

// ============================================================================
// localStorage — sticky project selection
// ============================================================================

const STORAGE_KEY = "marginalia-capture-project-id";

export const getStoredProjectId_ = () => {
  try {
    const v = localStorage.getItem(STORAGE_KEY);
    return v ? parseInt(v, 10) || 0 : 0;
  } catch {
    return 0;
  }
};

export const setStoredProjectId_ = (id) => () => {
  try {
    localStorage.setItem(STORAGE_KEY, String(id));
  } catch {
    // ignore — storage might be full or disabled
  }
};
