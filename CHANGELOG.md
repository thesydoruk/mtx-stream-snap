# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
- Valid `-input_format` names for YU12/RGB3/BGR3 cameras.
- `install.sh` fails with a clear message when the MediaMTX download fails.
- `uninstall.sh` stops services even when they are not enabled.
- `mediamtx.service` no longer depends on the Python venv.

[Unreleased]: https://github.com/thesydoruk/mtx-stream-snap/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/thesydoruk/mtx-stream-snap/releases/tag/v1.0.0
