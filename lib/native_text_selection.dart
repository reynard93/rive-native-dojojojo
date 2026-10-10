import 'package:rive_native/rive_native.dart';
import 'package:rive_native/text_selection.dart';

import 'src/ffi/text_selection_ffi.dart'
    if (dart.library.js_interop) 'src/web/text_selection_web.dart';

/// A native scene's contribution to a selection shared with its host. Dispose
/// before releasing the host scene. Tokens are stable across refreshes and are
/// invalidated when their actual nested Text instance disappears.
abstract class NativeTextSelectionRegion {
  static NativeTextSelectionRegion make(Artboard artboard) =>
      makeTextSelectionRegion(artboard);

  final Map<int, _NativeTarget> _targets = {};
  bool disposed = false;
  SelectionAppearance appearance = const SelectionAppearance();

  Iterable<TextSelectionTarget> get targets {
    if (disposed) return const [];
    appearance = readAppearance();
    final ids = refreshIds();
    final removed = _targets.keys.where((id) => !ids.contains(id)).toList();
    for (final id in removed) {
      _targets.remove(id)!.selectionEnabled = false;
    }
    for (final id in ids) {
      final target = _targets.putIfAbsent(id, () => _NativeTarget(this, id));
      final bounds = readBounds(id);
      target.selectionEnabled = bounds != null;
      if (bounds != null) target.selectionBounds = bounds;
      target.selectionText = readSource(id);
    }
    return ids.map((id) => _targets[id]!);
  }

  List<int> refreshIds();
  SelectionAppearance readAppearance();
  AABB? readBounds(int id);
  String readSource(int id);
  TextSelectionHit? hit(int id, Vec2D point, bool nearest);
  void range(int id, int start, int end, SelectionAppearance appearance);

  void dispose() {
    disposed = true;
    for (final target in _targets.values) {
      target.selectionEnabled = false;
    }
    _targets.clear();
  }
}

class _NativeTarget implements TextSelectionTarget {
  final NativeTextSelectionRegion region;
  final int id;
  @override
  String selectionText = '';
  @override
  bool selectionEnabled = false;
  @override
  AABB selectionBounds = AABB();
  _NativeTarget(this.region, this.id);

  @override
  SelectionAppearance get selectionAppearance => region.appearance;

  @override
  TextSelectionHit? selectionHit(Vec2D point, {bool nearest = false}) =>
      selectionEnabled && !region.disposed
      ? region.hit(id, point, nearest)
      : null;

  @override
  void selectText(int start, int end, {SelectionAppearance? appearance}) {
    if (!region.disposed)
      region.range(id, start, end, appearance ?? selectionAppearance);
  }
}
