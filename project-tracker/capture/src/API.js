// FFI for Capture.API

export const escapeJson = (s) =>
  s.replace(/\\/g, '\\\\')
   .replace(/"/g, '\\"')
   .replace(/\n/g, '\\n')
   .replace(/\r/g, '\\r')
   .replace(/\t/g, '\\t');
