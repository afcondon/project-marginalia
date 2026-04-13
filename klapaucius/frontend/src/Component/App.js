// FFI for App component
export const stopPropagation_ = (event) => () => { event.stopPropagation(); };

export const copyToClipboard = (s) => () => {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(s).catch((err) => {
      console.warn("clipboard.writeText failed:", (err && err.message) || err);
    });
  }
};

// Clipboard image paste
const readClipboardImage_ = (event) => {
  return new Promise((resolve) => {
    const items = event.clipboardData && event.clipboardData.items;
    if (!items) { resolve(null); return; }
    for (const item of items) {
      if (item.type.startsWith('image/')) {
        const blob = item.getAsFile();
        if (!blob) { resolve(null); return; }
        const ext = item.type.split('/')[1] || 'png';
        const ts = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
        const filename = 'screenshot-' + ts + '.' + ext;
        const reader = new FileReader();
        reader.onload = () => {
          const base64 = reader.result.split(',')[1] || '';
          resolve({ filename, base64 });
        };
        reader.onerror = () => resolve(null);
        reader.readAsDataURL(blob);
        return;
      }
    }
    resolve(null);
  });
};

export const slugify_ = (s) =>
  s.toLowerCase().replace(/\s+/g, '-').replace(/[^a-z0-9-]/g, '').replace(/-+/g, '-').replace(/^-|-$/g, '');

export const onPaste_ = (callback) => () => {
  const handler = (e) => {
    readClipboardImage_(e).then((result) => {
      if (result) {
        e.preventDefault();
        callback(result)();
      }
    });
  };
  window.addEventListener('paste', handler);
  return () => window.removeEventListener('paste', handler);
};

export const todayMMDD_ = () => {
  const now = new Date();
  const mm = String(now.getMonth() + 1).padStart(2, '0');
  const dd = String(now.getDate()).padStart(2, '0');
  return mm + '-' + dd;
};
