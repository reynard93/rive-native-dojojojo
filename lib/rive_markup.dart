/// Rive markup (.rml) conversion backed by packages/rml. Editor-only: the
/// native symbols are excluded from flutter_runtime builds, so this library
/// must never be imported from runtime code paths.
library;

export 'src/ffi/rive_markup_ffi.dart'
    if (dart.library.js_interop) 'src/web/rive_markup_web.dart'
    show revToRml, rmlToRev, RmlCompileResult, markupAvailable;
