# MediaMTX + SnapFeeder Auto Installer

This project provides a complete, self-contained RTSP + JPEG snapshot system using:

- **MediaMTX** for RTSP and WebRTC streaming with FFmpeg backend
- **SnapFeeder**, a Flask server that serves JPEG snapshots on-demand
- A Python-based configuration generator that automatically detects connected cameras and sets up MediaMTX accordingly

---

## 📁 Project Structure

```
mtx-stream-snap/
├── install.sh                # Full setup script
├── uninstall.sh              # Cleanup script
├── mediamtx/                 # Holds downloaded MediaMTX binary and mediamtx.yml
│   ├── mediamtx
│   └── mediamtx.yml
├── scripts/                  # All project Python logic
│   ├── generate_mediamtx_config.py
│   └── snapfeeder.py
├── templates/                # Template .service files with placeholders
│   ├── mediamtx.service.template
│   └── snapfeeder.service.template
├── venv/                     # Python virtual environment
└── services/                 # Populated during install with rendered .service files
```

---

## ✅ Features

- Detects all `/dev/video*` USB cameras
- Chooses the best format:
  - Prefers `mjpeg`, falls back to others
  - Picks `1280x720` if supported, otherwise selects the highest available resolution
  - Uses maximum FPS for the chosen resolution
- Leverages hardware acceleration if available:
  - ✅ VAAPI (Intel/AMD GPU)
  - ✅ RKMMP (Rockchip)
  - ✅ V4L2M2M (Raspberry Pi)
- Configures `mediamtx.yml` with:
  - Enabled: `rtsp`, `webrtc`, `hls`
  - Disabled: `rtmp`, `api`, `metrics`, `pprof`, `playback`, `srt`
  - Adds Google STUN server for WebRTC
- Snapshot server:
  - Reads the MediaMTX config
  - Decodes RTSP of each camera using PyAV
  - Encodes JPEG snapshots via TurboJPEG only when requested
  - Provides dynamic endpoints: `/cam0.jpg`, `/cam1.jpg`, etc.

---

## 🚀 Installation

```bash
cd ~
git clone https://github.com/thesydoruk/mtx-stream-snap.git
cd mtx-stream-snap
bash install.sh
```

This will:

- Install system dependencies via APT (including `python3-venv` and `libturbojpeg`)
- Create a Python virtual environment
- Download the latest MediaMTX release into `mediamtx/`
- Generate `mediamtx.yml` using `scripts/generate_mediamtx_config.py`
- Create `.service` files from `templates/` and write them to `services/`
- Create systemd symlinks in `/etc/systemd/system/`
- Enable and start `mediamtx` and `snapfeeder` services (SnapFeeder waits for MediaMTX)
- Print available camera URLs

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
location /cam0/ {
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
- Remove symlinks from `/etc/systemd/system/`
- Delete the `services/`, `mediamtx/` and `venv/` directories

---

## 🔧 Development Notes

- `generate_mediamtx_config.py` and `snapfeeder.py` use project-root-relative paths
- No environment variables are required
- All Python logic is inside the `scripts/` directory

---

## 📜 License

MIT License  
(c) 2025 Valerii Sydoruk
