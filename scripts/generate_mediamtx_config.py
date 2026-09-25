#!/usr/bin/env python3

"""
generate_mediamtx_config.py
---------------------------
Regenerates the 'paths' section in ../mediamtx/mediamtx.yml based on connected
/dev/video* devices. Applies optimal stream settings and enables only relevant
MediaMTX protocols.

Behavior:
- Enables: rtsp, webrtc, hls
- Disables: rtmp, api, metrics, pprof, playback, srt
- Adds default STUN server
- Chooses best available format (mjpeg preferred), resolution (1280x720 if possible), and max fps
- Picks the first H.264 encoder that passes a test encode:
  vaapi, rkmpp, v4l2m2m, libx264, libopenh264 (ffmpeg builds differ between distros)
- Adds the hqdn3d denoise filter only when this ffmpeg build has it
"""

import os
import re
import sys
import subprocess
from collections import defaultdict
from pathlib import Path

# Config path relative to this script (scripts/) → ../mediamtx/mediamtx.yml
CONFIG_PATH = Path(__file__).resolve().parent.parent / "mediamtx" / "mediamtx.yml"
PREFERRED_RES = "1280x720"
MAX_DEFAULT_FPS = 30
FORMAT_PRIORITY = ["mjpeg", "h264", "nv12", "yuv420p", "yuyv422", "rgb24", "bgr24"]
FORMAT_ALIASES = {
    "mjpg": "mjpeg",
    "yuyv": "yuyv422",
    "yu12": "yuv420p",
    "rgb3": "rgb24",
    "bgr3": "bgr24",
}

FLAGS_ON = ["rtsp", "webrtc", "hls"]
FLAGS_OFF = ["rtmp", "api", "metrics", "pprof", "playback", "srt"]

VAAPI_DEVICE = "/dev/dri/renderD128"
TEST_SOURCE = ["-f", "lavfi", "-i", "testsrc2=size=128x128:rate=5", "-frames:v", "1"]

# H.264 encoders in order of preference. "filters" are appended to the video
# filter chain, "args" select the encoder. Browsers (WebRTC/HLS) need 4:2:0.
ENCODERS = [
    {
        "name": "vaapi",
        "hwaccel": "vaapi",
        "global_args": ["-vaapi_device", VAAPI_DEVICE],
        "filters": ["format=nv12", "hwupload"],
        "args": ["-c:v", "h264_vaapi"],
    },
    {
        "name": "rkmpp",
        "hwaccel": "rkmpp",
        "global_args": [],
        "filters": [],
        "args": ["-pix_fmt", "nv12", "-c:v", "h264_rkmpp"],
    },
    {
        "name": "v4l2m2m",
        "hwaccel": "v4l2m2m",
        "global_args": [],
        "filters": [],
        "args": ["-pix_fmt", "yuv420p", "-c:v", "h264_v4l2m2m"],
    },
    {
        "name": "libx264",
        "hwaccel": None,
        "global_args": [],
        "filters": [],
        "args": ["-pix_fmt", "yuv420p", "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency"],
    },
    {
        # Fedora/openSUSE ship ffmpeg without x264 but with OpenH264
        "name": "libopenh264",
        "hwaccel": None,
        "global_args": [],
        "filters": [],
        "args": ["-pix_fmt", "yuv420p", "-c:v", "libopenh264"],
    },
]


def run_ffmpeg(args, timeout=30):
    """
    Runs ffmpeg with the given arguments. Returns CompletedProcess, or None when
    ffmpeg is missing or hangs.
    """
    try:
        return subprocess.run(
            ["ffmpeg", "-hide_banner"] + args,
            capture_output=True, text=True, timeout=timeout
        )
    except (OSError, subprocess.TimeoutExpired):
        return None


def list_available_hwaccels():
    result = run_ffmpeg(["-hwaccels"])
    if not result:
        return []
    return [line.strip() for line in result.stdout.splitlines()
            if line.strip() and not line.startswith("Hardware")]


def has_filter(name):
    """
    Checks whether this ffmpeg build provides the given video filter
    (LGPL builds lack GPL filters such as hqdn3d).
    """
    result = run_ffmpeg(["-filters"])
    if not result:
        return False
    pattern = re.compile(rf"\s*\S+\s+{re.escape(name)}\s")
    return any(pattern.match(line) for line in result.stdout.splitlines())


def encoder_works(encoder):
    """
    Runs a one-frame test encode with synthetic input to check that the encoder
    is both compiled in and usable on this machine.
    """
    vf = ",".join(encoder["filters"])
    args = (encoder["global_args"] + TEST_SOURCE + (["-vf", vf] if vf else [])
            + encoder["args"] + ["-f", "null", "-"])
    result = run_ffmpeg(["-loglevel", "error"] + args)
    return result is not None and result.returncode == 0


def detect_encoder():
    """
    Returns the first working encoder from ENCODERS, or None.
    """
    for encoder in ENCODERS:
        if encoder_works(encoder):
            return encoder
    return None


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
        fps = min(max(resolutions[resolution]), MAX_DEFAULT_FPS)
        return fmt, resolution, fps

    return None, None, None

def build_input_args(device, fmt, res, fps):
    return [
        "-f", "v4l2",
        "-input_format", fmt,
        "-video_size", res,
        "-framerate", str(fps),
        "-i", device
    ]


def build_ffmpeg_cmd(input_args, fps, cam_id, encoder, denoise=True, hwaccels=()):
    """
    Builds the ffmpeg command publishing input_args as H.264 to MediaMTX.
    """
    gop = max(1, fps // 2)
    rtsp_url = f"rtsp://localhost:8554/{cam_id}"

    # Only warnings and errors: progress stats would flood the MediaMTX log / journal
    log_args = ["-hide_banner", "-nostats", "-loglevel", "warning"]

    hwaccel_args = []
    if encoder["hwaccel"] and encoder["hwaccel"] in hwaccels:
        hwaccel_args += ["-hwaccel", encoder["hwaccel"]]
    hwaccel_args += encoder["global_args"]

    # ffmpeg honors only the last -vf, so the whole filter chain goes into one
    filters = (["hqdn3d"] if denoise else []) + encoder["filters"]
    filter_args = ["-vf", ",".join(filters)] if filters else []

    encoder_args = filter_args + encoder["args"] + ["-b:v", "4M"]
    output_args = ["-g", str(gop), "-bf", "0", "-f", "rtsp", rtsp_url]

    cmd = ["ffmpeg", "-y"] + log_args + hwaccel_args + input_args + encoder_args + output_args
    return " ".join(cmd)


def main():
    from ruamel.yaml import YAML

    # Load, modify, and save mediamtx config
    yaml = YAML()
    yaml.preserve_quotes = True

    if not CONFIG_PATH.exists():
        print(f"❌ Config file not found: {CONFIG_PATH}", file=sys.stderr)
        sys.exit(1)

    encoder = detect_encoder()
    if encoder is None:
        tried = ", ".join(e["name"] for e in ENCODERS)
        print(f"❌ No working H.264 encoder found in ffmpeg (tried: {tried}).\n"
              "   Install an ffmpeg build with libx264 or OpenH264 support.", file=sys.stderr)
        sys.exit(1)
    denoise = has_filter("hqdn3d")
    hwaccels = list_available_hwaccels()

    with CONFIG_PATH.open("r") as f:
        config = yaml.load(f)

    # Enable desired protocols and disable others
    for key in FLAGS_OFF:
        config[key] = False
    for key in FLAGS_ON:
        config[key] = True

    # Add WebRTC ICE STUN server
    config["webrtcICEServers2"] = [{"url": "stun:stun.l.google.com:19302"}]

    # Clear camera-specific entries (preserving all_others)
    if config.get("paths") is None:
        config["paths"] = {}
    for key in [k for k in config["paths"] if re.fullmatch(r"cam\d+", str(k))]:
        del config["paths"][key]
    all_others = config["paths"].pop("all_others", None)

    # Autodetect and configure each /dev/video* device
    cameras = []
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

        input_args = build_input_args(dev, fmt, res, fps)
        config["paths"][cam_id] = {
            "source": "publisher",
            "runOnInit": build_ffmpeg_cmd(input_args, fps, cam_id, encoder, denoise, hwaccels),
            "runOnInitRestart": True
        }
        cameras.append(f"{cam_id} ({dev}, {fmt} {res}@{fps})")

    # Reattach all_others
    config["paths"]["all_others"] = all_others

    # Write updated config to disk
    with CONFIG_PATH.open("w") as f:
        yaml.dump(config, f)

    denoise_state = "yes" if denoise else "no"
    print(f"✅ mediamtx.yml updated (encoder: {encoder['name']}, denoise: {denoise_state})")
    for cam in cameras:
        print(f"   🎥 {cam}")
    if not cameras:
        print("   ⚠️  No usable /dev/video* cameras found")


if __name__ == "__main__":
    main()
