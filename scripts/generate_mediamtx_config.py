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
- Uses hardware encoder if test passes (vaapi, rkmpp, v4l2m2m)
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

FLAGS_ON = ["rtsp", "webrtc", "hls"]
FLAGS_OFF = ["rtmp", "api", "metrics", "pprof", "playback", "srt"]

def list_available_hwaccels():
    try:
        result = subprocess.run(
            ["ffmpeg", "-hide_banner", "-hwaccels"],
            capture_output=True, text=True
        )
        lines = result.stdout.splitlines()
        return [line.strip() for line in lines if line.strip() and not line.startswith("Hardware")]
    except Exception:
        return []

AVAILABLE_HWACCELS = list_available_hwaccels()


def has_vaapi_encoder():
    """
    Checks whether VAAPI hardware encoder (h264_vaapi) is available
    by running a test FFmpeg command using synthetic input.
    """
    try:
        test_cmd = [
            "ffmpeg", "-hide_banner",
            "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=5",
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

def has_rkmpp_encoder():
    """
    Checks whether Rockchip MPP encoder (h264_rkmpp) is available
    by running a test FFmpeg command with synthetic input and nv12 format.
    """
    try:
        test_cmd = [
            "ffmpeg", "-hide_banner",
            "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=5",
            "-frames:v", "1",
            "-pix_fmt", "nv12",
            "-c:v", "h264_rkmpp",
            "-f", "null", "-"
        ]
        result = subprocess.run(test_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return result.returncode == 0
    except Exception:
        return False

def has_v4l2m2m_encoder():
    """
    Checks whether V4L2 M2M encoder (h264_v4l2m2m) is available
    by running a test FFmpeg command with synthetic input and yuv420p format.
    """
    try:
        test_cmd = [
            "ffmpeg", "-hide_banner",
            "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=5",
            "-frames:v", "1",
            "-c:v", "h264_v4l2m2m",
            "-pix_fmt", "yuv420p",
            "-f", "null", "-"
        ]
        result = subprocess.run(test_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return result.returncode == 0
    except Exception:
        return False

def list_video_devices():
    """
    Lists all available video input devices in /dev that match /dev/video*.
    Returns a sorted list of full paths like ['/dev/video0', '/dev/video1', ...].
    """
    return sorted([
        f"/dev/{d}" for d in os.listdir("/dev") if re.match(r"video\d+", d)
    ])

def run_v4l2ctl(device):
    """
    Runs `v4l2-ctl --list-formats-ext` for the given device path.
    Returns decoded output as a string, or None on failure.
    """
    try:
        return subprocess.check_output(
            ["v4l2-ctl", "--list-formats-ext", "-d", device],
            stderr=subprocess.DEVNULL
        ).decode()
    except Exception:
        return None

def parse_formats(v4l2_output):
    """
    Parses the output of `v4l2-ctl --list-formats-ext` and returns
    a nested dictionary:
        { format: { resolution: [fps, ...] } }
    """
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
    """
    Selects the best available format-resolution-FPS combination
    based on FORMAT_PRIORITY and preferred resolution.

    Returns a tuple: (format, resolution, fps)
    """
    for fmt in FORMAT_PRIORITY:
        if fmt not in formats_by_type:
            continue

        resolutions = formats_by_type[fmt]
        resolution = (
            PREFERRED_RES if PREFERRED_RES in resolutions else
            sorted(resolutions, key=lambda r: tuple(map(int, r.split('x'))), reverse=True)[0]
        )
        fps = max(resolutions[resolution])
        return fmt, resolution, fps

    return None, None, None

def build_ffmpeg_cmd(device, fmt, res, fps, cam_id, use_vaapi, use_rkmpp, use_v4l2m2m):
    """
    Builds a ffmpeg command using available hardware encoders and optional hwaccel support.
    """
    gop = max(1, fps // 2)
    rtsp_url = f"rtsp://localhost:8554/{cam_id}"

    input_args = [
        "-f", "v4l2",
        "-input_format", fmt,
        "-video_size", res,
        "-framerate", str(fps),
        "-i", device
    ]

    encoder_args = ["-vf", "hqdn3d"]
    hwaccel_args = []

    if use_vaapi:
        if "vaapi" in AVAILABLE_HWACCELS:
            hwaccel_args += ["-hwaccel", "vaapi", "-vaapi_device", "/dev/dri/renderD128"]
        encoder_args += ["-vf", "format=nv12,hwupload", "-c:v", "h264_vaapi"]

    elif use_rkmpp:
        if ("rkmpp" in AVAILABLE_HWACCELS and "drm" in AVAILABLE_HWACCELS):
            hwaccel_args += ["-hwaccel", "rkmpp", "-hwaccel_output_format", "drm_prime"]
        encoder_args += ["-pix_fmt", "nv12", "-c:v", "h264_rkmpp"]

    elif use_v4l2m2m:
        if "v4l2m2m" in AVAILABLE_HWACCELS:
            hwaccel_args += ["-hwaccel", "v4l2m2m"]
        encoder_args += ["-pix_fmt", "yuv420p", "-c:v", "h264_v4l2m2m"]

    else:
        encoder_args += ["-c:v", "libx264", "-preset", "ultrafast"]

    encoder_args += ["-b:v", "4M", "-tune", "zerolatency"]
    output_args = ["-g", str(gop), "-bf", "0", "-f", "rtsp", rtsp_url]

    cmd = ["ffmpeg", "-y"] + hwaccel_args + input_args + encoder_args + output_args
    return " ".join(cmd)


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

# Detect hardware encoder support
use_vaapi = has_vaapi_encoder()
use_rkmpp = has_rkmpp_encoder()
use_v4l2m2m = has_v4l2m2m_encoder()

# Clear camera-specific entries (preserving all_others)
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
        "runOnInit": build_ffmpeg_cmd(dev, fmt, res, fps, cam_id, use_vaapi, use_rkmpp, use_v4l2m2m),
        "runOnInitRestart": "yes"
    }

# Reattach all_others
config["paths"]["all_others"] = all_others

# Write updated config to disk
with CONFIG_PATH.open("w") as f:
    yaml.dump(config, f)

print(f"✅ mediamtx.yml updated (VAAPI: {'yes' if use_vaapi else 'no'})")
