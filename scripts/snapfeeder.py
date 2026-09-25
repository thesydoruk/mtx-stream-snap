#!/usr/bin/env python3

"""
snapfeeder.py
-------------
Flask-based JPEG snapshot server for MediaMTX RTSP streams.

This server:
- Parses ../mediamtx/mediamtx.yml (relative to this script)
- Detects all cameras with `source: publisher` and RTSP in `runOnInit`
- Connects to each RTSP stream with PyAV in a background thread
- Keeps the latest decoded frame in memory
- Encodes to JPEG on-demand using TurboJPEG
- One snapshot endpoint per camera: /cam0.jpg, /cam1.jpg, etc.

Dependencies:
- ruamel.yaml, flask, av, turbojpeg
"""

import re
import sys
import av
import time
import threading
from ruamel.yaml import YAML
from flask import Flask, send_file
from io import BytesIO
from turbojpeg import TurboJPEG, TJPF_BGR
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

    paths = config.get('paths') or {}
    for name, entry in paths.items():
        if not isinstance(entry, dict):
            continue
        if entry.get('source') != 'publisher':
            continue
        run_init = entry.get('runOnInit') or ''
        rtsp_match = re.search(r'rtsp://[^\s\'"]+', run_init)
        if rtsp_match:
            rtsp_url = rtsp_match.group(0)
            CAMERAS[name] = {
                'source': rtsp_url,
                'latest_frame': None,
                'latest_jpeg': None  # (frame, jpeg bytes) cache for latest_frame
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
        container = None
        try:
            container = av.open(
                cam['source'],
                options={"rtsp_transport": "tcp", "timeout": "2000000"}  # 2s socket I/O timeout (µs)
            )

            for frame in container.decode(video=0):
                cam['latest_frame'] = frame

            print(f"[{name}] Stream ended, reconnecting in {retry_delay}s...")
        except av.FFmpegError as e:
            print(f"[{name}] FFmpegError: {e}, retrying in {retry_delay}s...")
        except Exception as e:
            print(f"[{name}] Unexpected error: {e}, retrying in {retry_delay}s...")
        finally:
            # Do not serve stale frames while the stream is down
            cam['latest_frame'] = None
            if container is not None:
                try:
                    container.close()
                except Exception:
                    pass

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

    cached = cam.get('latest_jpeg')
    if cached and cached[0] is frame:
        return send_file(BytesIO(cached[1]), mimetype='image/jpeg')

    try:
        jpeg_buf = JPEG_ENCODER.encode(frame.to_ndarray(format='bgr24'), quality=100, pixel_format=TJPF_BGR)
        cam['latest_jpeg'] = (frame, jpeg_buf)
        return send_file(BytesIO(jpeg_buf), mimetype='image/jpeg')
    except Exception as e:
        return f"Encoding error: {e}", 500

# Register Flask route
app.add_url_rule('/<name>.jpg', view_func=serve_snapshot)

# Main entrypoint
if __name__ == '__main__':
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

    time.sleep(1)
    app.run(host='0.0.0.0', port=5050)
