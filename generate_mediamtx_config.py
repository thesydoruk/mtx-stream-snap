#!/usr/bin/env python3

"""
generate_mediamtx_config.py
---------------------------
Updates /usr/local/etc/mediamtx.yml by:
- Enabling required services (rtsp, webrtc)
- Disabling unused services (rtmp, hls, etc.)
- Adding STUN server if empty
- Generating 'paths:' section from /dev/video* list
- Choosing best format/res/fps and using VAAPI if available
- Supports --dry-run (no write, output to stdout)

Dependencies:
  - ruamel.yaml (installed via apt as python3-ruamel.yaml)
  - ffmpeg, v4l2-ctl
"""

import os
import re
import sys
import argparse
import subprocess
from collections import defaultdict
from ruamel.yaml import YAML
from pathlib import Path

# --------------------------------------------------------
# CONFIG
# --------------------------------------------------------
CONFIG_PATH = Path("/usr/local/etc/mediamtx.yml")
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

# --------------------------------------------------------
# Parse CLI
# --------------------------------------------------------
parser = argparse.ArgumentParser(description="Update mediamtx.yml with camera paths and service flags")
parser.add_argument("--dry-run", action="store_true", help="Output result without saving")
args = parser.parse_args()

# --------------------------------------------------------
# Helpers
# --------------------------------------------------------

def has_vaapi_encoder():
    try:
        test_cmd = [
            "ffmpeg",
            "-hide_banner",
            "-f", "lavfi",
            "-i", "testsrc",
            "-frames:v", "1",
            "-vaapi_device", "/dev/dri/renderD128",
            "-vf", "format=nv12,hwupload",
            "-c:v", "h264_vaapi",
            "-f", "null",
            "-"
        ]
        result = subprocess.run(test_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return result.returncode == 0
    except Exception:
        return False

def list_video_devices():
    return sorted([
        f"/dev/{d}" for d in os.listdir("/dev") if re.match(r"video\d+", d)
    ])

def run_v4l2ctl(device):
    try:
        return subprocess.check_output(["v4l2-ctl", "--list-formats-ext", "-d", device], stderr=subprocess.DEVNULL).decode()
    except Exception:
        return None

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

# --------------------------------------------------------
# Load existing YAML config
# --------------------------------------------------------
yaml = YAML()
yaml.preserve_quotes = True

if not CONFIG_PATH.exists():
    print(f"❌ mediamtx config not found: {CONFIG_PATH}", file=sys.stderr)
    sys.exit(1)

with CONFIG_PATH.open("r") as f:
    config = yaml.load(f)

# --------------------------------------------------------
# Update top-level flags
# --------------------------------------------------------
for key in FLAGS_OFF:
    config[key] = "no"

for key in FLAGS_ON:
    config[key] = "yes"

# Add STUN server
config["webrtcICEServers2"] = [{"url": "stun:stun.l.google.com:19302"}]

# --------------------------------------------------------
# Generate paths block
# --------------------------------------------------------
use_vaapi = has_vaapi_encoder()

all_others = config["paths"].pop("all_others")

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

config["paths"]["all_others"] = all_others

# --------------------------------------------------------
# Output or save
# --------------------------------------------------------
if args.dry_run:
    print("🔍 Dry run (config will not be written):\n")
    yaml.dump(config, sys.stdout)
else:
    with CONFIG_PATH.open("w") as f:
        yaml.dump(config, f)
    print(f"✅ mediamtx.yml updated (VAAPI: {'yes' if use_vaapi else 'no'})")
