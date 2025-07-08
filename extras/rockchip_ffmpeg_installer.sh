#!/bin/bash

# Resolve the project root directory (assuming this script is in extras/)
PROJECT_ROOT="$(realpath "$(dirname "$0")/..")"
DEV_DIR="${PROJECT_ROOT}/dev"

# Enable color codes for log output
GREEN="\e[32m"
BLUE="\e[34m"
CYAN="\e[36m"
RED="\e[31m"
RESET="\e[0m"

# ----------------------------------------------
# Prepare clean development environment
# ----------------------------------------------
echo -e "${BLUE}📁 Resetting development directory...${RESET}"
rm -rf "$DEV_DIR"
mkdir -p "$DEV_DIR"
cd "$DEV_DIR" || exit 1

# ----------------------------------------------
# Remove any existing system-installed FFmpeg to avoid conflicts
# with the custom-built version. This ensures the system uses
# only the manually built FFmpeg with full codec and hardware support.
# ----------------------------------------------
echo -e "${BLUE}🧹 Removing existing system FFmpeg (if any)...${RESET}"
sudo apt remove ffmpeg --purge -y
sudo apt autoremove --purge -y

# ----------------------------------------------
# Install all required system packages for building FFmpeg
# with hardware acceleration and codec support.
# ----------------------------------------------
echo -e "${BLUE}📦 Installing build dependencies...${RESET}"
sudo apt update
sudo apt install -y \
    nasm \
    libdrm-dev \
    libx264-dev \
    libx265-dev \
    libnuma-dev \
    libvpx-dev \
    libfdk-aac-dev \
    libopus-dev \
    libdav1d-dev \
    cmake \
    meson \
    ninja-build


# Clone and build Rockchip MPP (Media Process Platform)
# This enables hardware-accelerated video encoding/decoding
# on Rockchip platforms (e.g., RK3588, RK3399).
# ----------------------------------------------
echo -e "${CYAN}🔧 Cloning and building Rockchip MPP...${RESET}"
git clone -b jellyfin-mpp --depth=1 https://github.com/nyanmisaka/mpp.git rkmpp

# Enter the source directory and create a separate build directory
cd rkmpp || exit 1
mkdir rkmpp_build
cd rkmpp_build || exit 1

# Configure MPP using CMake with installation to /usr
cmake \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TEST=OFF \
    ..

# Compile MPP with all available CPU cores
make -j "$(nproc)"
# Install MPP to system directories
sudo make install

cd "$DEV_DIR" || exit 1

# ----------------------------------------------
# Clone and build Rockchip RGA (Raster Graphic Accelerator)
# Provides fast image processing operations such as scaling,
# color conversion, and rotation using hardware acceleration.
# ----------------------------------------------
echo -e "${CYAN}🔧 Cloning and building Rockchip RGA...${RESET}"
git clone -b jellyfin-rga --depth=1 https://github.com/nyanmisaka/rk-mirrors.git rkrga

# Configure RGA build using Meson
meson setup rkrga rkrga_build \
    --prefix=/usr \
    --libdir=lib \
    --buildtype=release \
    --default-library=shared \
    -Dcpp_args=-fpermissive \
    -Dlibdrm=false \
    -Dlibrga_demo=false

# Compile and install RGA
sudo ninja -C rkrga_build install

# ----------------------------------------------
# Clone and build FFmpeg with support for:
# Rockchip hardware acceleration (MPP/RGA),
# external codec libraries, and advanced media features.
# ----------------------------------------------
echo -e "${CYAN}🎞️  Cloning and building FFmpeg with Rockchip support...${RESET}"
git clone --depth=1 https://github.com/nyanmisaka/ffmpeg-rockchip.git ffmpeg
cd ffmpeg || exit 1

# Configure FFmpeg build with all necessary features
./configure \
    --prefix=/usr \
    --enable-gpl \
    --enable-version3 \
    --enable-libdrm \
    --enable-rkmpp \
    --enable-rkrga \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libvpx \
    --enable-nonfree \
    --enable-libfdk-aac \
    --enable-libopus \
    --enable-libdav1d

# Build FFmpeg using all available CPU cores
make -j "$(nproc)"
# Install FFmpeg to /usr
sudo make install

# ----------------------------------------------
# Clean up: remove the temporary build directory
# ----------------------------------------------
echo -e "${CYAN}🧼 Cleaning up temporary build directory...${RESET}"
rm -rf "$DEV_DIR"

echo -e "${GREEN}✅ Installation complete and temporary files removed.${RESET}"
