#!/usr/bin/env bash

# ==============================================================================
# Full Installer for MediaMTX + SnapFeeder
# ----------------------------------------
# - Installs system dependencies (apt, dnf, pacman or zypper)
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
# Usage: bash install.sh [--regenerate-config] [--deps-only]
#   --regenerate-config  recreate mediamtx.yml (the old one is backed up)
#   --deps-only          only install system packages and the Python venv
#
# Environment:
#   MEDIAMTX_VERSION  MediaMTX release tag to install (default: tested version
#                     below; "latest" picks the newest GitHub release)
# ==============================================================================

set -e

# MediaMTX release this version of the project is tested with
MEDIAMTX_VERSION="${MEDIAMTX_VERSION:-v1.21.1}"

REGENERATE_CONFIG=0
DEPS_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --regenerate-config) REGENERATE_CONFIG=1 ;;
    --deps-only) DEPS_ONLY=1 ;;
    -h|--help) sed -n '3,24p' "$0"; exit 0 ;;
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

# Run privileged commands directly when already root (e.g. containers without sudo)
if [ "$(id -u)" -eq 0 ]; then
  SUDO=()
elif command -v sudo >/dev/null 2>&1; then
  SUDO=(sudo)
else
  echo "❌ This installer needs root privileges: run it as root or install sudo."
  exit 1
fi

# ----------------------------------------------
# Package manager abstraction
# ----------------------------------------------
if command -v apt-get >/dev/null 2>&1; then
  PKG_MGR=apt
elif command -v dnf >/dev/null 2>&1; then
  PKG_MGR=dnf
elif command -v pacman >/dev/null 2>&1; then
  PKG_MGR=pacman
elif command -v zypper >/dev/null 2>&1; then
  PKG_MGR=zypper
else
  echo "❌ Unsupported distribution: none of apt-get, dnf, pacman or zypper found."
  echo "   Install python3 (with venv), ffmpeg, v4l-utils, curl and tar manually, then rerun."
  exit 1
fi
echo "🐧 Package manager: $PKG_MGR"

pkg_refresh() {
  case "$PKG_MGR" in
    apt)    "${SUDO[@]}" apt-get update ;;
    dnf)    "${SUDO[@]}" dnf -y makecache ;;
    pacman) "${SUDO[@]}" pacman -Sy --noconfirm ;;
    zypper) "${SUDO[@]}" zypper --non-interactive refresh ;;
  esac
}

pkg_installed() {
  case "$PKG_MGR" in
    apt)        dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed" ;;
    # --whatprovides also matches capabilities such as openSUSE's "python3"
    dnf|zypper) rpm -q --whatprovides "$1" >/dev/null 2>&1 ;;
    pacman)     pacman -Qi "$1" >/dev/null 2>&1 ;;
  esac
}

pkg_available() {
  case "$PKG_MGR" in
    apt)    apt-cache show "$1" 2>/dev/null | grep -q '^Package:' ;;
    dnf)    dnf -q info "$1" >/dev/null 2>&1 ;;
    pacman) pacman -Si "$1" >/dev/null 2>&1 ;;
    zypper) zypper --non-interactive -q search --provides --match-exact "$1" >/dev/null 2>&1 ;;
  esac
}

pkg_install() {
  case "$PKG_MGR" in
    apt)    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf)    "${SUDO[@]}" dnf install -y "$@" ;;
    # -Su completes the -Sy from pkg_refresh: Arch does not support partial upgrades
    pacman) "${SUDO[@]}" pacman -Su --needed --noconfirm "$@" ;;
    zypper) "${SUDO[@]}" zypper --non-interactive install "$@" ;;
  esac
}

# Package specs: "a|b" picks the first available alternative, a leading "?"
# marks the package optional (skipped with a warning when unavailable).
case "$PKG_MGR" in
  apt)
    PKG_SPECS=(python3 python3-venv curl ca-certificates tar gzip v4l-utils ffmpeg "?libturbojpeg0|libturbojpeg")
    PY_AV_PKG=python3-av ;;
  dnf)
    PKG_SPECS=(python3 curl ca-certificates tar gzip v4l-utils "ffmpeg|ffmpeg-free" "?openh264" "?turbojpeg")
    PY_AV_PKG=python3-av ;;
  pacman)
    PKG_SPECS=(python curl ca-certificates tar gzip v4l-utils ffmpeg "?libjpeg-turbo")
    PY_AV_PKG=python-av ;;
  zypper)
    PKG_SPECS=(python3 curl ca-certificates tar gzip v4l-utils "ffmpeg-7|ffmpeg-6|ffmpeg-5|ffmpeg-4|ffmpeg" "?libopenh264-7|libopenh264" "?libturbojpeg0")
    PY_AV_PKG=python3-av ;;
esac

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

if [[ -n "$ROCKCHIP_CPU" && "$DEPS_ONLY" -eq 0 && "$PKG_MGR" == "apt" && -t 0 ]]; then
    echo -e "🧠  \e[33mDetected Rockchip platform:\e[0m $ROCKCHIP_CPU"

    # Prompt user to optionally install the custom FFmpeg
    echo -e "🚀  \e[36mWould you like to install a custom FFmpeg build with Rockchip hardware acceleration (MPP/RGA)?\e[0m"
    read -r -p "✅  Type 'yes' to proceed or press Enter to skip: " user_input || true

    if [[ "$user_input" == "yes" ]]; then
      echo -e "🔧  \e[32mLaunching FFmpeg installer...\e[0m"
      bash "$BASE_DIR"/extras/rockchip_ffmpeg_installer.sh
    else
        echo -e "⏭️  \e[34mSkipping custom FFmpeg installation.\e[0m"
    fi
elif [[ -n "$ROCKCHIP_CPU" ]]; then
    echo -e "ℹ️  \e[34mRockchip platform detected ($ROCKCHIP_CPU); the custom FFmpeg installer is offered only on interactive apt-based installs.\e[0m"
fi

# ----------------------------------------------
# Ensure required system packages are installed
# ----------------------------------------------
echo "🔄 Refreshing package metadata"
pkg_refresh

MISSING_PKGS=()
for spec in "${PKG_SPECS[@]}"; do
  optional=0
  if [[ "$spec" == \?* ]]; then
    optional=1
    spec="${spec#\?}"
  fi

  # Keep an already installed ffmpeg (e.g. the custom Rockchip build)
  if [[ "$spec" == *ffmpeg* ]] && command -v ffmpeg >/dev/null 2>&1; then
    continue
  fi

  IFS='|' read -r -a alternatives <<< "$spec"
  chosen=""
  for pkg in "${alternatives[@]}"; do
    if pkg_installed "$pkg"; then
      chosen="installed"
      break
    fi
  done
  if [ -z "$chosen" ]; then
    for pkg in "${alternatives[@]}"; do
      if pkg_available "$pkg"; then
        chosen="$pkg"
        MISSING_PKGS+=("$pkg")
        break
      fi
    done
  fi

  if [ -z "$chosen" ]; then
    if [ "$optional" -eq 1 ]; then
      echo "⚠️  Optional package not available: ${spec//|/ or } (continuing without it)"
    else
      echo "❌ Required package not available: ${spec//|/ or }"
      echo "   Check your package sources (some distros ship ffmpeg only in extra repositories)."
      exit 1
    fi
  fi
done

if [ ${#MISSING_PKGS[@]} -ne 0 ]; then
  echo "🔧 Installing missing system packages: ${MISSING_PKGS[*]}"
  pkg_install "${MISSING_PKGS[@]}"
fi

# ----------------------------------------------
# Create Python virtual environment
# ----------------------------------------------
pip_install_requirements() {
  "$VENV_DIR/bin/python" -m pip install --upgrade pip wheel &&
    # Prefer an older release with a prebuilt wheel over building from source
    "$VENV_DIR/bin/python" -m pip install --prefer-binary -r "$BASE_DIR/venv-requirements.txt"
}

echo "🔧 Creating Python virtual environment"
if ! python3 -m venv "$VENV_DIR"; then
  echo "❌ python3 cannot create virtual environments (install the venv/ensurepip package for your Python)."
  exit 1
fi

if ! pip_install_requirements; then
  # Typical on armv7 and other platforms without PyAV wheels: use the distro's
  # prebuilt PyAV through a venv that can see system site-packages
  echo "⚠️  pip could not install all dependencies; retrying with the distro package $PY_AV_PKG"
  if pkg_available "$PY_AV_PKG" && pkg_install "$PY_AV_PKG"; then
    rm -rf "$VENV_DIR"
    python3 -m venv --system-site-packages "$VENV_DIR"
    if ! pip_install_requirements; then
      echo "❌ Failed to install Python dependencies, see pip output above."
      exit 1
    fi
  else
    echo "❌ Failed to install Python dependencies and $PY_AV_PKG is not available."
    exit 1
  fi
fi

if [ "$DEPS_ONLY" -eq 1 ]; then
  echo "✅ Dependencies installed (--deps-only)"
  exit 0
fi

if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
  echo "❌ systemd is not running on this system; the services cannot be installed."
  exit 1
fi

# ----------------------------------------------
# Download MediaMTX binary
# ----------------------------------------------
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

# Device access for the camera/encoder processes: only groups that exist here
# (a missing group in SupplementaryGroups= would stop the service from starting)
SUPPLEMENTARY_GROUPS=""
for group in video render; do
  if getent group "$group" >/dev/null 2>&1; then
    SUPPLEMENTARY_GROUPS="${SUPPLEMENTARY_GROUPS:+$SUPPLEMENTARY_GROUPS }$group"
  fi
done

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
    -e "s|__SUPPLEMENTARY_GROUPS__|$SUPPLEMENTARY_GROUPS|g" \
    "$template" > "$output"

  # Install rendered service file into systemd directory
  echo "📦 Installing $base → $systemd_target"
  "${SUDO[@]}" install -m 644 "$output" "$systemd_target"
done

# Reload systemd and enable/start services
echo "🚀 Reloading and enabling services..."
"${SUDO[@]}" systemctl daemon-reload
"${SUDO[@]}" systemctl enable mediamtx.service snapfeeder.service
"${SUDO[@]}" systemctl restart mediamtx.service snapfeeder.service

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
