#!/bin/bash

# ==============================================================================
# Uninstaller for MediaMTX + SnapFeeder system
# --------------------------------------------
# - Stops and disables systemd services
# - Removes generated service files and symlinks
# - Deletes MediaMTX installation directory
# - Cleans up the services/ folder
# ==============================================================================

set -e

echo "🔻 Uninstalling MediaMTX + SnapFeeder..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$SCRIPT_DIR/services"
MEDIAMTX_DIR="$SCRIPT_DIR/mediamtx"

# ------------------------------------------------------------------------------
# Step 1: Stop and disable systemd services
# ------------------------------------------------------------------------------
echo "🛑 Stopping services..."
sudo systemctl stop snapfeeder.service || true
sudo systemctl stop mediamtx.service || true

echo "❌ Disabling services..."
sudo systemctl disable snapfeeder.service || true
sudo systemctl disable mediamtx.service || true

# ------------------------------------------------------------------------------
# Step 2: Remove symlinks from /etc/systemd/system/
# ------------------------------------------------------------------------------
echo "🗑️ Removing systemd symlinks..."
sudo rm -f /etc/systemd/system/snapfeeder.service
sudo rm -f /etc/systemd/system/mediamtx.service

# ------------------------------------------------------------------------------
# Step 3: Remove entire services directory
# ------------------------------------------------------------------------------
if [[ -d "$SERVICE_DIR" ]]; then
  echo "🗑️ Removing services directory: $SERVICE_DIR"
  rm -rf "$SERVICE_DIR"
fi

# ------------------------------------------------------------------------------
# Step 4: Remove MediaMTX installation directory
# ------------------------------------------------------------------------------
if [[ -d "$MEDIAMTX_DIR" ]]; then
  echo "🗑️ Removing MediaMTX directory: $MEDIAMTX_DIR"
  rm -rf "$MEDIAMTX_DIR"
fi

# ------------------------------------------------------------------------------
# Step 5: Reload systemd to reflect changes
# ------------------------------------------------------------------------------
echo "🔄 Reloading systemd..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload

echo "✅ Uninstallation complete."
