# MediaMTX + SnapFeeder Auto Installer

[![CI](https://github.com/thesydoruk/mtx-stream-snap/actions/workflows/ci.yml/badge.svg)](https://github.com/thesydoruk/mtx-stream-snap/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/thesydoruk/mtx-stream-snap)](https://github.com/thesydoruk/mtx-stream-snap/releases)

This project provides a complete, self-contained RTSP + JPEG snapshot system using:

- **MediaMTX** for RTSP and WebRTC streaming with FFmpeg backend
- **SnapFeeder**, a Flask server that serves JPEG snapshots on-demand
- A Python-based configuration generator that automatically detects connected cameras and sets up MediaMTX accordingly

---

## 📁 Project Structure

```
mtx-stream-snap/
├── install.sh                # Full setup script (also used for upgrades)
├── uninstall.sh              # Cleanup script
├── VERSION                   # Current project version
├── CHANGELOG.md              # Release notes
├── mediamtx/                 # Holds downloaded MediaMTX binary and mediamtx.yml
│   ├── mediamtx
│   └── mediamtx.yml
├── scripts/                  # All project Python logic
│   ├── generate_mediamtx_config.py
│   └── snapfeeder.py
├── templates/                # Template .service files with placeholders
│   ├── mediamtx.service.template
│   └── snapfeeder.service.template
├── tests/
│   └── smoke_test.sh         # End-to-end test used by CI
├── venv/                     # Python virtual environment
└── services/                 # Populated during install with rendered .service files
```

---

## ✅ Features

- Provides an option to install an optimized FFmpeg build with hardware acceleration support on Rockchip platforms.
- Detects all `/dev/video*` USB cameras
- Chooses the best format:
  - Prefers `mjpeg`, falls back to others
  - Picks `1280x720` if supported, otherwise selects the highest available resolution
  - Caps default FPS at `30` for the chosen resolution
- Leverages hardware acceleration if available:
  - ✅ VAAPI (Intel/AMD GPU)
  - ✅ RKMPP (Rockchip)
  - ✅ V4L2M2M (Raspberry Pi)
  - Software fallback: `libx264`, or `libopenh264` where the distro's ffmpeg has no x264
  - Each encoder is verified with a test encode before it is used
- Configures `mediamtx.yml` with:
  - Enabled: `rtsp`, `webrtc`, `hls`
  - Disabled: `rtmp`, `api`, `metrics`, `pprof`, `playback`, `srt`
  - Adds Google STUN server for WebRTC
- Snapshot server:
  - Reads the MediaMTX config
  - Decodes RTSP of each camera using PyAV
  - Encodes JPEG snapshots via TurboJPEG only when requested
    (falls back to PyAV's built-in MJPEG encoder when libturbojpeg is missing or incompatible)
  - Provides dynamic endpoints: `/cam0.jpg`, `/cam1.jpg`, etc.

---

## 🚀 Installation

### Supported systems

Any systemd-based Linux with one of these package managers: `apt`, `dnf`, `pacman`, `zypper`.
Every change is tested in CI on:

| Distribution | Architectures |
|---|---|
| Debian 12, 13 (also Raspberry Pi OS, Armbian, DietPi) | amd64, arm64 |
| Ubuntu 22.04, 24.04 | amd64 |
| Fedora (latest) | amd64 |
| Arch Linux | amd64 |
| openSUSE Tumbleweed | amd64 |

On Fedora and openSUSE the stock ffmpeg has no x264, so streams are encoded with OpenH264
(installed automatically) unless a hardware encoder is available.

Install a released version (see [Releases](https://github.com/thesydoruk/mtx-stream-snap/releases) for the latest tag):

```bash
cd ~
git clone --branch v1.0.0 --depth 1 https://github.com/thesydoruk/mtx-stream-snap.git
cd mtx-stream-snap
bash install.sh
```

Cloning without `--branch` installs the development version from `main`.

This will:

- Install system dependencies with the system package manager (`libturbojpeg` and OpenH264 are
  optional and installed when the distro provides them)
- Add the service to the `video` and `render` groups (when they exist) for camera and GPU access
- Create a Python virtual environment
- Download the MediaMTX release tested with this version into `mediamtx/`
  (override with `MEDIAMTX_VERSION=v1.x.y bash install.sh`, or `MEDIAMTX_VERSION=latest`)
- Generate `mediamtx.yml` using `scripts/generate_mediamtx_config.py` (only if it does not exist yet)
- Create `.service` files from `templates/` and write them to `services/`
- Install rendered systemd unit files into `/etc/systemd/system/`
- Enable and start `mediamtx` and `snapfeeder` services (with startup readiness checks)
- Print available camera URLs

---

## ⬆️ Upgrading

```bash
cd ~/mtx-stream-snap
git fetch --tags
git checkout v1.1.0        # the release you want
bash install.sh
```

`install.sh` updates MediaMTX, the Python environment and the services, but keeps your
existing `mediamtx/mediamtx.yml`. To recreate it from scratch (for example after connecting
new cameras), run:

```bash
bash install.sh --regenerate-config
```

The previous config is saved as `mediamtx.yml.bak.<timestamp>`.
See [CHANGELOG.md](CHANGELOG.md) for what changed between versions.

---

## 🔍 Camera Access

After installation, each camera is available via:

```
🎥 cam0:
   📡 RTSP:     rtsp://<ip>:8554/cam0
   🌐 WebRTC:   http://<ip>:8889/cam0/
   📺 HLS:      http://<ip>:8888/cam0/index.m3u8
   🖼️ Snapshot: http://<ip>:5050/cam0.jpg
```

---

## 🌕 Moonraker Integration (Fluidd/Mainsail)

To display camera streams and snapshots in Moonraker interfaces like Fluidd or Mainsail, add the following to your `moonraker.conf`:

**Using WebRTC stream:**
```ini
[webcam cam0]
service: webrtc-mediamtx
stream_url: http://<ip>:8889/cam0/
snapshot_url: http://<ip>:5050/cam0.jpg
```

**Using HLS stream:**
```ini
[webcam cam0]
service: hlsstream
stream_url: http://<ip>:8888/cam0/index.m3u8
snapshot_url: http://<ip>:5050/cam0.jpg
```

Repeat for additional cameras (`cam1`, `cam2`, etc.) if needed.

Make sure that:
- Ports 8889 (MediaMTX WebRTC), 8888 (MediaMTX HLS) and 5050 (SnapFeeder) are reachable
- Your reverse proxy (e.g., NGINX) forwards these paths properly

**Example NGINX config:**

```nginx
# For WebRTC
location /cam0/ {
    proxy_pass http://127.0.0.1:8889/cam0/;
}

# For HLS
location /cam0_hls/ {
    proxy_pass http://127.0.0.1:8888/cam0/;
}

# For SnapFeeder
location /cam0.jpg {
    proxy_pass http://127.0.0.1:5050/cam0.jpg;
}
```

Once configured, you can omit the protocol, host, and port in `moonraker.conf` URLs.
If you want to use WebRTC and HLS together, make sure each uses a distinct NGINX location block (e.g., `/cam0/` for WebRTC and `/cam0_hls/` for HLS).

---

## 🧹 Uninstallation

```bash
cd ~/mtx-stream-snap
bash uninstall.sh
```

This will:

- Stop and disable both services
- Remove service files from `/etc/systemd/system/`
- Delete the `services/`, `mediamtx/` and `venv/` directories

---

## ⚙️ Manual Resolution / FPS Tuning

If you want to use a custom resolution or framerate, edit `mediamtx/mediamtx.yml` manually.

Each camera (`cam0`, `cam1`, etc.) has a `runOnInit` FFmpeg command, for example:

```yaml
paths:
  cam0:
    source: publisher
    runOnInit: ffmpeg -y -hide_banner -nostats -loglevel warning -f v4l2 -input_format mjpeg -video_size 1280x720 -framerate 30 -i /dev/video0 ...
    runOnInitRestart: true
```

Change these two arguments in `runOnInit`:
- `-video_size 1280x720` → your target resolution (for example `1920x1080`)
- `-framerate 30` → your target FPS (for example `25`)

After editing, apply changes:

```bash
sudo systemctl restart mediamtx.service
```

Notes:
- Use only modes supported by your camera (`v4l2-ctl --list-formats-ext -d /dev/videoX`).
- Rerunning `install.sh` keeps your edited `mediamtx.yml`; only `bash install.sh --regenerate-config` overwrites it (with a backup).

---

## 🔧 Development Notes

- `generate_mediamtx_config.py` and `snapfeeder.py` use project-root-relative paths
- No environment variables are required
- All Python logic is inside the `scripts/` directory
- `bash tests/smoke_test.sh` runs the end-to-end test locally on Linux (needs `ffmpeg` and free
  ports 8554/5050, so stop the installed services first). `bash install.sh --deps-only` installs
  just the dependencies; pass `VENV_DIR=$PWD/venv` to the smoke test to reuse that venv.
- `SNAPFEEDER_JPEG_ENCODER=pyav` forces snapfeeder to use the PyAV JPEG encoder

---

## 🏷️ Releasing

CI runs on every push to `main` and on pull requests: ShellCheck, syntax checks and an
end-to-end smoke test (`install.sh --deps-only`, then MediaMTX + snapfeeder with a synthetic
camera) in containers of every supported distribution.

To publish a release:

1. Move the entries from `## [Unreleased]` in `CHANGELOG.md` to a new `## [X.Y.Z] - YYYY-MM-DD` section
   and update the links at the bottom.
2. Put `X.Y.Z` into `VERSION`.
3. If a newer MediaMTX was tested, bump `MEDIAMTX_VERSION` in `install.sh`.
4. Commit, then tag and push:
   ```bash
   git tag vX.Y.Z
   git push origin main vX.Y.Z
   ```

The `Release` workflow re-runs CI, checks that the tag matches `VERSION` and creates a
GitHub Release with the notes from `CHANGELOG.md`.

Versioning follows [SemVer](https://semver.org/): `PATCH` for fixes, `MINOR` for new
features, `MAJOR` for changes that require manual steps when upgrading.

---

## 📜 License

MIT License  
(c) 2025 Valerii Sydoruk
