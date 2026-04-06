#!/usr/bin/env python3
"""
Minimal Whisper transcription server.
Accepts audio POST, returns text. Runs on port 3200.

Usage:
    python3 tools/whisper-server.py [--model base|medium|large-v3]
"""

import argparse
import json
import sys
import tempfile
from http.server import HTTPServer, BaseHTTPRequestHandler

# Lazy-load whisper to show startup message first
_model = None
_model_name = "base"


def get_model():
    global _model
    if _model is None:
        import whisper
        print(f"Loading Whisper model '{_model_name}'...")
        _model = whisper.load_model(_model_name)
        print("Model loaded.")
    return _model


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/transcribe":
            self.send_error(404)
            return

        content_length = int(self.headers.get("Content-Length", 0))
        if content_length == 0:
            self.send_error(400, "No audio data")
            return

        audio_data = self.rfile.read(content_length)

        # Write to temp file (whisper needs a file path)
        with tempfile.NamedTemporaryFile(suffix=".webm", delete=False) as f:
            f.write(audio_data)
            tmp_path = f.name

        try:
            model = get_model()
            result = model.transcribe(tmp_path, language="en", fp16=False)
            text = result["text"].strip()

            response = json.dumps({"text": text})
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.end_headers()
            self.wfile.write(response.encode())
        except Exception as e:
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(e)}).encode())
        finally:
            import os
            os.unlink(tmp_path)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def log_message(self, format, *args):
        # Quieter logging
        print(f"  {args[0]}")


def main():
    global _model_name
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="base", help="Whisper model (base, medium, large-v3)")
    parser.add_argument("--port", type=int, default=3200)
    args = parser.parse_args()
    _model_name = args.model

    # Pre-load model
    get_model()

    server = HTTPServer(("0.0.0.0", args.port), Handler)
    print(f"Whisper server running on http://localhost:{args.port}")
    print(f"  POST /transcribe — send audio, get text")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping.")
        server.server_close()


if __name__ == "__main__":
    main()
