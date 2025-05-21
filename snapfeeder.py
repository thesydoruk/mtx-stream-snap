#!/usr/bin/env python3

"""
RTSP JPEG Snapshot Server (Optimized for Raspberry Pi 5)
---------------------------------------------------------
This script runs a low-latency Flask web server that serves JPEG snapshots from one or more RTSP cameras.
It uses a lightweight architecture:
- One ffmpeg subprocess per camera receives raw H.264 video over RTSP and outputs MPEG-TS to stdout
- PyAV decodes the packets and stores the latest decoded frame
- TurboJPEG encodes the most recent frame into JPEG only when a request is made

All camera configurations are parsed from /usr/local/etc/mediamtx.yml.
Only cameras with 'source: publisher' and a valid RTSP URL in 'runOnInit' are used.

"""

from ruamel.yaml import YAML         # To parse mediamtx.yml
import subprocess                    # To launch ffmpeg subprocesses
import threading                     # To run camera handlers concurrently
import signal                        # For process termination
import atexit                        # Register exit cleanup
import time                          # Delay handling
import os                            # File paths
import re                            # RTSP URL extraction
import argparse                      # CLI parsing
from flask import Flask, Response, send_file  # HTTP server
from io import BytesIO               # Memory buffer for JPEGs
import av                            # PyAV for decoding
from turbojpeg import TurboJPEG      # TurboJPEG for fast JPEG encoding

# Parse optional HTTP port argument
parser = argparse.ArgumentParser(description="RTSP JPEG snapshot server")
parser.add_argument('--port', type=int, default=5050, help='Port for Flask server (default: 5050)')
args = parser.parse_args()
PORT = args.port

# Global Flask app and runtime data
app = Flask(__name__)
CAMERAS = {}  # name → {source, container, process, latest_frame, latest_jpeg}
JPEG_ENCODER = TurboJPEG()
CONFIG_PATH = '/usr/local/etc/mediamtx.yml'

def parse_mediamtx_config():
    """
    Reads mediamtx.yml and extracts RTSP camera definitions.
    Only entries with 'source: publisher' and a valid 'rtsp://' link in 'runOnInit' are accepted.
    """
    if not os.path.exists(CONFIG_PATH):
        raise FileNotFoundError(f"Config not found: {CONFIG_PATH}")
    
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

def capture_loop(name):
    """
    Threaded loop that launches ffmpeg to decode RTSP video,
    extracts latest frame via PyAV and stores it in memory.
    """
    cam = CAMERAS[name]
    cmd = [
        'ffmpeg',
        '-fflags', 'nobuffer',
        '-flags', 'low_delay',
        '-strict', 'experimental',
        '-fflags', '+genpts',
        '-avioflags', 'direct',
        '-probesize', '512k',
        '-analyzeduration', '0',
        '-rtsp_transport', 'tcp',
        '-i', cam['source'],
        '-an', '-c:v', 'copy',
        '-f', 'mpegts',
        '-'
    ]

    while True:
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            cam['process'] = proc
            container = av.open(proc.stdout, mode='r')
            cam['container'] = container

            for packet in container.demux(video=0):
                for frame in packet.decode():
                    cam['latest_frame'] = frame
                    cam['latest_jpeg'] = None
        except av.AVError:
            time.sleep(5)
        except Exception:
            time.sleep(5)

def serve_snapshot(name):
    """
    Flask route to return a JPEG snapshot from a named camera.
    Returns 404 if not found, 503 if frame isn't ready.
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

# Register dynamic route
app.add_url_rule('/<name>.jpg', view_func=serve_snapshot)

def cleanup():
    """
    Cleanly terminates all ffmpeg subprocesses on shutdown.
    """
    for cam in CAMERAS.values():
        proc = cam.get('process')
        if proc:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()

# Main execution
if __name__ == '__main__':
    try:
        parse_mediamtx_config()
    except Exception as e:
        print(f"Config error: {e}")
        sys.exit(1)

    if not CAMERAS:
        print("No valid RTSP publishers found.")
        sys.exit(1)

    for name in CAMERAS:
        t = threading.Thread(target=capture_loop, args=(name,), daemon=True)
        t.start()

    atexit.register(cleanup)
    time.sleep(1)
    app.run(host='0.0.0.0', port=PORT)
