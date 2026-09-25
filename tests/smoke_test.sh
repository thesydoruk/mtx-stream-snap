#!/usr/bin/env bash

# ==============================================================================
# End-to-end smoke test (used by CI, can be run locally on Linux)
# ------------------------------------------------------------------------------
# - Works in a temporary copy, never touches ./mediamtx/, ./venv/ or services
# - Installs Python deps from venv-requirements.txt into a temporary venv
#   (or uses an existing one: VENV_DIR=/path/to/venv, e.g. from install.sh --deps-only)
# - Downloads the MediaMTX version pinned in install.sh
# - Runs generate_mediamtx_config.py against its default mediamtx.yml
# - Adds a synthetic camera (ffmpeg testsrc2) as cam0, encoded with the
#   encoder the generator picks on this system
# - Starts MediaMTX + snapfeeder and checks that /cam0.jpg returns a JPEG
#
# Requires: python3 (with venv), ffmpeg, curl; libturbojpeg is optional.
# Ports 8554 and 5050 must be free (stop the installed services first).
# ==============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
PIDS=()

cleanup() {
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  echo "❌ $*"
  for log in "$WORK_DIR"/*.log; do
    [ -f "$log" ] || continue
    echo "----- $(basename "$log") -----"
    tail -n 50 "$log"
  done
  exit 1
}

MEDIAMTX_VERSION="${MEDIAMTX_VERSION:-$(sed -n 's/^MEDIAMTX_VERSION="\${MEDIAMTX_VERSION:-\(v[^}]*\)}"$/\1/p' "$ROOT_DIR/install.sh")}"
[ -n "$MEDIAMTX_VERSION" ] || fail "Could not read pinned MEDIAMTX_VERSION from install.sh"

case "$(uname -m)" in
  armv6l)       PLATFORM="linux_armv6" ;;
  armv7l)       PLATFORM="linux_armv7" ;;
  aarch64)      PLATFORM="linux_arm64" ;;
  amd64|x86_64) PLATFORM="linux_amd64" ;;
  *) fail "Unsupported architecture: $(uname -m)" ;;
esac

echo "🔧 Preparing work dir $WORK_DIR"
cp -r "$ROOT_DIR/scripts" "$WORK_DIR/scripts"
mkdir -p "$WORK_DIR/mediamtx"

if [ -n "${VENV_DIR:-}" ]; then
  echo "🐍 Using existing virtual environment $VENV_DIR"
  PY="$VENV_DIR/bin/python"
else
  echo "🐍 Installing Python dependencies"
  python3 -m venv "$WORK_DIR/venv"
  "$WORK_DIR/venv/bin/python" -m pip install -q --upgrade pip wheel
  "$WORK_DIR/venv/bin/python" -m pip install -q --prefer-binary -r "$ROOT_DIR/venv-requirements.txt"
  PY="$WORK_DIR/venv/bin/python"
fi
[ -x "$PY" ] || fail "Python not found at $PY"

echo "⬇️  Downloading MediaMTX $MEDIAMTX_VERSION ($PLATFORM)"
curl -fsSL -o "$WORK_DIR/mediamtx.tar.gz" \
  "https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_${PLATFORM}.tar.gz"
tar -xzf "$WORK_DIR/mediamtx.tar.gz" -C "$WORK_DIR/mediamtx" mediamtx mediamtx.yml

echo "🛠️  Generating config"
"$PY" "$WORK_DIR/scripts/generate_mediamtx_config.py" || fail "Config generator failed"

echo "🎥 Adding synthetic camera cam0"
"$PY" - "$WORK_DIR/mediamtx/mediamtx.yml" "$WORK_DIR/scripts" <<'EOF'
import sys
from ruamel.yaml import YAML

path = sys.argv[1]
sys.path.insert(0, sys.argv[2])
import generate_mediamtx_config as gen
yaml = YAML()
# MediaMTX parses YAML 1.1: unquoting values like "no" turns them into booleans
yaml.preserve_quotes = True
with open(path) as f:
    config = yaml.load(f)

for key in ["rtsp", "webrtc", "hls"]:
    assert config[key] is True, f"{key} should be enabled"
for key in ["rtmp", "api", "metrics", "pprof", "playback", "srt"]:
    assert config[key] is False, f"{key} should be disabled"
assert "all_others" in config["paths"], "all_others path must be preserved"

all_others = config["paths"].pop("all_others")
encoder = gen.detect_encoder()
assert encoder is not None, "no working H.264 encoder"
denoise = gen.has_filter("hqdn3d")
print(f"   encoder: {encoder['name']}, denoise: {denoise}")
input_args = ["-re", "-f", "lavfi", "-i", "testsrc2=size=640x480:rate=10"]
config["paths"]["cam0"] = {
    "source": "publisher",
    "runOnInit": gen.build_ffmpeg_cmd(input_args, 10, "cam0", encoder, denoise, gen.list_available_hwaccels()),
    "runOnInitRestart": True,
}
config["paths"]["all_others"] = all_others

with open(path, "w") as f:
    yaml.dump(config, f)
EOF

echo "🚀 Starting MediaMTX"
(cd "$WORK_DIR/mediamtx" && exec ./mediamtx) >"$WORK_DIR/mediamtx.log" 2>&1 &
PIDS+=($!)

for _ in $(seq 1 30); do
  (echo >/dev/tcp/127.0.0.1/8554) >/dev/null 2>&1 && break
  sleep 1
done
(echo >/dev/tcp/127.0.0.1/8554) >/dev/null 2>&1 || fail "MediaMTX did not open RTSP port 8554"

echo "🚀 Starting snapfeeder"
PYTHONUNBUFFERED=1 "$PY" "$WORK_DIR/scripts/snapfeeder.py" >"$WORK_DIR/snapfeeder.log" 2>&1 &
PIDS+=($!)

echo "🖼️  Waiting for snapshot"
SNAPSHOT="$WORK_DIR/cam0.jpg"
for _ in $(seq 1 60); do
  code=$(curl -s -o "$SNAPSHOT" -w '%{http_code}' http://127.0.0.1:5050/cam0.jpg || true)
  [ "$code" = "200" ] && break
  sleep 1
done
[ "${code:-}" = "200" ] || fail "Snapshot endpoint did not return 200 (last status: ${code:-none})"

magic=$(head -c 3 "$SNAPSHOT" | od -An -tx1 | tr -d ' \n')
[ "$magic" = "ffd8ff" ] || fail "Snapshot is not a JPEG (magic: $magic)"

code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5050/nope.jpg || true)
[ "$code" = "404" ] || fail "Unknown camera should return 404 (got $code)"

echo "✅ Smoke test passed ($(wc -c <"$SNAPSHOT") byte JPEG, $(grep -m1 'JPEG encoder' "$WORK_DIR/snapfeeder.log" || echo 'JPEG encoder: ?'))"
