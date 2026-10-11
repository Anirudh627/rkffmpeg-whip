# Test results for the WHIP-capable ffmpeg build

Date 2026-10-11, board antelao-3588 (RK3588). Build and background: `FFMPEG_WHIP_BUILD.md`. Everything here was
measured on the board unless it says "guess".

## How the tests were run

- **Source:** 30 seconds of the real camera (`IP Webcam` app, H.264 High, 720x480, about 30 fps, about 15.9 Mbit/s),
  recorded without re-encoding. Used as a file with `-re` (real-time rate) and `-stream_loop -1`.
- **Environment:** a throwaway container from the backend's own image (`standard-backend`), with the same four
  device nodes the backend gets (`/dev/mpp_service`, `/dev/dma_heap/system`, `/dev/dma_heap/cma`, `/dev/rga`) and
  `rkdt` mounted, and the bundle under test mounted at `/opt/rkffmpeg2`. WHIP tests used `--network host`.
- **Pipeline:** hardware decode (`h264_rkmpp`, `drm_prime`), `scale_rkrga` to 854 wide (854x570), 15 fps, 800 kbit/s,
  15 seconds per case, output to `-f null`. CPU is user+system seconds of the ffmpeg process divided by wall time.
- **Limits:** one run per case, no repeats, so there is no variance figure. The board was running its normal
  workload (load average about 4.8 at the start): inference, the kiosk browser and a live view.

## 1. Old build versus new build (hardware path)

| Case | Old `rkffmpeg2` | New build |
|---|---|---|
| Hardware decode and scale only | 0.11 cores | 0.10 cores |
| Hardware H.264 encode (`h264_rkmpp`, Baseline) | 0.08 cores | 0.08 cores |

Both kept up in real time (speed 1.04x). No difference between the builds on the hardware path.

## 2. Software encoders on the same input (new build only; the old one has no libvpx)

| Encoder | CPU | Kept up in real time |
|---|---|---|
| `libvpx` (VP8), `-deadline realtime -cpu-used 8` | 3.07 cores | yes (1.04x) |
| `libvpx-vp9`, `-deadline realtime -cpu-used 8 -row-mt 1` | 1.18 cores | yes (1.04x) |

Thread settings were left at their defaults and not tuned. The VP8 figure is higher than VP9, which is the opposite of
what one would expect, and was not investigated. Image quality at 800 kbit/s was not compared.

## 3. WHIP to the board's MediaMTX (test path `test_whip`)

MediaMTX 1.9.3 accepts WHIP publishing from anyone (user `any` has publish and read permission). Read back over RTSP.

| What was pushed | Result |
|---|---|
| `cam-002/raw` (H.264 Constrained Baseline L4.2, 1280x854, 30 fps) with `-c:v copy`, 15 s | arrived: `h264, Constrained Baseline, 1280x854`; 440 frames |
| Hardware encode `h264_rkmpp` Baseline level 3.1, 854x570, 15 fps, 800k | arrived: `h264, Constrained Baseline, 854x570` |
| `libvpx` (VP8) | rejected: `Error sending frames to consumers: Invalid argument`, nothing written |
| `libvpx-vp9` | rejected, same error |

The same VP8 and VP9 encodes ran fine to a null output (section 2), so the rejection comes from the `whip` muxer.
It is consistent with the muxer being H.264 only (its help says default video codec h264), but the muxer source was not read.

## 4. The live view's exact command, old versus new

The backend's real ffmpeg arguments (hardware decode, `scale_rkrga=w=1280:h=-2:format=nv12:force_original_aspect_ratio=decrease`,
`h264_rkmpp` CBR 1500k, Baseline level 4.2, GOP 40, no B-frames, RTSP out), published to a test path, read back:

| Bundle | Read back | Frames in 4 s |
|---|---|---|
| old | h264, Constrained Baseline, 1280x854, level 42, 30/1 | 110 |
| new | h264, Constrained Baseline, 1280x854, level 42, 30/1 | 110 |

## 5. Network, from the board

| Check | Result |
|---|---|
| HTTPS to `api.cloudflare.com` | reachable, certificate valid (HTTP 400 for an unauthenticated request) |
| STUN request to `stun.cloudflare.com:3478` | reply received, so outbound UDP works from this site |

## What was not tested

- **Anything on Cloudflare.** No account or live input was available: no real WHIP push to Cloudflare, no playback
  latency, no check of whether Cloudflare accepts these profiles.
- **Several cameras at once**, the hardware encoder's shared throughput limit
  (`voyager_servicecpp/docs/RKVENC_THROUGHPUT_CEILING.md`) while an extra WHIP encode runs, and long runs.
- **Real-camera H.264 Baseline pass-through of the camera itself:** the camera sends High profile, the Baseline
  stream is the backend's own `cam-NNN/raw` re-encode.

## A known problem that showed up again (not caused by the new build)

Hardware decode of a live RTSP stream produced by the board's own encoder stalls inside the backend container: ffmpeg
prints `Setting BufferSourceContext.pix_fmt to a HW format requires hw_frames_ctx to be non-NULL!` and no frames
arrive. This is item 1 of `SLIM_SDK_ISSUES_LOG.md`. It hit the old and the new build alike when reading
`cam-001/raw`; reading a file, or the camera directly, worked. The tests above therefore used a file.
