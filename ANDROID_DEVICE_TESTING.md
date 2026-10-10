# Android device testing

How the Android GL present path is tested on real devices, what testing found,
and the decisions that followed. Read this before changing how Rive textures
reach Flutter on Android, and add to it when you test again.

## The present path

Flutter's `ImageReader` waits for each buffer's GPU fence on the platform
thread before it can use the buffer. On native Mali and PowerVR drivers, the
fence a swap produces covers every command submitted on the swapping EGL
context, not only the surface being swapped. So swapping every Rive texture
from one shared render context makes each widget wait on every other widget's
GPU work, and stalls the app's platform thread with it.

Each texture therefore renders offscreen on the render context, and a present
thread with its own context blits the finished frame to the texture's window
surface and swaps. The texture presents directly from the render context
instead whenever that cannot run: no present context or pbuffer, no OpenGL ES 3
config or context, no EGL fence sync, a multisampled window config, or GL
provided by ANGLE (below).

## Running the benchmark

The example app has a renderer benchmark page that opens straight from a deep
link, which is what scripted runs use:

```sh
adb shell "am start -a android.intent.action.VIEW \
  -d 'riveexample://bench?asset=little_machine.riv&count=4&stats=1' \
  com.example.rive_example"
```

Parameters: `asset` (one of the page's feather-free and feathered files),
`count` (1-16 widgets), `shared=1` (one `RivePanel` texture instead of one per
widget), `move=1`, `dots` (0-60 animating Flutter dots), `layout=1`
(`RenderResolution.layout()`), `pages` (0-20 kept-alive pages),
`renderer=flutter`, and `stats=1`, which logs one `[rive-bench]` line a
second with the app's frame rate and Rive's replay rate.

Locally, measure from a perfetto trace rather than the app's own counters:
`queueBuffer` into each `ImageReader-*` is that texture's real update rate,
and the raster thread's `queueBuffer` is the app's frame rate. `dumpsys
meminfo <package>` reports `Graphics:` for the whole process, which includes
Flutter's buffers as well as Rive's textures, so compare two builds of the same
app rather than reading one total. `DIAGNOSTICS.md` documents the
`debug.rive.gl_fbo` and `debug.rive.gl_msaa` switches for A/B tests on one
build.

On a device farm, `packages/rive_flutter/example/tool/browserstack_bench.py`
runs the page on BrowserStack App Automate across a device list and prints a
table. Credentials come from the environment and outputs stay under the
example's ignored `build/` directory.

## What to compare against

Compare against 0.14.11, not 0.15.0-dev.2. The 0.15.0-dev releases used one
pacing budget for every texture, which starves whichever textures tick last:
with 8 widgets, 3 drew and the other 5 stayed blank. That makes dev.2 look
fast and cheap exactly where it is failing, both in frame rate and memory.
0.14.11 draws every widget. It predates the replay counters, but it draws
inside the app's frames, so its app frame rate is also its update rate.

Do not compare feathered content against the Flutter renderer: it does not draw
vector feathering, so it is rendering something different.

## Devices

Local: a Galaxy Tab A7 Lite (PowerVR GE8320, GPU bound) and a Pixel 8a
(Mali-G715). On BrowserStack, chosen for spread of GPU vendor, GL
implementation, refresh rate and tier:

| Device | Android | GPU | Why |
| --- | --- | --- | --- |
| Galaxy S20 | 10 | Mali-G77 | oldest driver available |
| Vivo Y21 | 11 | PowerVR GE8320 | low end, same GPU as the Tab A7 Lite |
| Galaxy M32 | 11 | Mali-G52 | low-end Mali |
| Pixel 6 | 12 | Mali-G78, 90 Hz | |
| Galaxy S22 | 12 | Xclipse 920 | GL through ANGLE on Vulkan 1.1 |
| Pixel 7 | 13 | Mali-G710, 90 Hz | |
| Galaxy S23 | 13 | Adreno 740 | |
| Galaxy S24 | 14 | Xclipse 940 | GL through ANGLE on Vulkan 1.3 |
| Galaxy Tab A9+ | 14 | Adreno | low-end tablet |

## Native GL and ANGLE

On Samsung's Xclipse GPUs, OpenGL ES is ANGLE translating to Vulkan rather
than a native driver. Logcat shows it at startup, for example `I/ANGLE ...
Renderer (ANGLE (Samsung Xclipse 920) on Vulkan 1.1.179)`, and the renderer
reports it as `isANGLESystemDriver`.

The offscreen present regressed badly there. On the S22, per widget:

| Scenario | 0.14.11 | Offscreen present | Direct present |
| --- | --- | --- | --- |
| 4 small | 30.3 | 24.1 | 30.0 |
| 8 small | 29.5 | 13.1 | 29.9 |
| 4 clip-heavy | 25.6 | 7.5 | 30.0 |

The direct present runs at full rate, so the context-wide fence the offscreen
path works around does not exist on ANGLE, and the offscreen path's context
switches and blits are pure cost. The S24's newer ANGLE regressed only
slightly (clip-heavy 24.4 against 25.9 direct), but never gained.

Decision: when GL is ANGLE, present directly. The log then reads `Rive GL
present: direct (ANGLE)`. Verified afterwards on the S22 (29.8, 29.9, 29.9)
and S24, with the Pixel 7 still on the offscreen path.

On these devices Vulkan is the native driver and Rive's Vulkan backend is the
long-term answer, since it removes the translation layer altogether.

## Results, 2026-09-22

Updates per second per widget, then the app's frame rate. 0.14.11 shows the app
frame rate only, which is also its update rate. The clip-heavy file was a
standalone app's `rope.riv`; the runner above uses the example app's
`vehicles.riv`, so its numbers are not directly comparable to these.

| Device | Scenario | 0.14.11 | 0.15.0-dev.2 | This change |
| --- | --- | --- | --- | --- |
| Galaxy S20 | 4 small | 53.6 | 29.9, app 60.4 | 59.7, app 59.7 |
| | 8 small | 45.6 | 14.9, app 60.1 | 55.3, app 57.9 |
| | 4 clip-heavy | 29.5 | 22.6, app 52.5 | 30.7, app 59.7 |
| Vivo Y21 | 4 small | not captured | 29.2, app 59.1 | 39.9, app 52.1 |
| | 8 small | not captured | 14.7, app 58.9 | 22.1, app 51.3 |
| | 4 clip-heavy | not captured | 5.8, app 14.7 | 5.0, app 59.2 |
| Galaxy M32 | 4 small | 31.0 | 29.6, app 60.0 | 59.2, app 58.7 |
| | 8 small | 23.9 | 14.9, app 60.3 | 50.4, app 55.7 |
| | 4 clip-heavy | 14.2 | 14.3, app 41.5 | 19.8, app 49.7 |
| Pixel 6 | 4 small | 59.9 | 30.0, app 60.1 | 59.9, app 59.4 |
| | 8 small | 59.6 | 15.0, app 60.2 | 60.0, app 60.0 |
| | 4 clip-heavy | 39.3 | 28.3, app 57.7 | 53.6, app 59.4 |
| Galaxy S22 | 4 small | 30.3 | 15.0, app 30.3 | 29.8, app 29.7 |
| | 8 small | 29.5 | 7.6, app 30.0 | 29.9, app 29.9 |
| | 4 clip-heavy | 25.6 | 14.6, app 29.8 | 29.9, app 30.2 |
| Pixel 7 | 4 small | 89.6 | 45.0, app 89.8 | 89.8, app 89.8 |
| | 8 small | 86.1 | 22.5, app 90.2 | 90.1, app 90.0 |
| | 4 clip-heavy | 42.9 | 32.0, app 64.7 | 49.8, app 90.9 |
| Galaxy S23 | 4 small | 30.1 | 15.1, app 30.0 | 30.0, app 30.3 |
| | 8 small | 29.9 | 7.6, app 30.1 | 30.0, app 30.2 |
| | 4 clip-heavy | 24.1 | 14.9, app 30.0 | 30.0, app 30.3 |
| Galaxy S24 | 4 small | 30.1 | 15.0, app 29.7 | 30.0, app 30.1 |
| | 8 small | 30.0 | 7.5, app 30.0 | 30.0, app 29.9 |
| | 4 clip-heavy | 22.5 | 14.2, app 28.9 | 25.9, app 25.8 |
| Galaxy Tab A9+ | 4 small | 51.8 | 34.5, app 72.5 | 66.0, app 66.7 |
| | 8 small | 39.0 | 17.9, app 72.0 | 52.9, app 59.4 |
| | 4 clip-heavy | 15.0 | 12.7, app 31.3 | 10.6, app 70.1 |

S22 and S24 rows for this change are from the verification run after the
ANGLE decision. One trade-off is visible on low-end Adreno: on the Tab A9+ a
clip-heavy widget updates about a third less often than on 0.14.11 (10.6
against 15.0 a second), while the app runs at 70 fps instead of 15, because
0.14.11 held the whole app to Rive's pace.

## Stress, 2026-09-22

Leaks show as growth, not as a level, so these are worth rerunning after any
change to texture lifetime. On the Tab A7 Lite and Pixel 8a:

| | 4 min churning widget count, mode and route | 45 s idle after | 3 min of a texture created and destroyed ~9 times a second |
| --- | --- | --- | --- |
| Galaxy Tab A7 Lite | 80 MB | 81 MB | 186-191 MB, flat |
| Pixel 8a | 200 MB | 198 MB | 434-491 MB, oscillating, no trend |

The last column is the example app's "Memory cleanup test" page. The churn
columns came from a standalone harness that changes the widget count, mode
and route every 400 ms; the example app has no equivalent yet. After heavy
churn, Mali frees deleted textures lazily, so GL memory can sit high for up
to a minute before settling.

## Known gaps

- BrowserStack's Galaxy S22, S23 and S24 ran at 30 Hz, so there is no 120 Hz
  data. Rows capped at 30 show only that nothing regressed.
- The oldest Android on BrowserStack is 10, and every device tested took the
  OpenGL ES 3 path, so the ES 2 fallback has not run on a real device.
- BrowserStack has no adb shell: no `dumpsys meminfo`, and no way to set the
  `debug.rive.*` switches. The direct-present comparison above used a build
  with the offscreen path turned off by default.
- 0.14.11 has no replay counters; its update rate is read from the app's
  frame rate.
