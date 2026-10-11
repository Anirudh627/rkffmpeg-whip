# How to build the rkffmpeg-whip bundle (step by step)

A runnable guide for building the Rockchip ffmpeg with the `whip` muxer, OpenSSL and libvpx, and putting it in place of
`rkffmpeg2` on a board. The story of how it was first built, what failed and why is in `FFMPEG_WHIP_BUILD.md`; the
measurements are in `FFMPEG_WHIP_TEST_RESULTS.md`; undoing a swap is in `FFMPEG_SWAP_AND_ROLLBACK.md`. The scripts below
are the ones that worked on 2026-10-11 on antelao-3588, with the fixes found on the way already applied.

## What you get

An ffmpeg 8.1-series (`ffmpeg-rockchip` commit `d90e3a1`) with: `h264_rkmpp` encoder and decoder, `scale_rkrga`, the
`whip` muxer (DTLS through OpenSSL), `https`/`tls`, and `libvpx` (VP8) and `libvpx-vp9`. The `whip` muxer accepts H.264
only (VP8 and VP9 were rejected in the tests).

## Before you start

| Need | Check |
|---|---|
| A board with Docker and internet access (GitHub reachable; gitee is flaky from some networks) | `docker ps`; `curl -sI https://github.com` |
| About 3 GB free on the data disk for the build container and output | `df -h /data` |
| The existing `rkffmpeg2` and `rkdt` folders (`scripts/02_setup_rkffmpeg2.sh` installs them) | `ls /home/antelao/rkffmpeg2 /home/antelao/rkdt` |
| The backend image `standard-backend` on the board (used for the tests) | `docker images standard-backend` |
| About 25 to 30 minutes. The build uses 6 of 8 cores at the lowest priority; do it when the board is not busy | |

Rules for every file you send from a Windows laptop: this repo's checkout may have CRLF line endings (git
`core.autocrlf=true`). Send scripts with the `\r` removed, or `bash` fails with `set: pipefail: invalid option name`:

```sh
tr -d '\r' < build.sh | ssh root@<board> 'cat > /home/antelao/shared/ffmpeg-whip-build/build.sh'
```

The board's host shell tools are BusyBox: there is no `timeout` or `nice`, `head` needs `-n N`, `nc` has no `-z`. Send
scripts as files with a **quoted** heredoc (`<<'EOF'`); an unquoted one is expanded by the board's shell first.

All paths below are on the board. Make the working folder first:

```sh
mkdir -p /home/antelao/shared/ffmpeg-whip-build/out
```

## Step 1. The build script

Save as `/home/antelao/shared/ffmpeg-whip-build/build.sh`. It runs inside a throwaway `ubuntu:22.04` container (the same
distribution `rkffmpeg2` was built with).

```bash
#!/bin/bash
# Builds ffmpeg-rockchip with whip (OpenSSL) and libvpx inside a throwaway ubuntu:22.04 container.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential git ca-certificates cmake meson ninja-build pkg-config \
  libdrm-dev libssl-dev libvpx-dev python3
mkdir -p /work/src /out && cd /work/src

clone() { # branch dest url...   tries every url up to three times
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
# GitHub mirror first (gitee drops the connection from some networks); gitee as the fallback.
clone jellyfin-mpp rkmpp https://github.com/nyanmisaka/rk-mirrors.git https://gitee.com/nyanmisaka/mpp.git
clone jellyfin-rga rkrga https://github.com/nyanmisaka/rk-mirrors.git https://gitee.com/nyanmisaka/rga.git
clone "" ffmpeg https://github.com/nyanmisaka/ffmpeg-rockchip.git

export PKG_CONFIG_PATH=/out/lib/pkgconfig
cmake -S rkmpp -B rkmpp_build -DCMAKE_INSTALL_PREFIX=/out -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DBUILD_TEST=OFF
nice -n 19 cmake --build rkmpp_build -j6
cmake --install rkmpp_build
meson setup rkrga_build rkrga --prefix=/out --libdir=lib --buildtype=release --default-library=shared \
  -Dcpp_args=-fpermissive -Dlibdrm=false -Dlibrga_demo=false
nice -n 19 ninja -C rkrga_build install

cd ffmpeg
git log -1 --format='ffmpeg-rockchip commit %h %cd' | tee /out/COMMIT.txt
./configure --prefix=/out --enable-gpl --enable-version3 --enable-libdrm --enable-rkmpp --enable-rkrga \
  --enable-openssl --enable-libvpx --enable-shared --disable-static --disable-doc --disable-htmlpages --disable-manpages
nice -n 19 make -j6
make install
echo BUILD-DONE
```

The flags are those of the existing `rkffmpeg2` plus `--enable-openssl --enable-libvpx`. After the clone, `COMMIT.txt`
should read `d90e3a1`. The tested build used the fork's `master`, which was that commit on 2026-10-11. To make the build
reproducible, pin it (not tried): drop `--depth=1` for ffmpeg, or `git fetch --depth=1 origin d90e3a1 && git checkout
d90e3a1`.

## Step 2. Run the build

```sh
cd /home/antelao/shared/ffmpeg-whip-build
docker run -d --name ffmpeg-whip-build \
  -v /home/antelao/shared/ffmpeg-whip-build:/work-host \
  -v /home/antelao/shared/ffmpeg-whip-build/out:/out \
  ubuntu:22.04 bash -c 'mkdir -p /out; bash /work-host/build.sh > /work-host/build.log 2>&1; echo exit=$? >> /work-host/build.log'
```

Follow it with `tail -f build.log`. It is finished when the last line is `exit=0` (just before it: `BUILD-DONE`). If it
ends with `exit=128` the clone failed (network): run step 2 again. Remove the old container first:
`docker rm -f ffmpeg-whip-build`. Cloning is the only step that has failed randomly.

## Step 3. Collect the libraries

The build is dynamically linked; it needs libssl, libcrypto, libvpx, libdrm and the C++ runtime next to it. Save as
`/home/antelao/shared/ffmpeg-whip-build/bundle.sh` and run it in a container that has the same distribution:

```bash
#!/bin/bash
# Collect the shared libraries the new ffmpeg/ffprobe need (except glibc) into /out/bundle-libs.
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
for b in /out/bin/ffmpeg /out/bin/ffprobe; do LD_LIBRARY_PATH=/out/lib:/out/bundle-libs ldd "$b" | grep 'not found'; done
echo "bundled:"; ls /out/bundle-libs
```

```sh
D=/home/antelao/shared/ffmpeg-whip-build
docker run --rm -v $D/out:/out -v $D/bundle.sh:/bundle.sh:ro ubuntu:22.04 bash /bundle.sh
```

Expected: nothing under "not found:", and `libcrypto.so.3 libdrm.so.2 libgcc_s.so.1 libssl.so.3 libstdc++.so.6 libvpx.so.7`
under "bundled:". Do not put this loop inside `build.sh` with `|| true`: it failed silently there once.

Quick check on the host:

```sh
O=$D/out; export LD_LIBRARY_PATH=$O/lib:$O/bundle-libs
$O/bin/ffmpeg -hide_banner -muxers  | grep whip           # a line with "WHIP"
$O/bin/ffmpeg -hide_banner -encoders | grep -E 'h264_rkmpp|libvpx'
$O/bin/ffmpeg -hide_banner -filters | grep scale_rkrga
```

Do not run hardware decode on the bare host: it is meant for the backend's container environment (the wrapper and
`rkdt`). Test hardware paths as in step 5.

## Step 4. Stage the bundle next to the old one

The new bundle keeps the old wrappers, `dt_redirect.so` **and the old bundle's MPP and RGA libraries**. The MPP built
from `jellyfin-mpp` failed on this board with `Failed to init MPP context: -1`, while the old bundle's MPP (`0986d01`,
2026-08-26) works. Save as `stage.sh` and run it with `sh`:

```sh
#!/bin/sh
set -e
D=/home/antelao/shared/ffmpeg-whip-build
rm -rf $D/rkffmpeg3
cp -a /home/antelao/rkffmpeg2 $D/rkffmpeg3                      # old wrappers, dt_redirect.so, old libs
cp $D/out/bin/ffmpeg $D/out/bin/ffprobe $D/rkffmpeg3/
cp -a $D/out/lib/*.so* $D/rkffmpeg3/lib/                        # new libav*, new mpp/rga (replaced below)
cp -a $D/out/bundle-libs/*.so* $D/rkffmpeg3/lib/
rm -f $D/rkffmpeg3/lib/librockchip_mpp* $D/rkffmpeg3/lib/librga*
cp -a /home/antelao/rkffmpeg2/lib/librockchip_mpp* /home/antelao/rkffmpeg2/lib/librga* $D/rkffmpeg3/lib/
chmod 755 $D/rkffmpeg3/ffmpeg $D/rkffmpeg3/ffprobe
```

## Step 5. Test before touching the live bundle

Run these in a throwaway container of the **backend's image** with the same devices as the backend, with the staged
bundle mounted where the live one would be. Use a recorded file as the source: reading a live `cam-NNN/raw` over RTSP
stalls the hardware decoder in this container (`SLIM_SDK_ISSUES_LOG.md` item 1), for the old build as well.

Record a sample from a camera, no re-encode (30 seconds):

```sh
O=$D/out; export LD_LIBRARY_PATH=$O/lib:$O/bundle-libs
$O/bin/ffmpeg -nostdin -loglevel error -rtsp_transport tcp -timeout 8000000 -i rtsp://<camera>/<path> -t 30 -an -c:v copy -y $D/real.mp4
```

The container command (replace `<BUNDLE>` with `$D/rkffmpeg3`; to compare, use `/home/antelao/rkffmpeg2`):

```sh
docker run --rm -i --network host --entrypoint sh \
  --device /dev/mpp_service --device /dev/dma_heap/system --device /dev/dma_heap/cma --device /dev/rga \
  -v $D:/data:ro -v /home/antelao/rkdt:/opt/rkdt:ro -v <BUNDLE>:/opt/rkffmpeg2:ro \
  standard-backend:latest -s < test.sh
```

`test.sh`, the backend's live-view command with the file as input, publishing to a test path and reading it back:

```sh
F=/opt/rkffmpeg2/ffmpeg-wrap; P=/opt/rkffmpeg2/ffprobe-wrap
U=rtsp://127.0.0.1:8554/test_live/raw
$F -nostdin -loglevel warning -re -stream_loop -1 -hwaccel rkmpp -hwaccel_output_format drm_prime -c:v h264_rkmpp -t 14 -i /data/real.mp4 \
  -vf scale_rkrga=w=1280:h=-2:format=nv12:force_original_aspect_ratio=decrease -c:v h264_rkmpp -rc_mode CBR -profile:v baseline -level 4.2 -b:v 1500k -g 40 -bf 0 -an \
  -f rtsp -rtsp_transport tcp $U > /tmp/l.log 2>&1 &
sleep 6
$P -v error -rw_timeout 6000000 -rtsp_transport tcp -select_streams v:0 -show_entries stream=codec_name,profile,level,width,height -of csv=p=0 $U
wait
```

Pass: `h264,Constrained Baseline,1280,854,42` for the old and the new bundle alike. A `WHIP` push test (anyone may publish
to the board's MediaMTX `test_whip` path; read it back over RTSP):

```sh
$F -nostdin -loglevel warning -re -stream_loop -1 -hwaccel rkmpp -hwaccel_output_format drm_prime -c:v h264_rkmpp -t 10 -i /data/real.mp4 -an \
  -vf scale_rkrga=w=854:h=-2:format=nv12 -r 15 -c:v h264_rkmpp -profile:v baseline -level 3.1 -rc_mode CBR -b:v 800k -g 30 -bf 0 \
  -f whip http://127.0.0.1:8889/test_whip/whip &
sleep 6; $P -v error -rtsp_transport tcp -select_streams v:0 -show_entries stream=codec_name,profile,width,height -of csv=p=0 rtsp://127.0.0.1:8554/test_whip; wait
```

Pass: `h264,Constrained Baseline,854,570`.

## Step 6. Put it in place of rkffmpeg2

Only when step 5 passed. Replace the files in place (rename per file), so running ffmpegs and the backend are not
disturbed. Save as `swap.sh`; it backs up first, verifies inside the **real backend container** and rolls back by itself
if a check fails:

```sh
#!/bin/sh
LIVE=/home/antelao/rkffmpeg2
NEW=/home/antelao/shared/ffmpeg-whip-build/rkffmpeg3
BAK=/home/antelao/rkffmpeg2.bak-$(date +%Y%m%d)
[ -e "$BAK" ] && { echo "backup $BAK exists, stopping"; exit 1; }
cp -a "$LIVE" "$BAK" || exit 1

cat > "$BAK/ROLLBACK.sh" <<RB
#!/bin/sh
B=$BAK; L=$LIVE
for f in \$(cd \$B/lib && ls); do cp -a \$B/lib/\$f \$L/lib/.rb.\$f && mv -f \$L/lib/.rb.\$f \$L/lib/\$f; done
for f in ffmpeg ffprobe; do cp -a \$B/\$f \$L/.rb.\$f && mv -f \$L/.rb.\$f \$L/\$f; done
for f in \$(cd \$L/lib && ls); do [ -e \$B/lib/\$f ] || rm -f \$L/lib/\$f; done
echo rolled back
RB
chmod 755 "$BAK/ROLLBACK.sh"

swap_file() { cp -a "$1" "$(dirname $2)/.new.$(basename $2)" && mv -f "$(dirname $2)/.new.$(basename $2)" "$2"; }
for f in $(cd $NEW/lib && ls); do swap_file "$NEW/lib/$f" "$LIVE/lib/$f" || { sh $BAK/ROLLBACK.sh; exit 1; }; done
for f in ffmpeg ffprobe; do swap_file "$NEW/$f" "$LIVE/$f" || { sh $BAK/ROLLBACK.sh; exit 1; }; done

fail=0; C="docker exec deepinsight_backend"
[ "$(md5sum $NEW/ffmpeg | cut -d' ' -f1)" = "$($C md5sum /opt/rkffmpeg2/ffmpeg | cut -d' ' -f1)" ] || { echo "backend does not see the new ffmpeg"; fail=1; }
$C /opt/rkffmpeg2/ffmpeg-wrap -hide_banner -muxers 2>&1 | grep -q whip || { echo "no whip muxer in backend"; fail=1; }
[ $fail -ne 0 ] && { echo "VERIFY FAILED, rolling back"; sh $BAK/ROLLBACK.sh; exit 1; }
echo "SWAP OK"
```

Add a final check with the backend's own live-view command against a real camera, as the 2026-10-11 swap did, if a
camera is reachable. Live-view ffmpegs that were already running keep the old build until they restart; new ones use the
new build. To confirm which build a running one uses: `grep -c libssl /proc/<pid>/maps` is non-zero only for the new
build (the old one does not load libssl).

## Rolling back

```sh
sh /home/antelao/rkffmpeg2.bak-<date>/ROLLBACK.sh
```

## Cleaning up

```sh
docker rm -f ffmpeg-whip-build
rm -f  /home/antelao/shared/ffmpeg-whip-build/real.mp4 /home/antelao/shared/ffmpeg-whip-build/sample.mp4
rm -rf /home/antelao/shared/ffmpeg-whip-build/out        # keep it if you want to rebuild the bundle without compiling again
```

Keep `rkffmpeg3/` and the backup until the new build has run in production for a while.

## Making it the default for new boards (not done)

`scripts/02_setup_rkffmpeg2.sh` downloads `rkffmpeg2_rkdt.tar.gz` from a GitHub release of `hrithik-naik/rk3588-migration`.
To use this build: pack `rkffmpeg3` (the contents of `/opt/rkffmpeg2`) with `rkdt` as the same layout, upload it as a
new release asset (for example `v2`), and point the script at it. Boards that were set up earlier keep what they have.
Upload and script change need someone with access to that repository; they were not done.

## Known limits

- The `whip` muxer takes H.264 only. VP8 and VP9 need another publisher.
- The MPP/RGA mismatch (step 4) is worked around, not explained.
- Tested on one board with one camera, one run per case.
