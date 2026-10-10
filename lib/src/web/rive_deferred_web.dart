import 'dart:js_interop' as js;

import 'dart:js_interop_unsafe';
import 'package:meta/meta.dart';

import 'package:rive_native/src/deferred_session_factory.dart';
import 'package:rive_native/src/rive.dart';
import 'package:rive_native/src/web/rive_web.dart';

export 'package:rive_native/src/deferred_session_factory.dart';

/// Web deferred recording. The session is created null-bound since no real
/// ore context exists at file import time on web, and late-binds when
/// attached to a render texture.
late js.JSFunction _makeDeferredSession;
late js.JSFunction _deleteDeferredSession;
late js.JSFunction _rendererUseDeferredSession;
late js.JSFunction _sampleStats;
late js.JSFunction _lastRecordUs;
late js.JSFunction _lastReplayUs;
late js.JSFunction _lastFrames;
// Postdates the thread stats, so null on older wasm builds.
js.JSFunction? _lastStreamPeakBytes;
bool _linked = false;

class DeferredWasm {
  static void link(js.JSObject module) {
    _makeDeferredSession = module['_riveMakeDeferredSession'] as js.JSFunction;
    _deleteDeferredSession =
        module['_riveDeleteDeferredSession'] as js.JSFunction;
    _rendererUseDeferredSession =
        module['rendererUseDeferredSession'] as js.JSFunction;
    _sampleStats = module['_riveDeferredSampleStats'] as js.JSFunction;
    _lastRecordUs = module['_riveDeferredLastRecordUs'] as js.JSFunction;
    _lastReplayUs = module['_riveDeferredLastReplayUs'] as js.JSFunction;
    _lastFrames = module['_riveDeferredLastFrames'] as js.JSFunction;
    _lastStreamPeakBytes =
        module['_riveDeferredLastStreamPeakBytes'] as js.JSFunction?;
    _linked = true;
  }
}

class WebDeferredFactory extends WebFactory with DeferredSessionFactory {
  WebDeferredFactory(super.pointer);

  @override
  int get sessionAddress => (pointer as js.JSNumber).toDartInt;

  // Every web RenderTexture builds its own WebGL context, render context and
  // ore context, and the session late binds to the first one that attaches.
  // A second texture would replay handles its own context never created, so
  // two distinct artboard instances still cannot share one web session.
  @override
  bool get boundToOneTexture => true;

  @override
  ({int recordUs, int replayUs, int frames, int streamPeakBytes})
      sampleThreadStats() {
    _sampleStats.callAsFunction(null, pointer);
    final streamPeak = _lastStreamPeakBytes;
    return (
      recordUs: (_lastRecordUs.callAsFunction(null) as js.JSNumber).toDartInt,
      replayUs: (_lastReplayUs.callAsFunction(null) as js.JSNumber).toDartInt,
      frames: (_lastFrames.callAsFunction(null) as js.JSNumber).toDartInt,
      streamPeakBytes: streamPeak == null
          ? 0
          : (streamPeak.callAsFunction(null) as js.JSNumber).toDartInt,
    );
  }

  @override
  void dispose() {
    if (sessionAddress != 0) {
      _deleteDeferredSession.callAsFunction(null, pointer);
      pointer = 0.toJS;
    }
  }
}

/// The web session never binds an ore context at creation, so headless is
/// the same construction.
Factory? makeHeadlessDeferredFactory() => makeDeferredRiveFactory();

Factory? makeDeferredRiveFactory() {
  if (!_linked) {
    return null;
  }
  final session = _makeDeferredSession.callAsFunction(null, 0.toJS);
  if (session == null || (session as js.JSNumber).toDartInt == 0) {
    return null;
  }
  return WebDeferredFactory(session);
}

/// The session late-binds to the renderer's contexts on attach.
void webRendererUseDeferredSession(js.JSAny? rendererPtr, int sessionAddress) {
  if (!_linked) {
    return;
  }
  _rendererUseDeferredSession.callAsFunction(
      null, rendererPtr, sessionAddress.toJS);
}

/// Not implemented on web: destroys wait for the session's next drawn frame.
/// A flush there must run on the replay worker with the owning canvas's GL
/// context current.
@internal
void flushDeferredDestroys() {}
