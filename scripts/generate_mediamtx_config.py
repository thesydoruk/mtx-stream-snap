#!/usr/bin/env python3

"""
generate_mediamtx_config.py
---------------------------
Regenerates the 'paths' section in ../mediamtx/mediamtx.yml based on connected
/dev/video* devices. Applies optimal stream settings and enables only relevant
MediaMTX protocols.

Behavior:
- Enables: rtsp, webrtc
- Disables: rtmp, hls, metrics, etc.
- Adds default STUN server
- Chooses best available format (mjpeg preferred), resolution (1280x720 if possible), and max fps
- Uses VAAPI encoder if test passes
"""

import os
import re
import sys
import subprocess
from collections import defaultdict
from ruamel.yaml import YAML
from pathlib import Path

# Config path relative to this script (scripts/) → ../mediamtx/mediamtx.yml
CONFIG_PATH = Path(__file__).resolve().parent.parent / "mediamtx" / "mediamtx.yml"
PREFERRED_RES = "1280x720"
FORMAT_PRIORITY = ["mjpeg", "h264", "nv12", "yuv420", "yuyv422", "rawvideo"]
FORMAT_ALIASES = {
    "mjpg": "mjpeg",
    "yuyv": "yuyv422",
    "yu12": "yuv420",
    "rgb3": "rawvideo",
    "bgr3": "rawvideo",
}

FLAGS_ON = ["rtsp", "webrtc"]
FLAGS_OFF = ["rtmp", "hls", "api", "metrics", "pprof", "playback", "srt"]

# VAAPI check: try real ffmpeg run with hardware encoder
def has_vaapi_encoder():
    try:
        test_cmd = [
            "ffmpeg", "-hide_banner",
            "-f", "lavfi", "-i", "testsrc",
            "-frames:v", "1",
            "-vaapi_device", "/dev/dri/renderD128",
            "-vf", "format=nv12,hwupload",
            "-c:v", "h264_vaapi",
            "-f", "null", "-"
        ]
        result = subprocess.run(test_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return result.returncode == 0
    except Exception:
        return False

# List all /dev/video* devices
def list_video_devices():
    return sorted([
        f"/dev/{d}" for d in os.listdir("/dev") if re.match(r"video\d+", d)
    ])

# Call v4l2-ctl to get camera format details
def run_v4l2ctl(device):
    try:
        return subprocess.check_output(["v4l2-ctl", "--list-formats-ext", "-d", device], stderr=subprocess.DEVNULL).decode()
    except Exception:
        return None

# Parse v4l2-ctl output into {format: {resolution: [fps]}}
def parse_formats(v4l2_output):
    formats = defaultdict(lambda: defaultdict(list))
    current_format = None
    current_res = None

    for line in v4l2_output.splitlines():
        line = line.strip()

        match = re.match(r"\[\d+\]: '(\w+)'", line)
        if match:
            raw = match.group(1).lower()
            current_format = FORMAT_ALIASES.get(raw, raw)
            continue

        match = re.match(r"Size: Discrete (\d+x\d+)", line)
        if match and current_format:
            current_res = match.group(1)
            continue

        match = re.match(r"Interval: Discrete \d+\.\d+s \(([\d\.]+) fps\)", line)
        if match and current_format and current_res:
            fps = round(float(match.group(1)))
            formats[current_format][current_res].append(fps)

    return formats

# Choose best format → resolution → fps combo
def select_best_format(formats_by_type):
    for fmt in FORMAT_PRIORITY:
        if fmt not in formats_by_type:
            continue
        resolutions = formats_by_type[fmt]
        resolution = PREFERRED_RES if PREFERRED_RES in resolutions else sorted(
            resolutions, key=lambda r: tuple(map(int, r.split('x'))), reverse=True
        )[0]
        fps = max(resolutions[resolution])
        return fmt, resolution, fps
    return None, None, None

# Build ffmpeg runOnInit command for a specific camera
def build_ffmpeg_cmd(device, fmt, res, fps, cam_id, use_vaapi):
    gop = max(1, fps // 2)
    rtsp_url = f"rtsp://localhost:8554/{cam_id}"

    if use_vaapi:
        return (
            f"ffmpeg -y -f v4l2 -input_format {fmt} -video_size {res} -framerate {fps} -i {device} "
            f"-vf 'format=nv12,hwupload' -c:v h264_vaapi -g {gop} -bf 0 "
            f"-f rtsp {rtsp_url}"
        )
    else:
        return (
            f"ffmpeg -y -f v4l2 -input_format {fmt} -video_size {res} -framerate {fps} -i {device} "
            f"-c:v libx264 -preset ultrafast -tune zerolatency -g {gop} -bf 0 "
            f"-f rtsp {rtsp_url}"
        )

# Load, modify, and save mediamtx config
yaml = YAML()
yaml.preserve_quotes = True

if not CONFIG_PATH.exists():
    print(f"❌ Config file not found: {CONFIG_PATH}", file=sys.stderr)
    sys.exit(1)

with CONFIG_PATH.open("r") as f:
    config = yaml.load(f)

# Enable desired protocols and disable others
for key in FLAGS_OFF:
    config[key] = "no"
for key in FLAGS_ON:
    config[key] = "yes"

# Add WebRTC ICE STUN server
config["webrtcICEServers2"] = [{"url": "stun:stun.l.google.com:19302"}]

# Clear camera-specific entries (preserving all_others)
use_vaapi = has_vaapi_encoder()
all_others = config["paths"].pop("all_others", {})

# Autodetect and configure each /dev/video* device
for dev in list_video_devices():
    match = re.search(r"video(\d+)", dev)
    if not match:
        continue
    cam_id = f"cam{match.group(1)}"

    raw = run_v4l2ctl(dev)
    if not raw:
        continue

    formats = parse_formats(raw)
    fmt, res, fps = select_best_format(formats)
    if not all([fmt, res, fps]):
        continue

    config["paths"][cam_id] = {
        "source": "publisher",
        "runOnInit": build_ffmpeg_cmd(dev, fmt, res, fps, cam_id, use_vaapi),
        "runOnInitRestart": "yes"
    }

# Reattach all_others
config["paths"]["all_others"] = all_others

# Write updated config to disk
with CONFIG_PATH.open("w") as f:
    yaml.dump(config, f)

print(f"✅ mediamtx.yml updated (VAAPI: {'yes' if use_vaapi else 'no'})")
