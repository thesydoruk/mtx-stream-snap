# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Support for Fedora, Arch Linux and openSUSE in addition to Debian/Ubuntu:
  `install.sh` detects `apt`, `dnf`, `pacman` or `zypper` and picks the right package names.
- Automatic H.264 encoder selection with a test encode: VAAPI, RKMPP, V4L2M2M, libx264,
  then libopenh264 (for distros whose ffmpeg has no x264). The `hqdn3d` filter is used
  only when the ffmpeg build provides it.
- snapfeeder falls back to PyAV's MJPEG encoder when libturbojpeg is missing or
  incompatible (`SNAPFEEDER_JPEG_ENCODER=pyav` forces it).
- `install.sh --deps-only` and running the installer as root without `sudo`.
- CI runs the smoke test on Debian 12/13, Ubuntu 22.04/24.04, Fedora, Arch Linux,
  openSUSE Tumbleweed and Debian 12 on arm64, with both JPEG encoders.

### Changed
- libturbojpeg is optional; the installer no longer stops when it is not packaged.
- pip prefers releases with prebuilt wheels; when PyAV still cannot be installed (e.g. armv7
  without wheels) the distro's PyAV package is used through the venv.
- PyAV `>=10` is accepted, so older distro packages qualify for that fallback.
- `mediamtx.service` joins the `video` and `render` groups (those that exist) for camera
  and GPU access, which is needed on distros that do not grant it to regular users.

### Fixed
- Software encoding outputs 4:2:0 (`-pix_fmt yuv420p`): MJPEG cameras produced 4:2:2
  H.264 that browsers cannot play over WebRTC/HLS.
- snapfeeder output reaches the journal immediately (`PYTHONUNBUFFERED=1`).
- The Rockchip FFmpeg prompt no longer aborts non-interactive installs.

## [1.0.1] - 2026-09-25

### Changed
- Generated camera commands run ffmpeg with `-hide_banner -nostats -loglevel warning`,
  so the MediaMTX log and the systemd journal no longer receive a progress line
  per frame batch (less SD card wear on single-board computers).

  `install.sh` keeps an existing `mediamtx.yml`, so to get this on an upgraded
  install either add these flags after `ffmpeg -y` in each `runOnInit` line, or run
  `bash install.sh --regenerate-config` (manual tuning in the old config is
  kept only in the `.bak` copy).

## [1.0.0] - 2026-09-25

First versioned release.

### Added
- Versioned releases: `VERSION` file, this changelog, GitHub Releases created from tags.
- CI: ShellCheck, syntax checks and an end-to-end smoke test (MediaMTX + snapfeeder
  with a synthetic camera) on every push and pull request.
- `install.sh --regenerate-config` to recreate `mediamtx.yml` (the old one is backed up).
- `MEDIAMTX_VERSION` environment variable to override the MediaMTX release (`latest` supported).

### Changed
- MediaMTX is pinned to the tested release `v1.21.1` instead of always using the latest.
- Python dependencies are bounded to tested major versions.
- Re-running `install.sh` keeps an existing `mediamtx.yml`, so manual tuning survives upgrades.
- Generated config uses `true`/`false` values, matching current MediaMTX configs.
- Line endings are normalized to LF via `.gitattributes`.

### Fixed
- Snapshot capture thread no longer dies on the first stream error (`av.AVError` was
  removed from PyAV; `av.FFmpegError` is used now), so `/camN.jpg` recovers after
  MediaMTX restarts.
- RTSP socket timeout works again (`timeout` instead of the removed `stimeout` option).
- Snapshots are not served from a stale frame while the stream is down.
- `hqdn3d` filter is no longer dropped for VAAPI (single `-vf` chain), and
  `-vaapi_device` is always passed for `hwupload`.
- `-tune zerolatency` is applied only to libx264.
- snapfeeder no longer crashes on startup with PyTurboJPEG 2.x: it requires
  libjpeg-turbo 3.0, which Debian, Ubuntu and Raspberry Pi OS do not ship, so
  PyTurboJPEG is limited to 1.x.
- Valid `-input_format` names for YU12/RGB3/BGR3 cameras.
- `install.sh` fails with a clear message when the MediaMTX download fails.
- `uninstall.sh` stops services even when they are not enabled.
- `mediamtx.service` no longer depends on the Python venv.

[Unreleased]: https://github.com/thesydoruk/mtx-stream-snap/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/thesydoruk/mtx-stream-snap/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/thesydoruk/mtx-stream-snap/releases/tag/v1.0.0
