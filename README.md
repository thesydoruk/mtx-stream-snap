# MediaMTX + SnapFeeder Auto Installer

This package sets up a complete local RTSP + JPEG snapshot system on Raspberry Pi (4/5) or compatible Linux machines.

## Components

- **MediaMTX**: RTSP/WebRTC server with FFmpeg backend
- **SnapFeeder**: Flask server for on-demand JPEG snapshots from RTSP streams
- **generate_mediamtx_config.py**: Auto-generates `mediamtx.yml` with optimized camera configuration

## Features

- Detects all connected `/dev/video*` cameras
- Selects optimal format (`mjpeg` preferred) and resolution (1280x720 if available)
- Sets best fps per resolution
- Uses **VAAPI hardware acceleration** if available and functional
- Auto-configures `mediamtx.yml`:
  - Enables: `rtsp`, `webrtc`
  - Disables: `rtmp`, `hls`, `api`, `metrics`, `pprof`, `playback`, `srt`
  - Adds STUN server (`stun:stun.l.google.com:19302`) if missing
- Installs `mediamtx` and `snapfeeder.py` to `/usr/local/bin`
- Creates and enables systemd services:
  - `mediamtx.service`
  - `snapfeeder.service`

## Requirements

- OS: Debian-based (Raspberry Pi OS, Ubuntu)
- Python 3.6+
- APT packages:
  - `python3`, `python3-pip`, `python3-flask`, `python3-av`, `python3-numpy`
  - `ffmpeg`, `v4l-utils`, `libturbojpeg0`, `python3-ruamel.yaml`
- If `python3-turbojpeg` is not available, `PyTurboJPEG` is installed via pip

## Installation

Run from the project directory:

```bash
chmod +x install.sh
./install.sh
```

The script will:
- Install dependencies
- Download the correct MediaMTX release
- Generate camera-specific config using `generate_mediamtx_config.py`
- Install and start both services

## Snapshot Access

Each detected camera gets a full set of access URLs. At the end of installation, the script prints something like:

```
🎥 cam2:
   📡 RTSP:     rtsp://<ip>:8554/cam2
   🖼️ Snapshot: http://<ip>:5050/cam2.jpg
   🌐 WebRTC:   http://<ip>:8889/cam2/
```

## Developer Tools

Test configuration output without writing:

```bash
python3 generate_mediamtx_config.py --dry-run
```

## Uninstallation

```bash
chmod +x uninstall.sh
./uninstall.sh
```

This will:
- Stop and disable services
- Remove binaries, systemd units, and config files

## License

MIT
