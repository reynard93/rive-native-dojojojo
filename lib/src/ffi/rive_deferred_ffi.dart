import 'dart:ffi';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'package:rive_native/src/deferred_session_factory.dart';
import 'package:rive_native/src/ffi/dynamic_library_helper.dart';
import 'package:rive_native/src/ffi/rive_ffi.dart';
import 'package:rive_native/src/ffi/rive_renderer_ffi.dart';
import 'package:rive_native/src/ffi/scripting_workspace_ffi.dart';
import 'package:rive_native/src/rive.dart';

export 'package:rive_native/src/deferred_session_factory.dart';

/// Setup-only FFI for the deferred recording session. Per-frame work
/// branches inside the existing native entry points once the session is
/// attached to a RenderTexture, so there is no per-frame Dart code.
final DynamicLibrary _nativeLib = DynamicLibraryHelper.open();

final Pointer<Void> Function(Pointer<Void> realOre) _makeDeferredSession =
    _nativeLib
        .lookup<NativeFunction<Pointer<Void> Function(Pointer<Void>)>>(
            'riveMakeDeferredSession')
        .asFunction();

final void Function(Pointer<Void>) _deleteDeferredSession = _nativeLib
    .lookup<NativeFunction<Void Function(Pointer<Void>)>>(
        'riveDeleteDeferredSession')
    .asFunction();

/// A deferred recording session as a Dart [Factory]. Dispose after every file
/// and texture that used it is gone, the recorder must outlive everything it
/// recorded.
class FFIDeferredFactory extends FFIFactory with DeferredSessionFactory {
  FFIDeferredFactory(Pointer<Void> realOre)
      : super(_makeDeferredSession(realOre));

  FFIDeferredFactory._owned(super.session);

  @override
  int get sessionAddress => pointer.address;

  @override
  ({int recordUs, int replayUs, int frames, int streamPeakBytes})
      sampleThreadStats() {
    final recordOut = malloc.allocate<Uint64>(8);
    final replayOut = malloc.allocate<Uint64>(8);
    final framesOut = malloc.allocate<Uint32>(4);
    final streamPeakOut = malloc.allocate<Uint64>(8);
    _deferredThreadStats(
        pointer, recordOut, replayOut, framesOut, streamPeakOut);
    final result = (
      recordUs: recordOut.value,
      replayUs: replayOut.value,
      frames: framesOut.value,
      streamPeakBytes: streamPeakOut.value
    );
    malloc.free(recordOut);
    malloc.free(replayOut);
    malloc.free(framesOut);
    malloc.free(streamPeakOut);
    return result;
  }

  @override
  void dispose() {
    if (pointer != nullptr) {
      _deleteDeferredSession(pointer);
      pointer = nullptr;
    }
  }
}

final Pointer<Void> Function(Pointer<Void>) _contextDeferredSession = _nativeLib
    .lookup<NativeFunction<Pointer<Void> Function(Pointer<Void>)>>(
        'riveContextDeferredSession')
    .asFunction();

// Lazily resolved so a stale native library missing the symbol degrades to a
// no-op (caching stays disabled) instead of throwing at load.
void Function(Pointer<Void> session, Pointer<Void> rc)?
    _deferredSessionBindRenderContext;

/// Binds the process render context to [session] so its
/// `factory()->renderContext()` resolves — required for native off-screen
/// canvases (cache-as-bitmap) that must allocate against the context the frame
/// replays on. No-op when the session or context is unavailable, or on a stale
/// native library. Idempotent.
void bindDeferredSessionRenderContext(Factory? session) {
  final sessionAddr = deferredSessionAddress(session);
  if (sessionAddr == 0 ||
      !_nativeLib.providesSymbol('riveDeferredSessionBindRenderContext')) {
    return;
  }
  final rc = FFIRiveFactory.instance.nativePointerAddress;
  if (rc == 0) {
    return;
  }
  final bind = _deferredSessionBindRenderContext ??= _nativeLib
      .lookup<NativeFunction<Void Function(Pointer<Void>, Pointer<Void>)>>(
          'riveDeferredSessionBindRenderContext')
      .asFunction();
  bind(Pointer<Void>.fromAddress(sessionAddr), Pointer<Void>.fromAddress(rc));
}

FFIDeferredFactory? _contextSession;

/// The render context's session: every file imports through it and every
/// artboard instances against it, so one recording serves every texture.
/// Owned by the context, so nothing here disposes it.
Factory? contextDeferredRiveFactory() {
  // Cache first: Factory.rive resolves through here, so this runs per access.
  final cached = _contextSession;
  if (cached != null) {
    return cached.isSupported ? cached : null;
  }
  if (!deferredTextureSupported ||
      !_nativeLib.providesSymbol('riveContextDeferredSession')) {
    return null;
  }
  // The raw factory, not Factory.rive: that getter resolves back to us.
  final rc =
      Pointer<Void>.fromAddress(FFIRiveFactory.instance.nativePointerAddress);
  if (rc == nullptr) {
    return null;
  }
  final session = _contextDeferredSession(rc);
  if (session == nullptr) {
    return null;
  }
  final factory = FFIDeferredFactory._owned(session);
  factory.autoAttach = true;
  _contextSession = factory;
  return factory;
}

/// Guards against a stale native library missing any deferred symbol this
/// file resolves eagerly. A partial ABI falls back to the immediate path with
/// one message instead of throwing at whichever lookup runs first.
bool? _deferredAbiComplete;
bool get deferredTextureSupported {
  final cached = _deferredAbiComplete;
  if (cached != null) {
    return cached;
  }
  const symbols = [
    'riveTextureUseDeferredSession',
    'riveContextDeferredSession',
    'riveMakeDeferredSession',
    'riveDeleteDeferredSession',
    'riveDeferredThreadStats',
  ];
  for (final symbol in symbols) {
    if (!_nativeLib.providesSymbol(symbol)) {
      debugPrint('rive_native: deferred rendering disabled, the native '
          'library is missing $symbol. A stale build usually causes this.');
      return _deferredAbiComplete = false;
    }
  }
  return _deferredAbiComplete = true;
}

/// A recording session with no real ore context and no GPU, so tests can
/// exercise the deferred path type headlessly.
Factory? makeHeadlessDeferredFactory() {
  if (!deferredTextureSupported) {
    return null;
  }
  return FFIDeferredFactory(nullptr);
}

/// Create a deferred recording factory wrapping the process ore context, or
/// null when unsupported. One per imported file, reusable across reloads.
Factory? makeDeferredRiveFactory() {
  if (!deferredTextureSupported) {
    return null;
  }
  final oreAddress = initGPUScriptingForPlatform();
  if (oreAddress == 0) {
    return null;
  }
  final factory = FFIDeferredFactory(Pointer<Void>.fromAddress(oreAddress));
  if (!factory.isSupported) {
    return null;
  }
  return factory;
}

final void Function(Pointer<Void>, Pointer<Uint64>, Pointer<Uint64>,
        Pointer<Uint32>, Pointer<Uint64>) _deferredThreadStats =
    _nativeLib
        .lookup<
            NativeFunction<
                Void Function(
                    Pointer<Void>,
                    Pointer<Uint64>,
                    Pointer<Uint64>,
                    Pointer<Uint32>,
                    Pointer<Uint64>)>>('riveDeferredThreadStats')
        .asFunction();


bool _checkedFlushDestroys = false;
void Function()? _flushDestroys;

/// Frees resources whose deferred handles have died. Destroys otherwise wait
/// for the session's next drawn frame, which an idle app may never produce.
/// Call after disposing content when nothing else is drawing. macOS, iOS and
/// Windows only; elsewhere it does nothing and the next frame carries them.
@internal
void flushDeferredDestroys() {
  if (!_checkedFlushDestroys) {
    _checkedFlushDestroys = true;
    if (_nativeLib.providesSymbol('riveDeferredFlushDestroysAll')) {
      _flushDestroys = _nativeLib
          .lookup<NativeFunction<Void Function()>>(
              'riveDeferredFlushDestroysAll')
          .asFunction();
    }
  }
  _flushDestroys?.call();
}
