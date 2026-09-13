// FFI for Capture.App

// ============================================================================
// Audio recording + Whisper transcription
// ============================================================================

let _mediaRecorder = null;
let _audioChunks = [];
let _recordedMimeType = "audio/webm";

// Safari only learned WebM/Opus recording in 18.4; older Safari and some
// Android builds want audio/mp4. Ask rather than assume — an unsupported
// mimeType makes the MediaRecorder constructor throw NotSupportedError.
const CANDIDATE_MIME_TYPES = [
  "audio/webm;codecs=opus",
  "audio/webm",
  "audio/mp4",
];

const pickMimeType = () => {
  for (const t of CANDIDATE_MIME_TYPES) {
    if (MediaRecorder.isTypeSupported(t)) return t;
  }
  return ""; // let the browser pick its own default
};

// Resolves "" on success, or a human-readable reason on failure. Never
// rejects: the caller renders whatever comes back, so a phone with no
// console attached still shows why nothing happened.
export const startRecording_ = () => {
  return new Promise((resolve) => {
    if (typeof MediaRecorder === "undefined") {
      resolve("This browser has no MediaRecorder.");
      return;
    }
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      resolve(
        window.isSecureContext
          ? "No microphone API in this browser."
          : "Microphone needs HTTPS — open the https:// address, not the :3101 one."
      );
      return;
    }
    navigator.mediaDevices.getUserMedia({ audio: true })
      .then(stream => {
        try {
          const mimeType = pickMimeType();
          _audioChunks = [];
          _mediaRecorder = mimeType
            ? new MediaRecorder(stream, { mimeType })
            : new MediaRecorder(stream);
          _recordedMimeType = _mediaRecorder.mimeType || mimeType || "audio/webm";
          console.log("[capture] recording as", _recordedMimeType);
          _mediaRecorder.ondataavailable = (e) => {
            if (e.data.size > 0) _audioChunks.push(e.data);
          };
          _mediaRecorder.start();
          resolve("");
        } catch (e) {
          stream.getTracks().forEach(t => t.stop());
          _mediaRecorder = null;
          console.error("[capture] MediaRecorder failed:", e);
          resolve("Recorder failed: " + (e.name || "") + " " + (e.message || ""));
        }
      })
      .catch(e => {
        console.error("[capture] getUserMedia failed:", e);
        const name = e && e.name ? e.name : "Error";
        resolve(
          name === "NotAllowedError"
            ? "Microphone permission denied — allow it for this site and retry."
            : name + ": " + ((e && e.message) || "could not open the microphone")
        );
      });
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
      const blob = new Blob(_audioChunks, { type: _recordedMimeType });
      console.log("[capture] recorded blob:", blob.size, "bytes", _recordedMimeType);
      _mediaRecorder.stream.getTracks().forEach(t => t.stop());
      _mediaRecorder = null;
      _audioChunks = [];

      const whisperUrl = window.location.origin + '/transcribe';
      console.log("[capture] POSTing to", whisperUrl);
      try {
        const resp = await fetch(whisperUrl, {
          method: "POST",
          body: blob,
          headers: { "Content-Type": _recordedMimeType },
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
