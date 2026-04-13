// FFI for App component
export const stopPropagation_ = (event) => () => { event.stopPropagation(); };

// Copy a string to the clipboard. Fire-and-forget: the Promise is not
// awaited and its rejection is swallowed so a failed copy never throws
// into the Halogen event loop. Requires a secure context (localhost or
// HTTPS); on a plain-HTTP LAN IP this will silently log a warning.
export const copyToClipboard = (s) => () => {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(s).catch((err) => {
      console.warn("clipboard.writeText failed:", (err && err.message) || err);
    });
  } else {
    console.warn("clipboard API unavailable (non-secure context?)");
  }
};

// Hash routing
export const getHash_ = () => window.location.hash.slice(1);
export const setHash_ = (hash) => () => { window.location.hash = hash; };

// Subscribe to hashchange events. Calls the callback with the new hash.
// Returns an unsubscribe effect.
export const onHashChange_ = (callback) => () => {
  const handler = () => callback(window.location.hash.slice(1))();
  window.addEventListener("hashchange", handler);
  return () => window.removeEventListener("hashchange", handler);
};

// Subscribe to keydown events. Calls callback with {key, ctrl, meta, shift, target}.
// Returns an unsubscribe effect.
export const onKeyDown_ = (callback) => () => {
  const handler = (e) => {
    const tag = (e.target && e.target.tagName) || "";
    const isInput = tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";
    callback({
      key: e.key,
      ctrl: e.ctrlKey,
      meta: e.metaKey,
      shift: e.shiftKey,
      isInput: isInput,
      preventDefault: () => e.preventDefault(),
    })();
  };
  window.addEventListener("keydown", handler);
  return () => window.removeEventListener("keydown", handler);
};

// Focus the search input
export const focusSearch_ = () => {
  const el = document.querySelector(".header-search");
  if (el) el.focus();
};

// Get the number of columns in the project card grid
export const getGridColumns_ = () => {
  const grid = document.querySelector(".project-cards");
  if (!grid) return 1;
  const style = window.getComputedStyle(grid);
  const cols = style.getPropertyValue("grid-template-columns").split(" ").length;
  return cols || 1;
};

// Blur the currently focused element
export const blurActive_ = () => {
  if (document.activeElement) document.activeElement.blur();
};

// Read altKey from a MouseEvent
export const altKey_ = (event) => () => event.altKey === true;

// Focus the note textarea
export const focusNoteInput_ = () => {
  const el = document.querySelector(".note-input-textarea");
  if (el) el.focus();
};

// ============================================================================
// Audio recording + Whisper transcription
// ============================================================================

let _mediaRecorder = null;
let _audioChunks = [];

// Start recording audio. Returns true if started, false if failed.
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

// Stop recording, send to Whisper, return transcribed text.
export const stopAndTranscribe_ = () => {
  return new Promise((resolve, reject) => {
    if (!_mediaRecorder || _mediaRecorder.state !== "recording") {
      reject(new Error("Not recording"));
      return;
    }
    _mediaRecorder.onstop = async () => {
      const blob = new Blob(_audioChunks, { type: "audio/webm" });
      // Stop all tracks to release microphone
      _mediaRecorder.stream.getTracks().forEach(t => t.stop());
      _mediaRecorder = null;
      _audioChunks = [];

      // Two deployment shapes, same bundle:
      //   * localhost: whisper sidecar is a separate process on :3200
      //   * remote: proxied at same origin via Tailscale Serve as /transcribe
      const whisperUrl =
        (window.location.hostname === 'localhost' ||
         window.location.hostname === '127.0.0.1')
          ? 'http://localhost:3200/transcribe'
          : window.location.origin + '/transcribe';
      try {
        const resp = await fetch(whisperUrl, {
          method: "POST",
          body: blob,
          headers: { "Content-Type": "audio/webm" },
        });
        const data = await resp.json();
        resolve(data.text || "");
      } catch (e) {
        reject(e);
      }
    };
    _mediaRecorder.stop();
  });
};

// Check if currently recording
export const isRecording_ = () => {
  return _mediaRecorder !== null && _mediaRecorder.state === "recording";
};
