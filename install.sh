#!/usr/bin/env bash

# ==============================================================================
# Full Installer for MediaMTX + SnapFeeder
# ----------------------------------------
# - Installs dependencies via APT and pip if needed
# - Creates Python virtual environment in ./venv/
# - Downloads MediaMTX (pinned version) and places it into ./mediamtx/
# - Generates mediamtx.yml using scripts/generate_mediamtx_config.py
#   (an existing mediamtx.yml is kept on upgrade unless --regenerate-config)
# - Processes *.service.template files from ./templates/
#   - Injects current user and absolute install path
#   - Saves rendered files into ./services/
#   - Installs rendered files into /etc/systemd/system/
# - Starts and enables systemd services
#
# Usage: bash install.sh [--regenerate-config]
#
# Environment:
#   MEDIAMTX_VERSION  MediaMTX release tag to install (default: tested version
#                     below; "latest" picks the newest GitHub release)
# ==============================================================================

set -e

# MediaMTX release this version of the project is tested with
MEDIAMTX_VERSION="${MEDIAMTX_VERSION:-v1.21.1}"

REGENERATE_CONFIG=0
for arg in "$@"; do
  case "$arg" in
    --regenerate-config) REGENERATE_CONFIG=1 ;;
    -h|--help) sed -n '3,22p' "$0"; exit 0 ;;
    *) echo "❌ Unknown option: $arg"; exit 1 ;;
  esac
done

# Define directories
BASE_DIR="$(dirname "$(realpath "$0")")"
VENV_DIR="$BASE_DIR/venv"
SERVICE_DIR="/etc/systemd/system"
TEMPLATE_DIR="$BASE_DIR/templates"
RENDERED_DIR="$BASE_DIR/services"
SCRIPTS_DIR="$BASE_DIR/scripts"
MEDIAMTX_DIR="$BASE_DIR/mediamtx"
MEDIAMTX_BIN="$MEDIAMTX_DIR/mediamtx"
MEDIAMTX_CONFIG="$MEDIAMTX_DIR/mediamtx.yml"

USERNAME=$(whoami)
PROJECT_VERSION=$(cat "$BASE_DIR/VERSION" 2>/dev/null || echo "unknown")

echo "📦 mtx-stream-snap $PROJECT_VERSION (MediaMTX $MEDIAMTX_VERSION)"

# ----------------------------------------------
# 🤖 Detect Rockchip platform (e.g., RK3588, RK3399)
# If detected, offer to install custom FFmpeg build
# with Rockchip hardware acceleration (MPP/RGA)
# ----------------------------------------------

# Read SoC info from device tree
ROCKCHIP_CPU=""
if [ -f /proc/device-tree/compatible ]; then
    ROCKCHIP_CPU=$(tr -d '\0' < /proc/device-tree/compatible | grep -o 'rockchip,[^,]*' || true)
fi

if [[ -n "$ROCKCHIP_CPU" ]]; then
    echo -e "🧠  \e[33mDetected Rockchip platform:\e[0m $ROCKCHIP_CPU"
    
    # Prompt user to optionally install the custom FFmpeg
    echo -e "🚀  \e[36mWould you like to install a custom FFmpeg build with Rockchip hardware acceleration (MPP/RGA)?\e[0m"
    read -p "✅  Type 'yes' to proceed or press Enter to skip: " user_input

    if [[ "$user_input" == "yes" ]]; then
      echo -e "🔧  \e[32mLaunching FFmpeg installer...\e[0m"
      bash "$BASE_DIR"/extras/rockchip_ffmpeg_installer.sh
    else
        echo -e "⏭️  \e[34mSkipping custom FFmpeg installation.\e[0m"
    fi
else
    echo -e "ℹ️  \e[34mNo Rockchip platform detected. Skipping hardware-accelerated FFmpeg prompt.\e[0m"
fi

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

# Download MediaMTX binary
VERSION="$MEDIAMTX_VERSION"
if [ "$VERSION" = "latest" ]; then
  VERSION=$(curl -fsSL https://api.github.com/repos/bluenviron/mediamtx/releases/latest | grep '"tag_name"' | cut -d '"' -f 4)
  if [ -z "$VERSION" ]; then
    echo "❌ Failed to determine the latest MediaMTX version (GitHub API unreachable or rate-limited)."
    exit 1
  fi
fi
ARCH=$(uname -m)
case "$ARCH" in
  armv6l)       PLATFORM="linux_armv6" ;;
  armv7l)       PLATFORM="linux_armv7" ;;
  aarch64)      PLATFORM="linux_arm64" ;;
  amd64|x86_64) PLATFORM="linux_amd64" ;;
  *) echo "❌ Unsupported architecture: $ARCH"; exit 1 ;;
esac

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
cd "$TMP_DIR" || exit 1
echo "⬇️  Downloading MediaMTX $VERSION for $PLATFORM..."
curl -fL -o mediamtx.tar.gz "https://github.com/bluenviron/mediamtx/releases/download/${VERSION}/mediamtx_${VERSION}_${PLATFORM}.tar.gz"
tar -xzf mediamtx.tar.gz

mkdir -p "$MEDIAMTX_DIR"
mv mediamtx "$MEDIAMTX_BIN"
chmod +x "$MEDIAMTX_BIN"

# Keep an existing config on upgrade so manual tuning survives
if [ -f "$MEDIAMTX_CONFIG" ] && [ "$REGENERATE_CONFIG" -eq 0 ]; then
  echo "ℹ️  Keeping existing $MEDIAMTX_CONFIG (use --regenerate-config to recreate it)"
else
  if [ -f "$MEDIAMTX_CONFIG" ]; then
    BACKUP="$MEDIAMTX_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
    echo "💾 Backing up current config to $BACKUP"
    cp "$MEDIAMTX_CONFIG" "$BACKUP"
  fi
  mv mediamtx.yml "$MEDIAMTX_CONFIG"
  chmod 644 "$MEDIAMTX_CONFIG"

  # Generate MediaMTX config
  "$VENV_DIR/bin/python" "$SCRIPTS_DIR/generate_mediamtx_config.py"
fi

# Render systemd service templates
mkdir -p "$RENDERED_DIR"

# Render .service files from templates and install to systemd
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

  # Install rendered service file into systemd directory
  echo "📦 Installing $base → $systemd_target"
  sudo install -m 644 "$output" "$systemd_target"
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
