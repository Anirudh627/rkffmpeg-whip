# Rebuilding the Rockchip ffmpeg with WHIP, OpenSSL and libvpx

Written 2026-10-11 after the build was done and tested on the Axelera Embedded 111c board (RK3588, Voyager Linux
1.3.3). Results are in `FFMPEG_WHIP_TEST_RESULTS.md`, what was changed on the board and how to undo it is in
`FFMPEG_SWAP_AND_ROLLBACK.md`, and why we wanted it is in `STREAMING_SERVICE_PLAN.md`.

## Why a new build

DeepInsight's live view uses `rkffmpeg2`, an ffmpeg with the Rockchip hardware encoder, decoder and scaler
(`h264_rkmpp`, `scale_rkrga`). To publish a stream to Cloudflare Stream over WebRTC (WHIP) we needed an ffmpeg with the
`whip` muxer. The old `rkffmpeg2` had none: it was built without a TLS library, so there was no `whip` muxer, no
`https` and no `tls` protocol, and no `libvpx`. The stock `/usr/bin/ffmpeg` of the board (2023) has neither the
Rockchip hardware support nor `whip`. Upstream FFmpeg (`github.com/FFmpeg/FFmpeg`, `release/8.1`) has `whip` but no
`rkmpp` or `rkrga`, so it cannot replace the live view's ffmpeg.

## What `rkffmpeg2` is (measured from the binary, not from a recipe)

| Fact | Source |
|---|---|
| FFmpeg version string `d90e3a1`; libavformat 62.12.102, libavcodec 62.28.102, libavutil 60.26.102 | `ffmpeg -version` |
| Configured with `--enable-cross-compile --cross-prefix=aarch64-linux-gnu- --enable-gpl --enable-version3 --enable-libdrm --enable-rkmpp --enable-rkrga --enable-shared --prefix=/out`, built with Ubuntu 22.04 gcc 11 | `ffmpeg -version` |
| It is the master of the Rockchip fork `github.com/nyanmisaka/ffmpeg-rockchip` at commit `d90e3a1` (2026-08-10) | the fork's `master` is that commit; the string matches |
| Bundled with `rkdt` (device-tree dump) and `dt_redirect.so`, packed as `rkffmpeg2_rkdt.tar.gz` and fetched by `scripts/02_setup_rkffmpeg2.sh` from a GitHub release of `hrithik-naik/rk3588-migration` | the script |
| The build recipe itself is not in this repo or in that repo (it has only a README) | read both |

Its MPP library is `0986d01` (Yandong Lin, 2026-08-26) and its RGA library is `librga.so.2.1.0`.

## The new build

Same fork, same commit (`d90e3a1`), same flags, plus `--enable-openssl --enable-libvpx`:

```
./configure --prefix=/out --enable-gpl --enable-version3 --enable-libdrm --enable-rkmpp --enable-rkrga \
  --enable-openssl --enable-libvpx --enable-shared --disable-static --disable-doc --disable-htmlpages --disable-manpages
```

Result: `whip` muxer present; `h264_rkmpp` encoder and decoder, `scale_rkrga`, `libvpx` (VP8) and `libvpx-vp9`
present; `https`, `tls` and `dtls` protocols present.

### How it was built

A native build on the board, inside a throwaway `ubuntu:22.04` (aarch64) container, so there was no cross-compile.
`docker run -d` with two mounts: the build folder and an output folder. The script
(`/home/antelao/shared/ffmpeg-whip-build/build.sh` on the board) does, in order:

1. `apt-get install build-essential git cmake meson ninja-build pkg-config libdrm-dev libssl-dev libvpx-dev`.
2. Clone and build MPP (`jellyfin-mpp`, commit `a9380ef`) and RGA (`jellyfin-rga`, commit `1d330cc`) into `/out`.
3. Clone `ffmpeg-rockchip` master, configure as above, `make -j6` under `nice`, `make install`.
4. Collect the shared libraries ffmpeg needs (libssl, libcrypto, libvpx, libdrm, libstdc++, libgcc_s) into
   `/out/bundle-libs`.

Build time: the first build took longer than later ones (an estimate from timestamps: about 25 minutes, with gitee
dropping connections, three restarts and cameras running). Run again from nothing with the single script on a quiet
board, `build` took 7.5 minutes (15:00:37 to 15:08:08) and `build`, `bundle`, `stage` and `test` together 8 min 20 s.
**That rebuild produced an `ffmpeg` byte for byte identical to the published one** (md5 `12cf735c2250ca375d41db14b818dc36`
both), so the build is reproducible from the sources and flags in `build_rkffmpeg_whip.sh`.

## What went wrong, and what was done

| # | Problem | Cause | Fix |
|---|---|---|---|
| 1 | `git clone` from gitee ended with `early EOF` three times | gitee drops long clones from this network | Use GitHub `github.com/nyanmisaka/rk-mirrors` branches `jellyfin-mpp` and `jellyfin-rga` (same commits as gitee); gitee stays as the fallback |
| 2 | `github.com/nyanmisaka/mpp` asked for a login | that repository does not exist | see 1 |
| 3 | The clone function ran with empty arguments | the patch was sent over ssh in an unquoted heredoc, so the board's shell expanded `$1`, `$2` and `"$@"` | Send scripts as files with a quoted heredoc |
| 4 | `bundle-libs` was empty, ffmpeg would not start (`libvpx.so.7` missing) | the library-collecting `awk` was mangled by nested quoting, and `|| true` hid the error | A separate `bundle.sh` run in a container |
| 5 | Shell scripts failed with `set: pipefail: invalid option name` | this laptop's git has `core.autocrlf=true`, so files sent to the board had CRLF | Strip `\r` on the board (`tr -d '\r'`), see item 5 of `SLIM_SDK_ISSUES_LOG.md` |
| 6 | The new ffmpeg failed with `Failed to init MPP context: -1` | the new build's MPP (`jellyfin-mpp`) did not initialise against this board's kernel driver, while the old bundle's MPP `0986d01` does | Keep `librockchip_mpp*` and `librga*` from the old `rkffmpeg2` and link the new ffmpeg against them. The jellyfin MPP and RGA libraries built here are not used. Cause of the mismatch not investigated |

Board quirks hit on the way: the host has no `timeout`, no `nice`, a BusyBox `nc` with no `-z`, and a BusyBox `head`
that wants `-n N`. The board's host `bash` is real bash 5.1, but `sh` and tools are BusyBox.

## Where things are on the board

| Path | What |
|---|---|
| `/home/antelao/shared/ffmpeg-whip-build/out/` | the build output (`bin/`, `lib/`, `bundle-libs/`, `COMMIT.txt`) |
| `/home/antelao/shared/ffmpeg-whip-build/rkffmpeg3/` | the staged bundle: old wrappers and `dt_redirect.so`, new ffmpeg/ffprobe/libs, old MPP/RGA |
| `/home/antelao/shared/ffmpeg-whip-build/build.sh`, `bundle.sh`, `stage.sh`, `swap.sh` | the scripts that were run |
| `/home/antelao/shared/ffmpeg-whip-build/real.mp4` | 30 s of real camera footage used for the tests (59.7 MB; delete when done) |
| `/home/antelao/shared/ffmpeg-whip-build/sample.mp4` | a synthetic test pattern, made when the camera was offline; not used for any result |
| container `ffmpeg-whip-build` | the stopped build container; `docker rm ffmpeg-whip-build` removes it |

## Rebuilding

Start from `build.sh`, but use the fixes in the table: GitHub mirror first, `bundle.sh` for the libraries, strip
CRLF, and after the install replace `librockchip_mpp*` and `librga*` in the bundle with the ones from `rkffmpeg2`.

## Published, and how new boards get it (done 2026-10-11)

- The bundle is published in `https://github.com/Anirudh627/rkffmpeg-whip` as a plain file in `main`
  (`rkffmpeg2_rkdt.tar.gz`, 17.8 MB, SHA-256 `a70028b69c893a7ac4fa107ef5093d640b8b2c3d27171c0cdb6d67dd94c5bc01`),
  together with `build_rkffmpeg_whip.sh` and copies of these docs. It is a file in the repository and not a GitHub release,
  because no `gh` login was available; the download link is `.../raw/main/rkffmpeg2_rkdt.tar.gz`.
- `scripts/02_setup_rkffmpeg2.sh` now downloads that file, checks the SHA-256 before extracting, and accepts
  `RELEASE_URL`, `RELEASE_SHA256` and `RKFFMPEG2_ARCHIVE` (a local file, for a board without internet). The earlier source
  was the `hrithik-naik/rk3588-migration` release `v1` (the bundle without `whip`).
- A fresh board therefore never compiles: it downloads the 18 MB file. Compiling (`build_rkffmpeg_whip.sh`) is only
  needed to produce a new bundle.
- Because the file lives on `main`, pushing a newer build changes what the link serves; the checksum in the script
  protects against a mismatch, so update the script's checksum together with the file.

### Clean-install test on the board (2026-10-11)

All ffmpeg builds made during the work were removed (the live `rkffmpeg2` emptied but the folder kept, because the backend
container has it mounted; the staged copy, the compile output, the archive and the build container deleted; the
operating system's own `/usr/bin/ffmpeg` was not touched). Then `scripts/02_setup_rkffmpeg2.sh` was run: it downloaded
the file from GitHub, verified it and installed it.

| Check | Result |
|---|---|
| Installed `ffmpeg` checksum against the one inside the archive | identical (`12cf735c...`) |
| The backend container's view of the file | same checksum; `ffmpeg version d90e3a1`; `whip`, `h264_rkmpp`, `libvpx`, `libvpx-vp9` present |
| Live-view command on the installed folder (`build_rkffmpeg_whip.sh test`, `BUNDLE=/home/antelao/rkffmpeg2`) | `h264, Constrained Baseline, 1280x854, level 42` |
| WHIP push with the hardware encoder to MediaMTX | `h264, Constrained Baseline, 854x570` |

Then DeepInsight's own live view was checked on the installed folder (14:45): the `cam-001` ffmpeg that had been running
was stopped and the operator reloaded the live view; DeepInsight started a new one.

| Check | Result |
|---|---|
| Input | `rtsp://192.168.1.69:8080/h264.sdp` |
| Runs from | `/opt/rkffmpeg2/ffmpeg`, not a deleted file; the process's executable has the same checksum as the installed file (`12cf735c...`) |
| Libraries | 8 `libssl`/`libvpx` mappings, so it is the WHIP build |
| `cam-001/raw` in MediaMTX | H.264 Constrained Baseline, level 4.2, 1280x854, 30 fps; 141 frames in 5 seconds |
| Backend log for `cam-001` | no non-`mpp` lines (no errors) |

Not checked: the picture in a browser, the annotated stream for that camera, long runs, and Cloudflare.

## Not done

- The MPP mismatch (item 6) was worked around, not explained. A future rebuild of MPP should be checked against the
  kernel driver version.
- The release is a file on `main`, not a GitHub release with an attached asset; switch the link if you create one.
