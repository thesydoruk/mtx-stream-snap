#!/bin/bash

# ==============================================================================
# Full Installer for MediaMTX + SnapFeeder
# ----------------------------------------
# - Installs dependencies via APT and pip if needed
# - Downloads MediaMTX and places it into ./mediamtx/
# - Generates mediamtx.yml using scripts/generate_mediamtx_config.py
# - Processes *.service.template files from ./templates/
#   - Injects current user and absolute install path
#   - Saves rendered files into ./services/
#   - Creates symlinks into /etc/systemd/system/
# - Starts and enables systemd services
# ==============================================================================

set -e

echo "📦 Starting installation of MediaMTX + SnapFeeder..."

# ------------------------------------------------------------------------------
# Determine important paths
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
MEDIAMTX_DIR="$SCRIPT_DIR/mediamtx"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
SERVICE_DIR="$SCRIPT_DIR/services"

MEDIAMTX_BIN="$MEDIAMTX_DIR/mediamtx"
MEDIAMTX_CONFIG="$MEDIAMTX_DIR/mediamtx.yml"

USERNAME=$(whoami)
INSTALL_DIR="$SCRIPT_DIR"  # Absolute path for template replacement

mkdir -p "$SERVICE_DIR"

# ------------------------------------------------------------------------------
# Step 1: Install required system packages
# ------------------------------------------------------------------------------
APT_PACKAGES=(
  curl ffmpeg v4l-utils
  python3 python3-pip
  python3-flask python3-numpy python3-av
  python3-ruamel.yaml
  libturbojpeg0
)

if apt-cache show python3-turbojpeg >/dev/null 2>&1; then
  APT_PACKAGES+=(python3-turbojpeg)
  INSTALL_TURBOJPEG_PIP=0
else
  INSTALL_TURBOJPEG_PIP=1
fi

echo "🔧 Installing system dependencies..."
sudo apt update
sudo apt install -y "${APT_PACKAGES[@]}"

# ------------------------------------------------------------------------------
# Step 2: Install PyTurboJPEG via pip if necessary
# ------------------------------------------------------------------------------
if [[ $INSTALL_TURBOJPEG_PIP -eq 1 ]]; then
  echo "⚠️  python3-turbojpeg not available via APT, installing PyTurboJPEG via pip..."
  if python3 -c "import turbojpeg" 2>/dev/null; then
    echo "✅ PyTurboJPEG already installed"
  else
    if pip3 install --help | grep -q -- '--break-system-packages'; then
      sudo pip3 install -U git+https://github.com/lilohuang/PyTurboJPEG.git --break-system-packages
    else
      sudo pip3 install -U git+https://github.com/lilohuang/PyTurboJPEG.git
    fi
  fi
fi

# ------------------------------------------------------------------------------
# Step 3: Download MediaMTX binary and default config to ./mediamtx/
# ------------------------------------------------------------------------------
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

mkdir -p "$MEDIAMTX_DIR"
mv mediamtx "$MEDIAMTX_BIN"
chmod +x "$MEDIAMTX_BIN"
mv mediamtx.yml "$MEDIAMTX_CONFIG"
chmod 644 "$MEDIAMTX_CONFIG"

# ------------------------------------------------------------------------------
# Step 4: Run Python config generator to populate mediamtx.yml
# ------------------------------------------------------------------------------
GEN_SCRIPT="$SCRIPTS_DIR/generate_mediamtx_config.py"
if [[ ! -f "$GEN_SCRIPT" ]]; then
  echo "❌ Missing script: $GEN_SCRIPT"
  exit 1
fi

echo "🧠 Generating mediamtx.yml with connected camera paths..."
python3 "$GEN_SCRIPT"

# ------------------------------------------------------------------------------
# Step 5: Render .service files from templates and symlink to systemd
# ------------------------------------------------------------------------------
for template in "$TEMPLATE_DIR"/*.service.template; do
  base=$(basename "$template" .template)
  output="$SERVICE_DIR/$base"
  systemd_target="/etc/systemd/system/$base"

  echo "🛠️  Rendering $base..."

  # Render template with variable substitution
  sed \
    -e "s|%INSTALL_DIR%|$INSTALL_DIR|g" \
    -e "s|%USERNAME%|$USERNAME|g" \
    "$template" > "$output"

  # Create symlink to systemd
  echo "🔗 Linking $base → $systemd_target"
  sudo ln -sf "$output" "$systemd_target"
done

# ------------------------------------------------------------------------------
# Step 6: Reload systemd and enable/start services
# ------------------------------------------------------------------------------
echo "🚀 Reloading and enabling services..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable mediamtx.service snapfeeder.service
sudo systemctl restart mediamtx.service snapfeeder.service

# ------------------------------------------------------------------------------
# Step 7: Show configured camera URLs
# ------------------------------------------------------------------------------
echo "✅ Installation complete!"
echo ""
echo "🔍 Configured cameras (from $MEDIAMTX_CONFIG):"
cam_names=$(grep '^[[:space:]]*cam[0-9]\+:' "$MEDIAMTX_CONFIG" | sed 's/^[[:space:]]*//;s/://')

for cam in $cam_names; do
  echo "🎥 $cam:"
  echo "   📡 RTSP:     rtsp://<ip>:8554/$cam"
  echo "   🌐 WebRTC:   http://<ip>:8889/$cam/"
  echo "   🖼️ Snapshot: http://<ip>:5050/$cam.jpg"
done
