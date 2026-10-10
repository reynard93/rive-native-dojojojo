import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:rive_native/src/ffi/dynamic_library_helper.dart';
import 'package:rive_native/src/rml_compile_result.dart';

export 'package:rive_native/src/rml_compile_result.dart';

final DynamicLibrary _nativeLib = DynamicLibraryHelper.nativeLib;

/// Whether the loaded native library carries the markup symbols. False in
/// flutter_runtime builds, where rml is excluded (editor-only); callers (and
/// tests) must check before using [revToRml] or [rmlToRev] -- the
/// lazily-initialized lookups below throw on first use otherwise. Both
/// directions are probed: they come from one translation unit, so a library
/// carrying only one of them is a stale build, and failing closed sends
/// callers down their fallback instead of throwing.
final bool markupAvailable = () {
  try {
    for (final symbol in ['freeRmlExport', 'freeRmlCompile']) {
      _nativeLib.lookup<NativeFunction<Void Function(Pointer<Void>)>>(symbol);
    }
    return true;
  } on ArgumentError {
    return false;
  }
}();

final class _RmlExportResponseStruct extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int size;
}

final bool Function(
  Pointer<Uint8> bytes,
  int length,
  Pointer<_RmlExportResponseStruct> response,
) _revToRml = _nativeLib
    .lookup<
        NativeFunction<
            Bool Function(Pointer<Uint8>, Uint64,
                Pointer<_RmlExportResponseStruct>)>>('revToRml')
    .asFunction();

final void Function(Pointer<_RmlExportResponseStruct> response)
    _freeRmlExport = _nativeLib
        .lookup<
            NativeFunction<
                Void Function(
                    Pointer<_RmlExportResponseStruct>)>>('freeRmlExport')
        .asFunction();

/// Converts the bytes of a .rev file into the equivalent .rml markup
/// document, with every payload embedded. Returns null when the bytes are not
/// a readable .rev.
Uint8List? revToRml(Uint8List revBytes) {
  if (revBytes.isEmpty) {
    return null;
  }
  final source = calloc<Uint8>(revBytes.length);
  final response = calloc<_RmlExportResponseStruct>();
  try {
    source.asTypedList(revBytes.length).setAll(0, revBytes);
    final ok = _revToRml(source, revBytes.length, response);
    if (!ok || response.ref.data == nullptr || response.ref.size <= 0) {
      return null;
    }
    // A view over native memory; copy it out before freeing.
    return Uint8List.fromList(
      response.ref.data.asTypedList(response.ref.size),
    );
  } finally {
    _freeRmlExport(response);
    calloc.free(response);
    calloc.free(source);
  }
}

final class _RmlCompileResponseStruct extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int size;

  external Pointer<Uint8> error;

  @Size()
  external int errorSize;
}

final void Function(
  Pointer<Uint8> bytes,
  int length,
  Pointer<_RmlCompileResponseStruct> response,
) _rmlToRev = _nativeLib
    .lookup<
        NativeFunction<
            Void Function(Pointer<Uint8>, Uint64,
                Pointer<_RmlCompileResponseStruct>)>>('rmlToRev')
    .asFunction();

final void Function(Pointer<_RmlCompileResponseStruct> response)
    _freeRmlCompile = _nativeLib
        .lookup<
            NativeFunction<
                Void Function(
                    Pointer<_RmlCompileResponseStruct>)>>('freeRmlCompile')
        .asFunction();

/// Compiles a .rml markup document into the equivalent .rev bytes -- the
/// inverse of [revToRml]. Every payload the document needs must be embedded
/// in it: a `file=` reference has no directory to resolve against here and
/// compiles as an error.
RmlCompileResult rmlToRev(Uint8List rmlBytes) {
  if (rmlBytes.isEmpty) {
    return const RmlCompileResult.failure('0: no markup to compile\n');
  }
  final source = calloc<Uint8>(rmlBytes.length);
  final response = calloc<_RmlCompileResponseStruct>();
  try {
    source.asTypedList(rmlBytes.length).setAll(0, rmlBytes);
    _rmlToRev(source, rmlBytes.length, response);
    if (response.ref.data != nullptr && response.ref.size > 0) {
      // A view over native memory; copy it out before freeing.
      return RmlCompileResult.success(
        Uint8List.fromList(response.ref.data.asTypedList(response.ref.size)),
      );
    }
    if (response.ref.error != nullptr && response.ref.errorSize > 0) {
      return RmlCompileResult.failure(
        utf8.decode(
          response.ref.error.asTypedList(response.ref.errorSize),
          allowMalformed: true,
        ),
      );
    }
    return const RmlCompileResult.failure('0: markup compile failed\n');
  } finally {
    _freeRmlCompile(response);
    calloc.free(response);
    calloc.free(source);
  }
}
