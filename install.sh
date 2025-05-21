#!/bin/bash

# ===============================================================
# Installs MediaMTX and SnapFeeder, configures mediamtx.yml
# using generate_mediamtx_config.py (with VAAPI & YAML editing).
# ===============================================================

set -e

echo "📦 Starting installation of MediaMTX + SnapFeeder..."

# Determine directory of this script to reliably find resources
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --------------------------------------------------------------
# Step 1: Required APT packages (only essentials, no duplicates)
# --------------------------------------------------------------
APT_PACKAGES=(
  curl ffmpeg v4l-utils
  python3 python3-pip
  python3-flask python3-numpy python3-av
  python3-ruamel.yaml
  libturbojpeg0
)

# Dynamically detect if python3-turbojpeg is available
if apt-cache show python3-turbojpeg >/dev/null 2>&1; then
  APT_PACKAGES+=(python3-turbojpeg)
  INSTALL_TURBOJPEG_PIP=0
else
  INSTALL_TURBOJPEG_PIP=1
fi

echo "🔧 Installing system dependencies..."
sudo apt update
sudo apt install -y "${APT_PACKAGES[@]}"

# --------------------------------------------------------------
# Step 2: Install PyTurboJPEG via pip if not in APT
# --------------------------------------------------------------
if [[ $INSTALL_TURBOJPEG_PIP -eq 1 ]]; then
  echo "⚠️  Installing PyTurboJPEG via pip (APT not available)..."
  if python3 -c "import turbojpeg" 2>/dev/null; then
    echo "✅ PyTurboJPEG already installed"
  else
    echo "⚠️  Installing PyTurboJPEG via pip..."
    if pip3 install --help | grep -q -- '--break-system-packages'; then
      sudo pip3 install -U git+https://github.com/lilohuang/PyTurboJPEG.git --break-system-packages
    else
      sudo pip3 install -U git+https://github.com/lilohuang/PyTurboJPEG.git
    fi
  fi
fi

# --------------------------------------------------------------
# Step 3: Download and extract latest MediaMTX release
# --------------------------------------------------------------
VERSION=$(curl -s https://api.github.com/repos/bluenviron/mediamtx/releases/latest | grep tag_name | cut -d '"' -f 4)
ARCH=$(uname -m)
case "$ARCH" in
  armv6l)     PLATFORM="linux_armv6" ;;
  armv7l)     PLATFORM="linux_armv7" ;;
  aarch64)    PLATFORM="linux_arm64" ;;
  amd64|x86_64) PLATFORM="linux_amd64" ;;
  *) echo "❌ Unsupported architecture: $ARCH"; exit 1 ;;
esac

TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
echo "⬇️  Downloading MediaMTX $VERSION for $PLATFORM..."
curl -L -o mediamtx.tar.gz "https://github.com/bluenviron/mediamtx/releases/download/${VERSION}/mediamtx_${VERSION}_${PLATFORM}.tar.gz"
tar -xzf mediamtx.tar.gz

# --------------------------------------------------------------
# Step 4: Install MediaMTX binary and default config
# --------------------------------------------------------------
sudo mv mediamtx /usr/local/bin/
sudo chmod +x /usr/local/bin/mediamtx
sudo mkdir -p /usr/local/etc/
sudo mv mediamtx.yml /usr/local/etc/mediamtx.yml
sudo chmod 644 /usr/local/etc/mediamtx.yml

# --------------------------------------------------------------
# Step 5: Generate config using generate_mediamtx_config.py
# --------------------------------------------------------------
if [[ ! -f "$SCRIPT_DIR/generate_mediamtx_config.py" ]]; then
  echo "❌ Missing: generate_mediamtx_config.py"
  exit 1
fi

echo "🧠 Generating camera path section..."
python3 "$SCRIPT_DIR/generate_mediamtx_config.py"

# --------------------------------------------------------------
# Step 6: Install MediaMTX systemd service
# --------------------------------------------------------------
if [[ ! -f "$SCRIPT_DIR/mediamtx.service" ]]; then
  echo "❌ Missing: mediamtx.service"
  exit 1
fi

sudo install -m 644 "$SCRIPT_DIR/mediamtx.service" /etc/systemd/system/mediamtx.service

# --------------------------------------------------------------
# Step 7: Install SnapFeeder script and service
# --------------------------------------------------------------
if [[ ! -f "$SCRIPT_DIR/snapfeeder.py" ]]; then
  echo "❌ Missing: snapfeeder.py"
  exit 1
fi

if [[ ! -f "$SCRIPT_DIR/snapfeeder.service" ]]; then
  echo "❌ Missing: snapfeeder.service"
  exit 1
fi

sudo install -m 755 "$SCRIPT_DIR/snapfeeder.py" /usr/local/bin/snapfeeder.py
sudo install -m 644 "$SCRIPT_DIR/snapfeeder.service" /etc/systemd/system/snapfeeder.service

# --------------------------------------------------------------
# Step 8: Reload and enable both services
# --------------------------------------------------------------
echo "🚀 Enabling MediaMTX and SnapFeeder services..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable mediamtx snapfeeder
sudo systemctl start mediamtx snapfeeder

# --------------------------------------------------------------
# Done + show all configured cameras
# --------------------------------------------------------------
echo "✅ Installation finished!"
echo ""
echo "🔍 Configured cameras (from /usr/local/etc/mediamtx.yml):"

# Extract cam names from YAML using grep/sed (safe for default format)
cam_names=$(grep '^[[:space:]]*cam[0-9]\+:' /usr/local/etc/mediamtx.yml | sed 's/^[[:space:]]*//;s/://')

for cam in $cam_names; do
  echo "🎥 $cam:"
  echo "   📡 RTSP:     rtsp://<ip>:8554/$cam"
  echo "   🌐 WebRTC:   http://<ip>:8889/$cam/"
  echo "   🖼️ Snapshot: http://<ip>:5050/$cam.jpg"
done
