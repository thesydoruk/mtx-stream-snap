#!/usr/bin/env bash

# ==============================================================================
# Full Installer for MediaMTX + SnapFeeder
# ----------------------------------------
# - Installs dependencies via APT and pip if needed
# - Creates Python virtual environment in ./venv/
# - Downloads MediaMTX and places it into ./mediamtx/
# - Generates mediamtx.yml using scripts/generate_mediamtx_config.py
# - Processes *.service.template files from ./templates/
#   - Injects current user and absolute install path
#   - Saves rendered files into ./services/
#   - Creates symlinks into /etc/systemd/system/
# - Starts and enables systemd services
# ==============================================================================

set -e

# Define directories
BASE_DIR="$(dirname $(realpath $0))"
VENV_DIR="$BASE_DIR/venv"
SERVICE_DIR="/etc/systemd/system"
TEMPLATE_DIR="$BASE_DIR/templates"
RENDERED_DIR="$BASE_DIR/services"
SCRIPTS_DIR="$BASE_DIR/scripts"
MEDIAMTX_DIR="$BASE_DIR/mediamtx"
MEDIAMTX_BIN="$MEDIAMTX_DIR/mediamtx"
MEDIAMTX_CONFIG="$MEDIAMTX_DIR/mediamtx.yml"

USERNAME=$(whoami)

# Ensure required system packages are installed
REQUIRED_PKGS=(python3 python3-pip python3-venv curl v4l-utils)
MISSING_PKGS=()

for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING_PKGS+=("$pkg")
  fi
done

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ℹ️  ffmpeg not found, adding to install list"
  MISSING_PKGS+=(ffmpeg)
fi

if apt-cache show libturbojpeg0 >/dev/null 2>&1; then
  if ! dpkg -s libturbojpeg0 >/dev/null 2>&1; then
    echo "ℹ️  libturbojpeg0 is available and not installed — adding to install list"
    MISSING_PKGS+=(libturbojpeg0)
  fi
elif apt-cache show libturbojpeg >/dev/null 2>&1; then
  if ! dpkg -s libturbojpeg >/dev/null 2>&1; then
    echo "ℹ️  libturbojpeg is available and not installed — adding to install list"
    MISSING_PKGS+=(libturbojpeg)
  fi
else
  echo "❌ Neither 'libturbojpeg0' nor 'libturbojpeg' are available in APT repositories."
  echo "   Please check your APT sources."
  exit 1
fi

if [ ${#MISSING_PKGS[@]} -ne 0 ]; then
  echo "🔧 Installing missing system packages: ${MISSING_PKGS[*]}"
  sudo apt update
  sudo apt install -y "${MISSING_PKGS[@]}"
fi


# Create Python virtual environment
echo "🔧 Creating Python virtual environment"
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip wheel
pip install -r "$BASE_DIR/venv-requirements.txt"
deactivate

# Download latest MediaMTX binary
VERSION=$(curl -s https://api.github.com/repos/bluenviron/mediamtx/releases/latest | grep tag_name | cut -d '"' -f 4)
ARCH=$(uname -m)
case "$ARCH" in
  armv6l)       PLATFORM="linux_armv6" ;;
  armv7l)       PLATFORM="linux_armv7" ;;
  aarch64)      PLATFORM="linux_arm64" ;;
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

# Generate MediaMTX config
"$VENV_DIR/bin/python" "$SCRIPTS_DIR/generate_mediamtx_config.py"

# Render systemd service templates
mkdir -p "$RENDERED_DIR"

# Render .service files from templates and symlink to systemd
for template in "$TEMPLATE_DIR"/*.service.template; do
  base=$(basename "$template" .template)
  output="$RENDERED_DIR/$base"
  systemd_target="$SERVICE_DIR/$base"

  echo "🛠️  Rendering $base..."

  # Render template with variable substitution
  sed \
    -e "s|__BASE_DIR__|$BASE_DIR|g" \
    -e "s|__VENV_DIR__|$VENV_DIR|g" \
    -e "s|__USERNAME__|$USERNAME|g" \
    "$template" > "$output"

  # Create symlink to systemd
  echo "🔗 Linking $base → $systemd_target"
  sudo ln -sf "$output" "$systemd_target"
done

# Reload systemd and enable/start services
echo "🚀 Reloading and enabling services..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable mediamtx.service snapfeeder.service
sudo systemctl restart mediamtx.service snapfeeder.service

# Show configured camera URLs
echo "✅ Installation complete!"
echo ""
echo "🔍 Configured cameras (from $MEDIAMTX_CONFIG):"
cam_names=$(grep '^[[:space:]]*cam[0-9]\+:' "$MEDIAMTX_CONFIG" | sed 's/^[[:space:]]*//;s/://')

for cam in $cam_names; do
  echo "🎥 $cam:"
  echo "   📡 RTSP:     rtsp://<ip>:8554/$cam"
  echo "   🌐 WebRTC:   http://<ip>:8889/$cam/"
  echo "   📺 HLS:      http://<ip>:8888/$cam/index.m3u8"
  echo "   🖼️ Snapshot: http://<ip>:5050/$cam.jpg"
done
