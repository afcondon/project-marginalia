// FFI for Capture.API

export const escapeJson = (s) =>
  s.replace(/\\/g, '\\\\')
   .replace(/"/g, '\\"')
   .replace(/\n/g, '\\n')
   .replace(/\r/g, '\\r')
   .replace(/\t/g, '\\t');

// Trigger camera/file picker, upload the selected photo, return filename.
// Returns "" if the user cancels or the upload fails.
export const pickAndUploadPhotoImpl = (projectId) => () => {
  return new Promise((resolve) => {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = 'image/*';
    input.capture = 'environment'; // rear camera on mobile

    input.onchange = async () => {
      const file = input.files && input.files[0];
      if (!file) { resolve(""); return; }

      const url = `/api/agent/projects/${projectId}/attachments/upload`;
      console.log("[capture] uploading photo:", file.name, file.size, "bytes");
      try {
        const resp = await fetch(url, {
          method: "POST",
          body: file,
          headers: { "Content-Type": file.type || "image/jpeg" },
        });
        console.log("[capture] upload response:", resp.status);
        const data = await resp.json();
        console.log("[capture] upload result:", JSON.stringify(data));
        resolve(data.filename || "");
      } catch (e) {
        console.error("[capture] upload error:", e);
        resolve("");
      }
    };

    // If the user cancels the picker, onchange won't fire on some browsers.
    // Listen for focus returning to the window as a fallback.
    const onFocus = () => {
      setTimeout(() => {
        if (!input.files || input.files.length === 0) resolve("");
        window.removeEventListener('focus', onFocus);
      }, 500);
    };
    window.addEventListener('focus', onFocus);

    input.click();
  });
};
