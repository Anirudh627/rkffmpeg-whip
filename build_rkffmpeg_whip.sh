#!/bin/bash
# Author: Anirudh R Rao
# Builds the Rockchip ffmpeg with the whip muxer (OpenSSL) and libvpx, tests it, and installs it in place of the
# rkffmpeg2 that DeepInsight's live view uses. One script, run ON THE BOARD as root:
#
#   bash build_rkffmpeg_whip.sh build     compile it in a throwaway ubuntu:22.04 container (7.5 minutes measured on a quiet board)
#   bash build_rkffmpeg_whip.sh bundle    collect the shared libraries it needs (libssl, libvpx, ...)
#   bash build_rkffmpeg_whip.sh stage     assemble the folder to install: old wrappers and old MPP/RGA libs + new ffmpeg
#   bash build_rkffmpeg_whip.sh test      run the live view's command and a WHIP push with the staged build
#   bash build_rkffmpeg_whip.sh install   put it in place of the live rkffmpeg2 and verify inside the backend container
#   bash build_rkffmpeg_whip.sh all       build, bundle, stage, test, install
#   bash build_rkffmpeg_whip.sh clean     remove the build container and the generated helper files
#
# Full explanation, test numbers and the problems met on the first build: standard/docs/FFMPEG_WHIP_HOWTO_BUILD.md,
# FFMPEG_WHIP_BUILD.md and FFMPEG_WHIP_TEST_RESULTS.md.
#
# What it changes: only the files inside $LIVE (ffmpeg, ffprobe, lib/), by renaming each one over the old file, so ffmpegs
# that are running keep working and the backend is not restarted. A live-view ffmpeg started after the install uses
# the new build. `install` first copies the folder to $LIVE.bak-<time> and puts the old files back by itself if its checks
# fail; that copy is a safety net for a failed install, and can be deleted once the install passed.
#
# Settings (environment variables, all optional):
#   WORK               working folder (default /home/antelao/shared/ffmpeg-whip-build)
#   LIVE               the folder DeepInsight mounts as /opt/rkffmpeg2 (default /home/antelao/rkffmpeg2)
#   RKDT               device-tree dump folder (default /home/antelao/rkdt)
#   BACKEND_IMAGE      image used for the tests (default standard-backend:latest)
#   BACKEND_CONTAINER  running backend container used to verify the install (default deepinsight_backend)
#   CAMERA_URL         an RTSP camera: recorded for the test if $WORK/real.mp4 is missing, and used for a last live
#                      check after the install (optional)
#   JOBS               compile jobs (default 6 of 8 cores, leave some for DeepInsight)
#
# Needs: Docker, internet access (GitHub), about 3 GB free on the data disk, MediaMTX running for `test`.
# The board's host tools are BusyBox (no timeout, no nice). If this file came from a Windows checkout, remove the
# carriage returns first:  tr -d '\r' < build_rkffmpeg_whip.sh > fixed.sh
set -euo pipefail

WORK="${WORK:-/home/antelao/shared/ffmpeg-whip-build}"
LIVE="${LIVE:-/home/antelao/rkffmpeg2}"
RKDT="${RKDT:-/home/antelao/rkdt}"
BACKEND_IMAGE="${BACKEND_IMAGE:-standard-backend:latest}"
BACKEND_CONTAINER="${BACKEND_CONTAINER:-deepinsight_backend}"
CAMERA_URL="${CAMERA_URL:-}"
JOBS="${JOBS:-6}"
MEDIAMTX_RTSP="${MEDIAMTX_RTSP:-rtsp://127.0.0.1:8554}"        # as seen from the host (tests use host networking)
MEDIAMTX_WHIP="${MEDIAMTX_WHIP:-http://127.0.0.1:8889}"
MEDIAMTX_FROM_BACKEND="${MEDIAMTX_FROM_BACKEND:-rtsp://host.docker.internal:8554}"   # as seen from the backend container
BUILD_CONTAINER=ffmpeg-whip-build
DEVICES="--device /dev/mpp_service --device /dev/dma_heap/system --device /dev/dma_heap/cma --device /dev/rga"

log() { echo ">>> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------------------------
# build: runs inside the throwaway container
# ---------------------------------------------------------------------------------------------------------------
write_inner_build() {
  cat > "$WORK/inner_build.sh" <<'INNER'
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential git ca-certificates cmake meson ninja-build pkg-config \
  libdrm-dev libssl-dev libvpx-dev python3
mkdir -p /work/src /out && cd /work/src

# clone BRANCH DEST URL...   tries every URL, up to three rounds. BRANCH may be empty.
clone() {
  local br="$1" dest="$2"; shift 2
  local i url
  for i in 1 2 3; do
    for url in "$@"; do
      rm -rf "$dest"
      if [ -n "$br" ]; then
        git -c http.version=HTTP/1.1 clone -b "$br" --depth=1 "$url" "$dest" && return 0
      else
        git -c http.version=HTTP/1.1 clone --depth=1 "$url" "$dest" && return 0
      fi
      sleep 5
    done
  done
  return 1
}
# GitHub mirror first (gitee drops the connection from some networks), gitee as the fallback.
clone jellyfin-mpp rkmpp https://github.com/nyanmisaka/rk-mirrors.git https://gitee.com/nyanmisaka/mpp.git
clone jellyfin-rga rkrga https://github.com/nyanmisaka/rk-mirrors.git https://gitee.com/nyanmisaka/rga.git
clone "" ffmpeg https://github.com/nyanmisaka/ffmpeg-rockchip.git

JOBS="${JOBS:-6}"
export PKG_CONFIG_PATH=/out/lib/pkgconfig
cmake -S rkmpp -B rkmpp_build -DCMAKE_INSTALL_PREFIX=/out -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DBUILD_TEST=OFF
nice -n 19 cmake --build rkmpp_build -j"$JOBS"
cmake --install rkmpp_build
meson setup rkrga_build rkrga --prefix=/out --libdir=lib --buildtype=release --default-library=shared \
  -Dcpp_args=-fpermissive -Dlibdrm=false -Dlibrga_demo=false
nice -n 19 ninja -C rkrga_build install

cd ffmpeg
# The tested build was the fork's master at d90e3a1, the same commit as the old rkffmpeg2.
git log -1 --format='ffmpeg-rockchip commit %h %cd' | tee /out/COMMIT.txt
./configure --prefix=/out --enable-gpl --enable-version3 --enable-libdrm --enable-rkmpp --enable-rkrga \
  --enable-openssl --enable-libvpx --enable-shared --disable-static --disable-doc --disable-htmlpages --disable-manpages
nice -n 19 make -j"$JOBS"
make install
echo BUILD-DONE
INNER
}

step_build() {
  mkdir -p "$WORK/out"
  write_inner_build
  docker rm -f "$BUILD_CONTAINER" >/dev/null 2>&1 || true
  rm -f "$WORK/build.log"
  log "Starting the build in container $BUILD_CONTAINER (log: $WORK/build.log)"
  docker run -d --name "$BUILD_CONTAINER" -e JOBS="$JOBS" -v "$WORK":/work-host -v "$WORK/out":/out ubuntu:22.04 \
    bash -c 'mkdir -p /out; bash /work-host/inner_build.sh > /work-host/build.log 2>&1; echo exit=$? >> /work-host/build.log' >/dev/null
  until grep -q '^exit=' "$WORK/build.log" 2>/dev/null; do
    sleep 30
    echo "    $(date +%T) $(tail -n 1 "$WORK/build.log" 2>/dev/null | cut -c1-100)"
  done
  grep -q '^exit=0' "$WORK/build.log" || die "the build failed, see $WORK/build.log (a clone error means: run build again)"
  [ -x "$WORK/out/bin/ffmpeg" ] || die "no $WORK/out/bin/ffmpeg after the build"
  docker rm -f "$BUILD_CONTAINER" >/dev/null 2>&1 || true
  log "Build done: $(cat "$WORK/out/COMMIT.txt")"
}

# ---------------------------------------------------------------------------------------------------------------
# bundle: the shared libraries the new ffmpeg needs, from a container of the same distribution
# ---------------------------------------------------------------------------------------------------------------
step_bundle() {
  [ -x "$WORK/out/bin/ffmpeg" ] || die "run build first"
  cat > "$WORK/inner_bundle.sh" <<'INNER'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null 2>&1
apt-get install -y --no-install-recommends libvpx7 libssl3 libdrm2 >/dev/null 2>&1
export LD_LIBRARY_PATH=/out/lib
mkdir -p /out/bundle-libs
for b in /out/bin/ffmpeg /out/bin/ffprobe; do ldd "$b"; done \
  | awk '/=> \//{print $3}' | sort -u \
  | grep -v '^/out/' | grep -vE '/(libc|libm|libdl|librt|libpthread|ld-linux-aarch64)[.-]' \
  | while read -r l; do cp -L "$l" /out/bundle-libs/; done
echo "not found:"
for b in /out/bin/ffmpeg /out/bin/ffprobe; do LD_LIBRARY_PATH=/out/lib:/out/bundle-libs ldd "$b" | grep 'not found' || true; done
echo "bundled:"; ls /out/bundle-libs
INNER
  local out
  out="$(docker run --rm -v "$WORK/out":/out -v "$WORK/inner_bundle.sh":/bundle.sh:ro ubuntu:22.04 bash /bundle.sh)"
  echo "$out"
  # nothing may be listed between "not found:" and "bundled:", and libssl and libvpx must be there
  if echo "$out" | sed -n '/^not found:/,/^bundled:/p' | grep -q 'not found$'; then die "a library is still missing"; fi
  echo "$out" | grep -q libssl.so.3 || die "libssl.so.3 was not bundled"
  echo "$out" | grep -q 'libvpx.so' || die "libvpx was not bundled"
  log "Libraries bundled"
}

# ---------------------------------------------------------------------------------------------------------------
# stage: the folder to install. Old wrappers and dt_redirect.so, new ffmpeg/ffprobe/libs, and the OLD MPP and RGA libs:
# the MPP built from jellyfin-mpp fails on this board with "Failed to init MPP context: -1".
# ---------------------------------------------------------------------------------------------------------------
step_stage() {
  [ -d "$WORK/out/bundle-libs" ] || die "run bundle first"
  [ -d "$LIVE/lib" ] || die "no $LIVE/lib (scripts/02_setup_rkffmpeg2.sh installs the bundle first)"
  local S="$WORK/rkffmpeg3"
  rm -rf "$S"
  cp -a "$LIVE" "$S"
  cp "$WORK/out/bin/ffmpeg" "$WORK/out/bin/ffprobe" "$S/"
  cp -a "$WORK"/out/lib/*.so* "$S/lib/"
  cp -a "$WORK"/out/bundle-libs/*.so* "$S/lib/"
  rm -f "$S"/lib/librockchip_mpp* "$S"/lib/librga*
  cp -a "$LIVE"/lib/librockchip_mpp* "$LIVE"/lib/librga* "$S/lib/"
  chmod 755 "$S/ffmpeg" "$S/ffprobe"
  log "Staged $S ($(du -sh "$S" | cut -f1), $(ls "$S/lib" | wc -l) library files)"
}

# ---------------------------------------------------------------------------------------------------------------
# test: in a throwaway container of the backend's image, with the backend's device nodes, the staged bundle mounted at
# /opt/rkffmpeg2. Source is a recorded file: reading a live cam-NNN/raw stalls the hardware decoder in the container
# (standard/docs/SLIM_SDK_ISSUES_LOG.md item 1).
# ---------------------------------------------------------------------------------------------------------------
step_test() {
  # BUNDLE: the folder to test. Default is the staged one; BUNDLE=/home/antelao/rkffmpeg2 tests what is installed.
  local B="${BUNDLE:-$WORK/rkffmpeg3}"
  [ -d "$B/lib" ] || die "no bundle at $B (run stage first, or set BUNDLE)"
  mkdir -p "$WORK"
  if [ ! -s "$WORK/real.mp4" ]; then
    [ -n "$CAMERA_URL" ] || die "no $WORK/real.mp4: put an H.264 clip there, or set CAMERA_URL to record one"
    log "Recording 30 s from $CAMERA_URL (no re-encode)"
    LD_LIBRARY_PATH="$B/lib" "$B/ffmpeg" -nostdin -loglevel error -rtsp_transport tcp \
      -timeout 8000000 -i "$CAMERA_URL" -t 30 -an -c:v copy -y "$WORK/real.mp4"
  fi
  cat > "$WORK/inner_test.sh" <<'INNER'
F=/opt/rkffmpeg2/ffmpeg-wrap; P=/opt/rkffmpeg2/ffprobe-wrap
RTSP="$1"; WHIP="$2"
# 1. the backend's live-view command (1280 wide, Baseline level 4.2, CBR 1500k, GOP 40), published and read back
$F -nostdin -loglevel warning -re -stream_loop -1 -hwaccel rkmpp -hwaccel_output_format drm_prime -c:v h264_rkmpp -t 14 -i /data/real.mp4 \
  -vf scale_rkrga=w=1280:h=-2:format=nv12:force_original_aspect_ratio=decrease -c:v h264_rkmpp -rc_mode CBR -profile:v baseline -level 4.2 -b:v 1500k -g 40 -bf 0 -an \
  -f rtsp -rtsp_transport tcp "$RTSP/test_live/raw" > /tmp/live.log 2>&1 &
sleep 6
echo "RESULT_LIVE:$($P -v error -rw_timeout 6000000 -rtsp_transport tcp -select_streams v:0 -show_entries stream=codec_name,profile,level,width,height -of csv=p=0 "$RTSP/test_live/raw" 2>&1 | head -n 1)"
wait
# 2. a WHIP push with the hardware encoder, read back over RTSP
$F -nostdin -loglevel warning -re -stream_loop -1 -hwaccel rkmpp -hwaccel_output_format drm_prime -c:v h264_rkmpp -t 10 -i /data/real.mp4 -an \
  -vf scale_rkrga=w=854:h=-2:format=nv12 -r 15 -c:v h264_rkmpp -profile:v baseline -level 3.1 -rc_mode CBR -b:v 800k -g 30 -bf 0 \
  -f whip "$WHIP/test_whip/whip" > /tmp/whip.log 2>&1 &
sleep 6
echo "RESULT_WHIP:$($P -v error -rw_timeout 6000000 -rtsp_transport tcp -select_streams v:0 -show_entries stream=codec_name,profile,width,height -of csv=p=0 "$RTSP/test_whip" 2>&1 | head -n 1)"
wait
INNER
  log "Testing the bundle at $B (about 40 seconds)"
  local out
  # shellcheck disable=SC2086
  out="$(docker run --rm --network host --entrypoint bash $DEVICES -v "$WORK":/data:ro -v "$RKDT":/opt/rkdt:ro \
    -v "$B":/opt/rkffmpeg2:ro "$BACKEND_IMAGE" /data/inner_test.sh "$MEDIAMTX_RTSP" "$MEDIAMTX_WHIP" 2>&1)" || true
  local live whip
  live="$(echo "$out" | sed -n 's/^RESULT_LIVE://p' | head -n 1)"
  whip="$(echo "$out" | sed -n 's/^RESULT_WHIP://p' | head -n 1)"
  echo "  live-view command read back: ${live:-<nothing>}"
  echo "  WHIP push read back        : ${whip:-<nothing>}"
  [[ "$live" == "h264,Constrained Baseline,1280,"* ]] || die "the live-view command did not produce a 1280 wide Constrained Baseline stream"
  [[ "$whip" == "h264,Constrained Baseline,854,"* ]] || die "the WHIP push did not arrive as 854 wide Constrained Baseline (is MediaMTX running?)"
  log "Tests passed"
}

# ---------------------------------------------------------------------------------------------------------------
# install: put the staged files into $LIVE, one rename per file; verify through the real backend container; if a check
# fails, put the old files back.
# ---------------------------------------------------------------------------------------------------------------
step_install() {
  local NEW="$WORK/rkffmpeg3" BAK="$LIVE.bak-$(date +%Y%m%d-%H%M%S)"
  [ -d "$NEW/lib" ] || die "run stage first"
  cp -a "$LIVE" "$BAK" || die "could not back up $LIVE"
  log "Safety copy of the current folder: $BAK"

  restore() {
    log "Putting the old files back from $BAK"
    local f
    for f in $(cd "$BAK/lib" && ls); do cp -a "$BAK/lib/$f" "$LIVE/lib/.rb.$f" && mv -f "$LIVE/lib/.rb.$f" "$LIVE/lib/$f"; done
    for f in ffmpeg ffprobe; do cp -a "$BAK/$f" "$LIVE/.rb.$f" && mv -f "$LIVE/.rb.$f" "$LIVE/$f"; done
    for f in $(cd "$LIVE/lib" && ls); do [ -e "$BAK/lib/$f" ] || rm -f "$LIVE/lib/$f"; done
  }
  swap_file() { cp -a "$1" "$(dirname "$2")/.new.$(basename "$2")" && mv -f "$(dirname "$2")/.new.$(basename "$2")" "$2"; }

  local f
  for f in $(cd "$NEW/lib" && ls); do swap_file "$NEW/lib/$f" "$LIVE/lib/$f" || { restore; die "copy failed on lib/$f"; }; done
  for f in ffmpeg ffprobe; do swap_file "$NEW/$f" "$LIVE/$f" || { restore; die "copy failed on $f"; }; done
  log "Files installed in $LIVE"

  local fail=0 C="docker exec $BACKEND_CONTAINER"
  if docker ps --format '{{.Names}}' | grep -qx "$BACKEND_CONTAINER"; then
    local want got
    want="$(md5sum "$NEW/ffmpeg" | cut -d' ' -f1)"
    got="$($C md5sum /opt/rkffmpeg2/ffmpeg | cut -d' ' -f1)"
    if [ "$want" = "$got" ]; then echo "  backend sees the new ffmpeg: ok"; else echo "  backend does NOT see the new ffmpeg"; fail=1; fi
    local muxers
    muxers="$($C /opt/rkffmpeg2/ffmpeg-wrap -hide_banner -muxers 2>&1 || true)"
    if grep -q whip <<<"$muxers"; then echo "  whip muxer visible in the backend: ok"; else echo "  no whip muxer in the backend"; fail=1; fi
    if [ -n "$CAMERA_URL" ]; then
      $C /opt/rkffmpeg2/ffmpeg-wrap -nostdin -loglevel warning -rtsp_transport tcp -timeout 5000000 -hwaccel rkmpp -hwaccel_output_format drm_prime \
        -c:v h264_rkmpp -t 10 -i "$CAMERA_URL" -vf scale_rkrga=w=1280:h=-2:format=nv12:force_original_aspect_ratio=decrease \
        -c:v h264_rkmpp -rc_mode CBR -profile:v baseline -level 4.2 -b:v 1500k -g 40 -bf 0 -an \
        -f rtsp -rtsp_transport tcp "$MEDIAMTX_FROM_BACKEND/test_live/raw" > /tmp/install_check.log 2>&1 &
      sleep 6
      local seen
      seen="$($C /opt/rkffmpeg2/ffprobe-wrap -v error -rw_timeout 6000000 -rtsp_transport tcp -select_streams v:0 \
        -show_entries stream=codec_name,profile,width,height -of csv=p=0 "$MEDIAMTX_FROM_BACKEND/test_live/raw" 2>&1 | head -n 1)"
      wait || true
      echo "  live-view style publish from the camera, read back: ${seen:-<nothing>}"
      [[ "$seen" == "h264,Constrained Baseline,1280,"* ]] || fail=1
    fi
  else
    echo "  WARNING: container $BACKEND_CONTAINER is not running, skipped the checks through it"
  fi
  if [ "$fail" -ne 0 ]; then restore; die "verification failed, the old files are back"; fi
  log "Installed. Live-view ffmpegs that were already running keep the old build until they restart; new ones use the new build."
  log "The safety copy $BAK can be deleted when you are sure."
}

step_clean() {
  docker rm -f "$BUILD_CONTAINER" >/dev/null 2>&1 || true
  rm -f "$WORK"/inner_build.sh "$WORK"/inner_bundle.sh "$WORK"/inner_test.sh
  log "Removed the build container and the generated helper files (kept out/, rkffmpeg3/, build.log and any samples)"
}

case "${1:-}" in
  build)   step_build ;;
  bundle)  step_bundle ;;
  stage)   step_stage ;;
  test)    step_test ;;
  install) step_install ;;
  clean)   step_clean ;;
  all)     step_build; step_bundle; step_stage; step_test; step_install ;;
  *)       sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
