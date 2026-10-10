// ignore_for_file: invalid_export_of_internal_element

/// Deferred recording. The factory wraps a native DeferredSession which is a
/// rive::Factory, so file import records every resource instead of touching
/// the driver. Attach the session to a RenderTexture to record and replay.
library;

export 'src/deferred_session_factory.dart'
    show detachAndDisposeDeferredSession;
export 'src/ffi/rive_deferred_ffi.dart'
    if (dart.library.js_interop) 'src/web/rive_deferred_web.dart'
    show
        makeDeferredRiveFactory,
        makeHeadlessDeferredFactory,
        deferredSessionAddress,
        deferredThreadStats,
        deferredAttachedTexture,
        setDeferredAttachedTexture,
        deferredBoundToOneTexture,
        textureDisplaying,
        setTextureDisplaying,
        deferredAutoAttach,
        enableDeferredAutoAttach,
        flushDeferredDestroys;
