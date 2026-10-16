# rive_native

Rive Native is a Dart plugin that interfaces with the [core Rive C++ runtime](https://github.com/rive-app/rive-runtime), powered by the [Rive Renderer](https://rive.app/renderer).

## Dojojojo Android fork

This fork provides `rive_native 0.2.0-dev.3+dojojojo.1` as a Git dependency pinned to a commit SHA. It is based on the [published dev.3 source archive](https://pub.dev/api/archives/rive_native-0.2.0-dev.3.tar.gz), SHA-256 `0acff64554fc0973a6624daa0b0c0261ec00cde744df4b9e3daea2fa8a7b85a8`, with upstream example/test fixtures omitted. Original licenses are retained.

`AndroidRenderTextureFrameSink.beginCanvasContent()` restores GL bindings before offscreen Canvas replay. Without this hook, the screen flush leaves internal textures unbound and the next canvas loses its contents.

`PathDraw` marks source paint opaque only when opacity and colour-alpha modulation also remain fully opaque. Otherwise the depth/stencil MSAA path disables blending for translucent paint: a zero-alpha replay erases pixels already drawn, including offscreen Canvas clears. A debug invariant checks the resulting solid-paint alpha. Android arm64 emulator regression proof draws a red square followed by an opaque green paint modulated to alpha zero: the square now stays red instead of exposing the Flutter layer beneath it. All four Android ABIs were built; only arm64 was exercised in the emulator.

Android setup and Gradle validate all four patched libraries before deciding whether to compile. A valid cache skips compilation; a missing or invalid cache builds patched source, never downloaded stock binaries. Legacy completion markers are ignored. Source builds require NDK r27c (`27.2.12479018`); setup checks `NDK_PATH/source.properties` before invoking the build. Install Ninja, make, Python 3 and Git, plus `shasum` (`CertUtil` on Windows). Native objects remain available for incremental builds, but CI caches only the four libraries and their manifest, not source, markers, dependencies or objects.

For manual Android setup, set `ANDROID_HOME` to the SDK used by `android/local.properties`, then run from the app root:

```sh
NDK_PATH="$ANDROID_HOME/ndk/27.2.12479018" fvm dart run rive_native:setup --platform android
```

To get cache metadata without installing an NDK or building, run from the app root:

```sh
dart run rive_native:setup --android-cache-info
```

This prints only one JSON object with `key`, `path`, `revision`, `ndkVersion` and `configuration`. `path` is the resolved package's absolute `android/src/main/jniLibs` directory. `revision` is that checkout's actual 40-character Git HEAD, not `version.txt`. `configuration` is `release android flutter-runtime`, the exact arguments passed to `native/build.sh`; that script builds shared `librive_native.so` libraries for `armeabi-v7a`, `arm64-v8a`, `x86` and `x86_64`. The key binds the revision, pinned NDK, configuration and host OS/architecture. Absolute paths are excluded from identity so CI can restore to a different checkout path.

Cache `path` as one directory, including its hidden `.rive-native-cache.json` manifest. Use an exact CI cache key with no prefix restore keys, and always run Android setup after restoring it. The manifest records that identity plus each expected library's full SHA-256 digest. Setup validates all four ELF classes, shared-object types, machine architectures and digests on every invocation, including Gradle. Cache absence, malformed manifests, identity mismatches, missing libraries, bad ELF headers and checksum mismatches log the rejection reason and build source. Real Git, filesystem, checksum-tool and build failures fail setup instead of hiding the error. Cache hits and metadata lookup do not require an installed NDK.

`--clean --platform android` removes the destination and forces a source build even for a valid cache. Setup removes stale manifests before building and writes a new one only after a successful source build and artifact validation. Direct `native/build.sh` Android builds invalidate manifests but cannot create trusted cache metadata.

Other platforms retain official binaries identified by the unchanged `version.txt` and `hash.txt`; these source fixes ship automatically only on Android. When upgrading Rive, rebase both patches and repeat effects-enabled Android rendering checks; remove the fork when an upstream release includes both fixes.


Additional documentation:

- [Rive Flutter getting started guide](https://rive.app/docs/runtimes/flutter/flutter)
- [What is Rive Native](https://rive.app/docs/runtimes/flutter/rive-native)
- [Migration guides](https://rive.app/docs/runtimes/flutter/migration-guide)

For up to date information on Rive Native, see the [official documentation](https://rive.app/docs/runtimes/flutter/rive-native).

## Which Package to use

While you can use `rive_native` on its own, we recommend using the [Rive Flutter package](https://pub.dev/packages/rive) (version `0.14.0+`). The `rive` package includes `rive_native` as a dependency and provides a more intuitive runtime API.

## Getting started

`rive_native` is not yet publicly available on GitHub but will be soon. For now, you can pull the source code and example by running:

```bash
dart pub unpack rive_native # Unpack the package source code and example app
cd rive_native/example      # Navigate to the example folder
flutter create .            # Create the platform folders
flutter pub get             # Fetch dependencies
flutter run                 # Run the example app
```

A higher-level declarative API is under development to simplify working with Rive graphics in Flutter.

For an example implementation, see the `rive_player.dart` file in `rive_native/example/rive_player.dart`.

---

## Platform support

| Platform | Flutter Renderer | Rive Renderer |
| -------- | ---------------- | ------------- |
| iOS      | ✅               | ✅            |
| Android  | ✅               | ✅            |
| macOS    | ✅               | ✅            |
| Windows  | ✅               | ✅            |
| Linux    | ✅               | ✅            |
| Web      | ✅               | ✅            |

---

## Feature support

All core Rive features are supported. See [Feature Support](https://rive.app/docs/feature-support) for more information.

---

## Troubleshooting

Outside Android, the required native libraries should be automatically downloaded during the build step (`flutter run` or `flutter build`). Android validates its patched-library cache or builds patched source. If you encounter issues, try the following:

1. Run `flutter clean`
2. Run `flutter pub get`
3. Run `flutter run`

Alternatively, you can manually run the `rive_native` setup script. In the root of your Flutter app, execute:

```bash
dart run rive_native:setup --verbose --clean --platform macos
```

This will clean the `rive_native` setup and download the platform-specific libraries specified with the `--platform` flag. Refer to the **Platform Support** section above for details.

---

## Building `rive_native`

Outside Android, prebuilt native libraries are downloaded and used by default. To build those platforms from source, use the `--build` flag with the setup script. Android builds from source on a cache miss, or whenever `--clean` is requested. In the root of your Flutter app:

```bash
flutter clean # Important
flutter pub get
dart run rive_native:setup --verbose --clean --build --platform macos
```

See [Building rive_native](https://rive.app/docs/runtimes/flutter/rive-native#building-rive_native) in the official docs for the required tooling per platform, supported `--platform` values, web specifics, and how to return to the prebuilt libraries.

---

## Testing

Shared libraries are included in the download/build process. If you've done `flutter run` on the native platform, the libraries should already be available.

Otherwise, manually download the prebuilt libraries by doing:

```bash
dart run rive_native:setup --verbose --clean --platform macos
```

Specify the desired `--platform`, options are `macos`, `windows`, and `linux`.

Now you can run `flutter test`.

Android cache behavior tests use temporary real ELF files and the normal checksum tool; no native compilation is needed:

```sh
flutter test test/android_cache_test.dart
```

Optionally build the libraries if desired:

```bash
dart run rive_native:setup --verbose --clean --build --platform macos
```

If you encounter issues using `rive_native` in your tests, please reach out to us for assistance.

## Support

- Reach out to us on our [Community](https://community.rive.app/feed)
- File an issue on the [Rive Flutter repository](https://github.com/rive-app/rive-flutter/issues)
