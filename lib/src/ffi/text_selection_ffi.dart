import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:rive_native/native_text_selection.dart';
import 'package:rive_native/rive_native.dart';
import 'package:rive_native/text_selection.dart';

import 'rive_ffi.dart';

final _create = nativeLib
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)
    >('textSelectionCreate');
final _deletePtr = nativeLib
    .lookup<NativeFunction<Void Function(Pointer<Void>)>>(
      'textSelectionDelete',
    );
final _delete = _deletePtr.asFunction<void Function(Pointer<Void>)>();
final _refresh = nativeLib
    .lookupFunction<
      Uint32 Function(Pointer<Void>),
      int Function(Pointer<Void>)
    >('textSelectionRefresh');
final _id = nativeLib
    .lookupFunction<
      Uint32 Function(Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int)
    >('textSelectionTargetId');
final _bounds = nativeLib
    .lookupFunction<
      Bool Function(Pointer<Void>, Uint32, Pointer<Float>),
      bool Function(Pointer<Void>, int, Pointer<Float>)
    >('textSelectionTargetBounds');
final _source = nativeLib
    .lookupFunction<
      Pointer<Utf8> Function(Pointer<Void>, Uint32),
      Pointer<Utf8> Function(Pointer<Void>, int)
    >('textSelectionTargetSource');
final _hit = nativeLib
    .lookupFunction<
      Int32 Function(Pointer<Void>, Uint32, Float, Float, Bool, Pointer<Float>),
      int Function(Pointer<Void>, int, double, double, bool, Pointer<Float>)
    >('textSelectionTargetHit');
final _range = nativeLib
    .lookupFunction<
      Void Function(Pointer<Void>, Uint32, Uint32, Uint32, Uint32, Float),
      void Function(Pointer<Void>, int, int, int, int, double)
    >('textSelectionTargetRange');
final _color = nativeLib
    .lookupFunction<
      Uint32 Function(Pointer<Void>),
      int Function(Pointer<Void>)
    >('textSelectionDefaultColor');
final _radius = nativeLib
    .lookupFunction<
      Float Function(Pointer<Void>),
      double Function(Pointer<Void>)
    >('textSelectionDefaultRadius');

NativeTextSelectionRegion makeTextSelectionRegion(Artboard artboard) =>
    _FFIRegion(_create((artboard as FFIRiveArtboard).pointer));

class _FFIRegion extends NativeTextSelectionRegion implements Finalizable {
  final Pointer<Void> pointer;
  static final _finalizer = NativeFinalizer(_deletePtr);
  _FFIRegion(this.pointer) {
    _finalizer.attach(this, pointer, detach: this);
  }

  @override
  List<int> refreshIds() {
    final count = _refresh(pointer);
    return List.generate(count, (index) => _id(pointer, index));
  }

  @override
  SelectionAppearance readAppearance() => SelectionAppearance(
    highlightColor: _color(pointer),
    cornerRadius: _radius(pointer),
  );

  @override
  AABB? readBounds(int id) {
    final out = calloc<Float>(4);
    try {
      return _bounds(pointer, id, out)
          ? AABB.fromValues(out[0], out[1], out[2], out[3])
          : null;
    } finally {
      calloc.free(out);
    }
  }

  @override
  String readSource(int id) =>
      safeString(_source(pointer, id), deleteNative: true);

  @override
  TextSelectionHit? hit(int id, Vec2D point, bool nearest) {
    final out = calloc<Float>();
    try {
      final offset = _hit(pointer, id, point.x, point.y, nearest, out);
      return offset < 0 ? null : TextSelectionHit(offset, out.value);
    } finally {
      calloc.free(out);
    }
  }

  @override
  void range(int id, int start, int end, SelectionAppearance appearance) =>
      _range(
        pointer,
        id,
        start,
        end,
        appearance.highlightColor,
        appearance.cornerRadius,
      );

  @override
  void dispose() {
    if (disposed) return;
    super.dispose();
    _delete(pointer);
    _finalizer.detach(this);
  }
}
