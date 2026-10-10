# Deferred rendering diagnostics

Repo-internal tools for diagnosing frame pacing with the deferred renderer
(`Factory.rive` on native platforms). Not part of the public API - the
counters live in `lib/src/` unexported and are off by default, with zero cost
while off.

Two complementary measures:

| Tool | Measures | Where |
| --- | --- | --- |
| `RiveDeferredPacingDiagnostics` | What the driver did with each ticker tick: painted, or skipped and why (worker behind, paused, attach blocked, failed clear/flush), plus ticked-vs-painted animation time | `lib/src/deferred_pacing_diagnostics.dart` (dedicated-texture path, i.e. `RiveWidget` and friends; the `RivePanel` shared path is not instrumented) |
| `deferredThreadStats` | How long record and replay take (busy microseconds and frame count since last sample) | `package:rive_native/rive_deferred.dart` (public advanced API) |

## Using them

- **Example app overlay**: the rive_flutter example wraps every page in
  `RivePacingOverlayHost` (`example/lib/pacing_overlay.dart`). Tap the speed chip
  (top right) to toggle a readout. The headline is `rive N/s (n/s x T tex) ·
  flutter M fps`: `rive` is the session-wide replay (draw) rate - the number
  that drops under load - with the per-texture share alongside it, and
  `flutter` is the app frame rate, which stays at 60 when the pipeline is
  healthy even while Rive content paces lower. The pacing line is normalized
  per texture (the raw counters are sums across every ticking texture);
  `time N%` is painted vs ticked animation time, 100% = no banking. `record`
  / `replay` are per-frame averages - they legitimately shrink as instances
  are added (smaller textures, and boosted CPU clocks under load). This is
  the fastest way to look at a device.
- **Console**: set `RiveDeferredPacingDiagnostics.enabled = true` and
  `logToConsole = true` (implementation import from `lib/src/`) - one
  `RIVEPACE` line per second via `debugPrint`, readable over adb logcat / CI
  logs.
- **Programmatic**: set `RiveDeferredPacingDiagnostics.onWindow` to receive each
  ~1s `RiveDeferredPacingWindow` record.

Note `deferredThreadStats` resets its counters on every read - one sampler at
a time (the overlay assumes it is the only one).

## Reading the numbers

- `ticks` - driver ticks (one per Flutter frame while animating).
- `paints` - ticks that recorded a frame. `paints < ticks` means pacing gates
  skipped the difference.
- `skips worker` (`canAcceptDeferredFrame` false) - the replay worker is the
  pacer; the producer holds off so the stateful command stream never drops a
  recorded frame.
- `skips paused / blocked` - recording paused (iOS backgrounding) or another
  widget already displays this artboard instance.
- `time painted/ticked` - animation seconds painted vs elapsed. They track
  each other even when worker/clear-fail skips are high: those skipped ticks
  bank their elapsed into the next paint. Paused ticks are the exception -
  paused time is dropped by design (a pause freezes the animation rather than
  fast-forwarding it on resume), so it widens the gap. Outside pauses, a
  persistently growing gap would be a bug.
- `record / replay` - per-frame busy cost of recording (UI thread) and replay
  (render thread), from `deferredThreadStats`.

Interpretation:

| Pattern | Meaning |
| --- | --- |
| rive == flutter == 60 | Healthy: everything at full rate. |
| flutter 60, rive < flutter, `skips worker` high, time tracking | The render pipeline is the pacer, not a bug: the app stays smooth and the texture updates at what the replay cycle sustains. For a single texture the cycle is largely size-independent (replay CPU + fence/buffer latency), so shrinking the texture may not raise cadence; multiple textures pipeline and lift aggregate rate. |
| flutter well below 60, ticks == paints == flutter fps, threads look idle | The frame pipeline itself is stalled (e.g. a consumer blocking on GPU fences, the Android symptom before offscreen present). Take a perfetto trace; look for `waitForever` on the main/raster thread. |
| paints 0, `skips blocked` | This widget's artboard instance is displayed by another widget; give each widget its own instance. |
| ticks 0 while a RivePanel animates | Expected: the panel's shared path is not instrumented by these counters. |

Worked example: the Android present fix started from these counters
showing fps ~35 with ticks == paints == fps and zero skips - everything
moving in lockstep at a reduced rate, so the loss had to be a stall outside
the driver loop. A perfetto trace then located it: the platform thread
blocked in `Fence::waitForever` acquiring Rive's ImageReader buffer before
its GPU work had signaled.

## Android GL testing switches

The Android GL backend reads two system properties once, when it creates its
GL context. Set them over adb and restart the app:

```sh
adb shell setprop debug.rive.gl_fbo 0    # present directly from the render context
adb shell setprop debug.rive.gl_msaa 1   # MSAA instead of the renderer's choice
adb shell setprop debug.rive.gl_fbo "''" # unset: back to the default
```

| Property | Unset (shipping) | Set |
| --- | --- | --- |
| `debug.rive.gl_fbo` | Offscreen present where the device supports it (`ANDROID_DEVICE_TESTING.md` lists when it does not): each texture renders into rotating offscreen textures (up to three, allocated only as contention demands), and a present thread with its own GL context blits the finished one to the Flutter surface and swaps. | `0`: render into the surface and swap on the render thread. Flutter's platform thread then blocks on Rive's GPU work when it acquires the buffer. |
| `debug.rive.gl_msaa` | The renderer picks pixel local storage or MSAA per GPU. | `1`: disable pixel local storage, which forces MSAA. |

The log line `Rive GL present: offscreen|direct [(ANGLE)] [(msaa forced)]`
confirms what the process is running; `(ANGLE)` means the offscreen path was
skipped because GL is ANGLE. Both switches exist for testing. Shipping
behavior is the unset one.

