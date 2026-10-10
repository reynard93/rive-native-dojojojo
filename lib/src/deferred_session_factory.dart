import 'package:rive_native/rive_native.dart' show RenderTexture;
import 'package:rive_native/src/rive.dart';
import 'package:rive_native/src/rive_renderer.dart';

/// Shared surface of a deferred recording session [Factory]. Platform
/// classes supply construction and the raw native calls.
mixin DeferredSessionFactory on Factory {
  /// The most recent texture this session replays into, so the owner can
  /// detach before disposal. A session that serves a whole render context
  /// has several; this names the last one to attach.
  Object? attachedTexture;

  /// Every texture attached right now, so disposal can detach them all.
  final Set<Object> attachedTextures = {};

  /// Sessions decode created for a file attach automatically. Manually
  /// managed sessions like the editor process session do not.
  bool autoAttach = false;

  /// Whether this session's replay is tied to a single texture's render
  /// context, so a second texture would resolve recorded handles against a
  /// context that never created them.
  bool get boundToOneTexture => false;

  /// The native session address, 0 once disposed.
  int get sessionAddress;

  @override
  bool get isSupported => sessionAddress != 0;

  @override
  Future<void> completedDecodingFile(bool success) async {}

  @override
  bool isValidRenderer(Renderer renderer) => true;

  /// Sample and reset the native busy time counters.
  ({int recordUs, int replayUs, int frames, int streamPeakBytes})
      sampleThreadStats();

  void dispose();
}

/// The native session address; 0 when this is not a live session.
int deferredSessionAddress(Factory? factory) =>
    factory is DeferredSessionFactory ? factory.sessionAddress : 0;

/// Tracked so owners can detach before the session dies.
Object? deferredAttachedTexture(Factory factory) =>
    factory is DeferredSessionFactory ? factory.attachedTexture : null;

void setDeferredAttachedTexture(Factory factory, Object? texture) {
  if (factory is DeferredSessionFactory) {
    factory.attachedTexture = texture;
    if (texture != null) {
      factory.attachedTextures.add(texture);
    }
  }
}

/// Every texture attached to [factory] right now.
Set<Object> deferredAttachedTextures(Factory factory) =>
    factory is DeferredSessionFactory ? factory.attachedTextures : const {};

/// [texture] is leaving [factory]; it also gives up the last-attached slot
/// when it held it.
void forgetDeferredAttachedTexture(Factory factory, Object texture) {
  if (factory is DeferredSessionFactory) {
    factory.attachedTextures.remove(texture);
    if (identical(factory.attachedTexture, texture)) {
      factory.attachedTexture = null;
    }
  }
}

/// Whether this session can only ever replay into one texture, so a second
/// one has to be refused however distinct its content is.
bool deferredBoundToOneTexture(Factory factory) =>
    factory is DeferredSessionFactory && factory.boundToOneTexture;

/// Which texture displays each artboard instance. Weak on the instance, so a
/// released artboard drops its claim without anyone having to say so.
final Expando<RenderTexture> _displayingTexture = Expando<RenderTexture>();

/// The texture displaying [artboard], live or not. One artboard instance is
/// one animation state, so only one texture may show it at a time.
RenderTexture? textureDisplaying(Artboard artboard) =>
    _displayingTexture[artboard];

void setTextureDisplaying(Artboard artboard, RenderTexture? texture) {
  _displayingTexture[artboard] = texture;
}

/// Whether the render box should attach this session itself.
bool deferredAutoAttach(Factory factory) =>
    factory is DeferredSessionFactory && factory.autoAttach;

void enableDeferredAutoAttach(Factory factory) {
  if (factory is DeferredSessionFactory) {
    factory.autoAttach = true;
  }
}

/// Producer and consumer busy time since the last call, plus the largest
/// stream any one of those frames recorded. Zeros when no deferred session is
/// active. It is a high water mark sampled at snapshot rather than a live
/// read, because a session's stream drains at the frame boundary.
({int recordUs, int replayUs, int frames, int streamPeakBytes})
    deferredThreadStats(Factory factory) {
  if (factory is! DeferredSessionFactory || factory.sessionAddress == 0) {
    return (recordUs: 0, replayUs: 0, frames: 0, streamPeakBytes: 0);
  }
  return factory.sampleThreadStats();
}

/// Detach first so the replay worker drains before the session dies.
void detachAndDisposeDeferredSession(Factory? session) {
  if (session is! DeferredSessionFactory) {
    return;
  }
  // Copied since a detach removes itself from the set.
  for (final texture in session.attachedTextures.toList()) {
    if (texture is RenderTexture && !texture.isDisposed) {
      texture.useDeferredSession(null);
    }
  }
  session.attachedTextures.clear();
  session.attachedTexture = null;
  session.dispose();
}
