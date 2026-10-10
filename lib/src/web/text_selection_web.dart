import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:rive_native/native_text_selection.dart';
import 'package:rive_native/rive_native.dart';
import 'package:rive_native/src/rive_native_web.dart';
import 'package:rive_native/text_selection.dart';

import 'rive_web.dart';

JSFunction _fn(String name) => RiveWasm.module!['_$name'] as JSFunction;
int _int(JSAny? value) => (value as JSNumber).toDartInt;

NativeTextSelectionRegion makeTextSelectionRegion(Artboard artboard) =>
    _WebRegion(
      _int(
        _fn(
          'textSelectionCreate',
        ).callAsFunction(null, (artboard as WebRiveArtboard).pointer.toJS),
      ),
    );

class _WebRegion extends NativeTextSelectionRegion {
  final int pointer;
  static final _finalizer = Finalizer<int>(
    (pointer) => _fn('textSelectionDelete').callAsFunction(null, pointer.toJS),
  );
  _WebRegion(this.pointer) {
    _finalizer.attach(this, pointer, detach: this);
  }

  @override
  List<int> refreshIds() {
    final count = _int(
      _fn('textSelectionRefresh').callAsFunction(null, pointer.toJS),
    );
    return List.generate(
      count,
      (index) => _int(
        _fn(
          'textSelectionTargetId',
        ).callAsFunction(null, pointer.toJS, index.toJS),
      ),
    );
  }

  @override
  SelectionAppearance readAppearance() => SelectionAppearance(
    highlightColor: _int(
      _fn('textSelectionDefaultColor').callAsFunction(null, pointer.toJS),
    ),
    cornerRadius:
        (_fn('textSelectionDefaultRadius').callAsFunction(null, pointer.toJS)
                as JSNumber)
            .toDartDouble,
  );

  @override
  AABB? readBounds(int id) {
    final out = _int(_fn('malloc').callAsFunction(null, 16.toJS));
    try {
      if (_int(
            _fn(
              'textSelectionTargetBounds',
            ).callAsFunction(null, pointer.toJS, id.toJS, out.toJS),
          ) ==
          0)
        return null;
      final values = RiveWasm.heapViewF32(out, 4);
      return AABB.fromValues(values[0], values[1], values[2], values[3]);
    } finally {
      _fn('free').callAsFunction(null, out.toJS);
    }
  }

  @override
  String readSource(int id) => RiveWasm.toDartString(
    _int(
      _fn(
        'textSelectionTargetSource',
      ).callAsFunction(null, pointer.toJS, id.toJS),
    ),
    deleteNative: true,
  );

  @override
  TextSelectionHit? hit(int id, Vec2D point, bool nearest) {
    final out = _int(_fn('malloc').callAsFunction(null, 4.toJS));
    try {
      final offset = _int(
        _fn('textSelectionTargetHit').callAsFunctionEx(
          null,
          pointer.toJS,
          id.toJS,
          point.x.toJS,
          point.y.toJS,
          (nearest ? 1 : 0).toJS,
          out.toJS,
        ),
      );
      return offset < 0
          ? null
          : TextSelectionHit(offset, RiveWasm.heapViewF32(out, 1)[0]);
    } finally {
      _fn('free').callAsFunction(null, out.toJS);
    }
  }

  @override
  void range(int id, int start, int end, SelectionAppearance appearance) =>
      _fn('textSelectionTargetRange').callAsFunctionEx(
        null,
        pointer.toJS,
        id.toJS,
        start.toJS,
        end.toJS,
        appearance.highlightColor.toJS,
        appearance.cornerRadius.toJS,
      );

  @override
  void dispose() {
    if (disposed) return;
    super.dispose();
    _fn('textSelectionDelete').callAsFunction(null, pointer.toJS);
    _finalizer.detach(this);
  }
}
