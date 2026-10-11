# rkffmpeg-whip

Author: Anirudh R Rao

The Rockchip hardware ffmpeg (`h264_rkmpp`, `scale_rkrga`) rebuilt with the **WHIP muxer** (WebRTC publishing, through
OpenSSL) and **libvpx** (VP8 and VP9), for RK3588 boards running DeepInsight. It replaces the `rkffmpeg2` bundle that the
DeepInsight live view uses, and it can push a stream to a WebRTC service such as Cloudflare Stream.

## Download

The bundle is a file in this repository, version v1 (built 2026-10-11):

```
https://github.com/Anirudh627/rkffmpeg-whip/raw/main/rkffmpeg2_rkdt.tar.gz
SHA-256  a70028b69c893a7ac4fa107ef5093d640b8b2c3d27171c0cdb6d67dd94c5bc01
```

The file on `main` changes when a newer build is pushed; DeepInsight's setup script checks the SHA-256 above, so it
refuses a file that does not match.

## What is in the download

`rkffmpeg2_rkdt.tar.gz` (about 18 MB) holds two folders, in the layout `scripts/02_setup_rkffmpeg2.sh` of
DeepInsight expects:

| Folder | Content |
|---|---|
| `rkffmpeg2/` | `ffmpeg`, `ffprobe`, the launchers `ffmpeg-wrap` / `ffprobe-wrap`, `dt_redirect.so`, and `lib/` (the ffmpeg libraries, libssl, libcrypto, libvpx, libdrm, and the MPP and RGA libraries of the earlier bundle) |
| `rkdt/` | the device-tree dump the launchers use |

`SHA256SUMS` has its checksum. Check it before installing: `sha256sum -c SHA256SUMS`.

## What it can do (measured on one RK3588 board, 2026-10-11)

- Hardware decode, scale and encode as before, with the same CPU cost as the old bundle (about 0.1 cores each).
- `-f whip` publishing of **H.264**. The WHIP muxer rejected VP8 and VP9.
- Software VP8 and VP9 encoders are present (`libvpx`, `libvpx-vp9`), at a much higher CPU cost.

Details, numbers and what was not tested: `docs/FFMPEG_WHIP_TEST_RESULTS.md`.

## Installing on a board

With DeepInsight's `scripts/02_setup_rkffmpeg2.sh` (it downloads this release, checks the checksum and installs in place).
By hand, on a board without internet:

```sh
RKFFMPEG2_ARCHIVE=/path/to/rkffmpeg2_rkdt.tar.gz bash scripts/02_setup_rkffmpeg2.sh
```

It installs into `/home/antelao/rkffmpeg2` and `/home/antelao/rkdt` by copying into the existing folders (never replacing
the folders), so a running DeepInsight backend keeps its mounts.

## Building it yourself

`build_rkffmpeg_whip.sh` does everything on the board: build in a throwaway Ubuntu 22.04 container, collect libraries,
stage, test, install. Read `docs/FFMPEG_WHIP_HOWTO_BUILD.md` first; the story and the problems met are in
`docs/FFMPEG_WHIP_BUILD.md`.

## Source and licenses

The binaries are built from these sources, so anyone can rebuild them with the script above:

| Component | Source |
|---|---|
| ffmpeg | `github.com/nyanmisaka/ffmpeg-rockchip`, `master` at commit `d90e3a1` (2026-08-10) |
| Rockchip MPP / RGA (runtime libraries of the earlier bundle) | the earlier bundle's `librockchip_mpp` (`0986d01`) and `librga` 2.1.0; the build script also builds `jellyfin-mpp` `a9380ef` and `jellyfin-rga` `1d330cc` from `github.com/nyanmisaka/rk-mirrors`, which were not used on the board |
| OpenSSL 3, libvpx 1.11 | Ubuntu 22.04 packages |

Configure options: `--enable-gpl --enable-version3 --enable-libdrm --enable-rkmpp --enable-rkrga --enable-openssl
--enable-libvpx --enable-shared`. The build is therefore under the **GNU GPL, version 3 or later**. The licenses of FFmpeg,
the Rockchip libraries, OpenSSL and libvpx apply to their parts. This note is not legal advice: check it with whoever
handles licensing before distributing.

## Known limits

- The WHIP muxer takes H.264 only.
- The build keeps the old MPP and RGA libraries: the MPP built from `jellyfin-mpp` failed on the test board with
  `Failed to init MPP context: -1`. The cause was not investigated.
- Tested on one board with one camera, one run per case. Nothing was tested against Cloudflare yet.
