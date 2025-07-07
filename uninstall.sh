#!/usr/bin/env bash

# ==============================================================================
# Uninstaller for MediaMTX + SnapFeeder system
# --------------------------------------------
# - Stops and disables systemd services
# - Removes python virtual env
# - Removes generated service files and symlinks
# - Deletes MediaMTX installation directory
# - Cleans up the services/ folder
# ==============================================================================

set -e

echo "🧹 Starting uninstallation..."

# Define directories
BASE_DIR="$(dirname $(realpath $0))"
RENDERED_DIR="$BASE_DIR/services"
SERVICE_DIR="/etc/systemd/system"
VENV_DIR="$BASE_DIR/venv"
MEDIAMTX_DIR="$BASE_DIR/mediamtx"

# List of managed services
SERVICES=(snapfeeder.service mediamtx.service)

# Stop and disable systemd services
for svc in "${SERVICES[@]}"; do
  if systemctl is-enabled "$svc" &>/dev/null; then
    echo "⛔ Disabling $svc"
    sudo systemctl disable --now "$svc"
  fi

  TARGET="$SERVICE_DIR/$svc"
  if [ -L "$TARGET" ]; then
    echo "🗑️  Removing symlink: $TARGET"
    sudo rm -f "$TARGET"
  fi
done

# Reload systemd to clear removed units
sudo systemctl daemon-reload

# Remove rendered service files
if [ -d "$RENDERED_DIR" ]; then
  echo "🗑️  Removing rendered service files from $RENDERED_DIR"
  rm -rf "$RENDERED_DIR"
fi

# Remove virtual environment
if [ -d "$VENV_DIR" ]; then
  echo "🗑️  Removing virtualenv $VENV_DIR"
  rm -rf "$VENV_DIR"
fi

# Remove MediaMTX directory
if [ -d "$MEDIAMTX_DIR" ]; then
  echo "🗑️  Removing MediaMTX directory $MEDIAMTX_DIR"
  rm -rf "$MEDIAMTX_DIR"
fi

echo "✅ Uninstallation complete."
