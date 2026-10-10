import 'dart:convert';
import 'dart:js_interop' as js;
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:rive_native/src/rive_native_web.dart';
import 'package:rive_native/src/rml_compile_result.dart';

export 'package:rive_native/src/rml_compile_result.dart';

late js.JSObject _module;
late js.JSFunction _revToRml;
late js.JSFunction _freeRmlExport;
late js.JSFunction _rmlToRev;
late js.JSFunction _freeRmlCompile;
bool _linked = false;

/// Whether the wasm module carries the markup exports. False in
/// flutter_runtime builds, where rml is excluded (editor-only).
bool get markupAvailable => _linked;

/// Links the markup wasm exports. Only present in editor builds of the wasm
/// module (rml is excluded from flutter_runtime builds).
class MarkupWasm {
  static void link(js.JSObject module) {
    bool callable(js.JSAny? export) =>
        export != null && export.isA<js.JSFunction>();
    final convert = module['revToRmlWasm'];
    final free = module['freeRmlExportWasm'];
    final compile = module['rmlToRevWasm'];
    final freeCompile = module['freeRmlCompileWasm'];
    if (!callable(convert) ||
        !callable(free) ||
        !callable(compile) ||
        !callable(freeCompile)) {
      // flutter_runtime wasm module (rml not compiled in), or a
      // partial/mismatched module: fail closed, markupAvailable stays false.
      return;
    }
    _module = module;
    _revToRml = convert as js.JSFunction;
    _freeRmlExport = free as js.JSFunction;
    _rmlToRev = compile as js.JSFunction;
    _freeRmlCompile = freeCompile as js.JSFunction;
    _linked = true;
  }
}

/// Converts the bytes of a .rev file into the equivalent .rml markup
/// document, with every payload embedded. Returns null when the bytes are not
/// a readable .rev.
Uint8List? revToRml(Uint8List revBytes) {
  if (!_linked || revBytes.isEmpty) {
    return null;
  }
  final source = WasmBuffer.fromBytes(revBytes);
  try {
    final response = _revToRml.callAsFunction(
      _module,
      source.pointer,
      revBytes.length.toJS,
    ) as js.JSObject;
    final data = (response['data'] as js.JSNumber).toDartInt;
    final size = (response['size'] as js.JSNumber).toDartInt;
    if (data == 0 || size <= 0) {
      return null;
    }
    try {
      // A view over the wasm heap; copy it out before freeing.
      return Uint8List.fromList(RiveWasm.heap(data, size));
    } finally {
      _freeRmlExport.callAsFunction(_module, response);
    }
  } finally {
    source.dispose();
  }
}

/// Compiles a .rml markup document into the equivalent .rev bytes -- the
/// inverse of [revToRml]. Every payload the document needs must be embedded
/// in it: a `file=` reference has no directory to resolve against here and
/// compiles as an error.
RmlCompileResult rmlToRev(Uint8List rmlBytes) {
  if (!_linked) {
    return const RmlCompileResult.failure('0: markup is not available\n');
  }
  if (rmlBytes.isEmpty) {
    return const RmlCompileResult.failure('0: no markup to compile\n');
  }
  final source = WasmBuffer.fromBytes(rmlBytes);
  try {
    final response = _rmlToRev.callAsFunction(
      _module,
      source.pointer,
      rmlBytes.length.toJS,
    ) as js.JSObject;
    try {
      final data = (response['data'] as js.JSNumber).toDartInt;
      final size = (response['size'] as js.JSNumber).toDartInt;
      if (data != 0 && size > 0) {
        // A view over the wasm heap; copy it out before freeing.
        return RmlCompileResult.success(
          Uint8List.fromList(RiveWasm.heap(data, size)),
        );
      }
      final error = (response['error'] as js.JSNumber).toDartInt;
      final errorSize = (response['errorSize'] as js.JSNumber).toDartInt;
      if (error != 0 && errorSize > 0) {
        return RmlCompileResult.failure(
          utf8.decode(RiveWasm.heap(error, errorSize), allowMalformed: true),
        );
      }
      return const RmlCompileResult.failure('0: markup compile failed\n');
    } finally {
      _freeRmlCompile.callAsFunction(_module, response);
    }
  } finally {
    source.dispose();
  }
}
