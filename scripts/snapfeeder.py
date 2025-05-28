#!/usr/bin/env python3

"""
snapfeeder.py
-------------
Flask-based JPEG snapshot server for MediaMTX RTSP streams.

This server:
- Parses ../mediamtx/mediamtx.yml (relative to this script)
- Detects all cameras with `source: publisher` and RTSP in `runOnInit`
- Spawns an ffmpeg subprocess for each RTSP stream
- Uses PyAV to grab latest frame
- Encodes to JPEG on-demand using TurboJPEG
- One snapshot endpoint per camera: /cam0.jpg, /cam1.jpg, etc.

Dependencies:
- ruamel.yaml, flask, av, turbojpeg, ffmpeg
"""

import os
import re
import sys
import av
import time
import signal
import threading
import subprocess
from ruamel.yaml import YAML
from flask import Flask, Response, send_file
from io import BytesIO
from turbojpeg import TurboJPEG
from pathlib import Path

# Configuration file path: ../mediamtx/mediamtx.yml
CONFIG_PATH = Path(__file__).resolve().parent.parent / "mediamtx" / "mediamtx.yml"

# Flask app and runtime data
app = Flask(__name__)
CAMERAS = {}  # cam name → stream info
JPEG_ENCODER = TurboJPEG()

# Parse MediaMTX config and extract camera definitions
def parse_mediamtx_config():
    """
    Reads mediamtx.yml and collects all RTSP camera entries
    with source: publisher and a valid RTSP URL in runOnInit.
    """
    if not CONFIG_PATH.exists():
        raise FileNotFoundError(f"❌ Config file not found: {CONFIG_PATH}")
    
    yaml = YAML()
    with open(CONFIG_PATH, 'r') as f:
        config = yaml.load(f)

    paths = config.get('paths', {})
    for name, entry in paths.items():
        if not isinstance(entry, dict):
            continue
        if entry.get('source') != 'publisher':
            continue
        run_init = entry.get('runOnInit', '')
        rtsp_match = re.search(r'rtsp://[^\s\'"]+', run_init)
        if rtsp_match:
            rtsp_url = rtsp_match.group(0)
            CAMERAS[name] = {
                'source': rtsp_url,
                'container': None,
                'process': None,
                'latest_frame': None,
                'latest_jpeg': None
            }

# PyAV capture thread for a specific camera
def capture_loop(name):
    """
    Directly connects to the RTSP stream using PyAV and stores the latest raw frame.
    JPEG encoding happens only on-demand during HTTP request.
    """
    cam = CAMERAS[name]
    retry_delay = 5

    while True:
        try:
            container = av.open(
                cam['source'],
                options={"rtsp_transport": "tcp", "stimeout": "2000000"}  # 2s timeout
            )
            cam['container'] = container

            for frame in container.decode(video=0):
                cam['latest_frame'] = frame
                cam['latest_jpeg'] = None

        except av.AVError as e:
            print(f"[{name}] AVError: {e}, retrying in {retry_delay}s...")
            time.sleep(retry_delay)
        except Exception as e:
            print(f"[{name}] Unexpected error: {e}")
            time.sleep(retry_delay)


# Flask view to return JPEG snapshot from camera
def serve_snapshot(name):
    """
    Returns latest JPEG from memory.
    - 404: unknown camera
    - 503: no frame ready
    """
    cam = CAMERAS.get(name)
    if not cam:
        return "Camera not found", 404

    frame = cam.get('latest_frame')
    if frame is None:
        return "Frame not ready", 503

    if cam['latest_jpeg']:
        return send_file(BytesIO(cam['latest_jpeg']), mimetype='image/jpeg')

    try:
        jpeg_buf = JPEG_ENCODER.encode(frame.to_ndarray(format='bgr24'), quality=100, pixel_format=1)
        cam['latest_jpeg'] = jpeg_buf
        return send_file(BytesIO(jpeg_buf), mimetype='image/jpeg')
    except Exception as e:
        return f"Encoding error: {e}", 500

# Graceful shutdown: stop all ffmpeg processes
def cleanup():
    for cam in CAMERAS.values():
        proc = cam.get('process')
        if proc:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()

# Register Flask route
app.add_url_rule('/<name>.jpg', view_func=serve_snapshot)

# Main entrypoint
if __name__ == '__main__':
    import atexit
    try:
        parse_mediamtx_config()
    except Exception as e:
        print(f"Config error: {e}")
        sys.exit(1)

    if not CAMERAS:
        print("No RTSP publishers found in mediamtx.yml.")
        sys.exit(1)

    for name in CAMERAS:
        t = threading.Thread(target=capture_loop, args=(name,), daemon=True)
        t.start()

    atexit.register(cleanup)
    time.sleep(1)
    app.run(host='0.0.0.0', port=5050)
