#!/bin/bash

# Uninstaller for MediaMTX and SnapFeeder
# This script stops services, disables them from autostart, and removes all related files.

set -e

echo "🔻 Uninstalling MediaMTX and SnapFeeder..."

# Stop and disable systemd services
echo "🛑 Stopping services..."
sudo systemctl stop snapfeeder.service || true
sudo systemctl stop mediamtx.service || true

echo "❌ Disabling services..."
sudo systemctl disable snapfeeder.service || true
sudo systemctl disable mediamtx.service || true

# Remove service files
echo "🗑️ Removing systemd service files..."
sudo rm -f /etc/systemd/system/snapfeeder.service
sudo rm -f /etc/systemd/system/mediamtx.service

# Remove installed binaries
echo "🧹 Removing installed binaries..."
sudo rm -f /usr/local/bin/mediamtx
sudo rm -f /usr/local/bin/snapfeeder.py

# Remove config files
echo "🗃️ Removing configuration files..."
sudo rm -f /usr/local/etc/mediamtx.yml

# Reload systemd
echo "🔄 Reloading systemd..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload

echo "✅ Uninstallation complete."
