import 'dart:math' as math;
import 'dart:ui';

import 'package:rive_native/math.dart';

/// Values chosen by a selection context from its shared style resource.
/// Every target receives this appearance, including across nested instances.
class SelectionAppearance {
  final int highlightColor;
  final double cornerRadius;
  const SelectionAppearance({
    this.highlightColor = 0x663B82F6,
    this.cornerRadius = 0,
  });

  @override
  bool operator ==(Object other) =>
      other is SelectionAppearance &&
      highlightColor == other.highlightColor &&
      cornerRadius == other.cornerRadius;
  @override
  int get hashCode => Object.hash(highlightColor, cornerRadius);
}

/// A character endpoint and its squared distance from the pointer, measured in
/// root artboard coordinates. Offsets throughout this API are Unicode code
/// points, never UTF-16 code units.
class TextSelectionHit {
  final int offset;
  final double distanceSquared;
  const TextSelectionHit(this.offset, this.distanceSquared);
}

/// A regular Text instance participating in a shared selection. Implementations
/// use the same layout and clipping as their renderer. Instance identity must
/// remain stable across frames, including repeated nested artboards.
abstract interface class TextSelectionTarget {
  SelectionAppearance get selectionAppearance;
  String get selectionText;
  bool get selectionEnabled;
  AABB get selectionBounds;
  TextSelectionHit? selectionHit(Vec2D rootPosition, {bool nearest = false});
  void selectText(int start, int end, {SelectionAppearance? appearance});
}

/// Coordinates one read-only range across editor and native Text instances.
/// The host supplies targets in reading order and arbitrates pointer-down
/// against its other interactive objects. Once captured, moves may cross gaps.
class TextSelectionController {
  List<TextSelectionTarget> _targets = [];
  List<String> _sources = [];
  (int, int)? _anchor;
  (int, int)? _extent;
  int? _pointer;
  SelectionAppearance? _appearanceOverride;
  SelectionAppearance _appearance = const SelectionAppearance();

  SelectionAppearance get appearance => _appearance;
  set appearance(SelectionAppearance value) {
    _appearanceOverride = value;
    _useAppearance(value);
  }

  void _useAppearance(SelectionAppearance value) {
    if (_appearance == value) return;
    _appearance = value;
    if (validate()) _apply();
  }

  bool get isDragging => _pointer != null;
  bool get isActive => _anchor != null;
  bool get hasSelection => validate() && _anchor != _extent;

  void updateTargets(Iterable<TextSelectionTarget> targets) {
    final next = targets.where((t) => t.selectionEnabled).toList();
    // Freeze reading order during a selection; transforms may animate.
    if (next.length != _targets.length ||
        next.any((target) => !_targets.contains(target))) {
      clear();
      _targets = next;
    } else if (!isActive) {
      _targets = next;
    }
    validate();
    _useAppearance(
      _appearanceOverride ??
          (_targets.isEmpty
              ? const SelectionAppearance()
              : _targets.first.selectionAppearance),
    );
  }

  /// Clear the complete range when a participant changes or disappears.
  bool validate() {
    if (_anchor == null) return false;
    for (var i = 0; i < _targets.length; i++) {
      if (!_targets[i].selectionEnabled ||
          _targets[i].selectionText != _sources[i]) {
        clear();
        return false;
      }
    }
    return true;
  }

  TextSelectionTarget? hitTest(Vec2D point) {
    for (final target in _targets.reversed) {
      if (target.selectionHit(point) != null) return target;
    }
    return null;
  }

  bool pointerDown(
    TextSelectionTarget target,
    Vec2D point, {
    int pointerId = 0,
    bool extend = false,
  }) {
    if (isDragging) return false;
    final hit = target.selectionHit(point);
    final index = _targets.indexOf(target);
    if (hit == null || index < 0) return false;
    final endpoint = (index, hit.offset);
    if (!extend || !validate()) {
      clear();
      _anchor = endpoint;
      _sources = _targets.map((t) => t.selectionText).toList();
    }
    _extent = endpoint;
    _pointer = pointerId;
    _apply();
    return true;
  }

  bool pointerMove(Vec2D point, {int pointerId = 0}) {
    if (_pointer != pointerId || !validate()) return false;
    var distance = double.infinity;
    for (var i = 0; i < _targets.length; i++) {
      final hit = _targets[i].selectionHit(point, nearest: true);
      if (hit != null && hit.distanceSquared < distance) {
        distance = hit.distanceSquared;
        _extent = (i, hit.offset);
      }
    }
    _apply();
    return true;
  }

  bool pointerUp(Vec2D point, {int pointerId = 0}) {
    if (!pointerMove(point, pointerId: pointerId)) return false;
    _pointer = null;
    return true;
  }

  void cancel({int pointerId = 0}) {
    if (_pointer == pointerId) clear();
  }

  void clear() {
    for (final target in _targets) {
      target.selectText(0, 0);
    }
    _anchor = _extent = null;
    _pointer = null;
    _sources = [];
  }

  void selectAll() {
    if (!validate() || _targets.isEmpty) return;
    _anchor = (0, 0);
    _extent = (_targets.length - 1, _sources.last.runes.length);
    _apply();
  }

  ((int, int), (int, int)) get _range {
    final a = _anchor!, b = _extent!;
    return a.$1 < b.$1 || (a.$1 == b.$1 && a.$2 <= b.$2) ? (a, b) : (b, a);
  }

  void _apply() {
    final (start, end) = _range;
    for (var i = 0; i < _targets.length; i++) {
      _targets[i].selectText(
        i == start.$1 ? start.$2 : 0,
        i < start.$1 || i > end.$1
            ? 0
            : i == end.$1
            ? end.$2
            : _sources[i].runes.length,
        appearance: _appearance,
      );
    }
  }

  String get selectedText {
    if (!hasSelection) return '';
    final (start, end) = _range;
    return [
      for (var i = start.$1; i <= end.$1; i++)
        String.fromCharCodes(
          _sources[i].runes
              .skip(i == start.$1 ? start.$2 : 0)
              .take(
                (i == end.$1 ? end.$2 : _sources[i].runes.length) -
                    (i == start.$1 ? start.$2 : 0),
              ),
        ),
    ].join('\n');
  }
}

/// One displayed glyph cluster, captured from the regular Text render layout.
class TextSelectionGlyph {
  final int start, count;
  final Rect bounds;
  final bool rtl;
  const TextSelectionGlyph(this.start, this.count, this.bounds, this.rtl);

  Rect? selectedRect(int first, int last) {
    if (count <= 0 || last <= start || first >= start + count) return null;
    var a = (first - start).clamp(0, count) / count;
    var b = (last - start).clamp(0, count) / count;
    if (rtl) {
      a = 1 - a;
      b = 1 - b;
    }
    return Rect.fromLTRB(
      bounds.left + bounds.width * math.min(a, b),
      bounds.top,
      bounds.left + bounds.width * math.max(a, b),
      bounds.bottom,
    );
  }
}

/// Maps the existing displayed glyphs to endpoints without reshaping text.
TextSelectionHit? hitTextSelectionGlyphs(
  Iterable<TextSelectionGlyph> glyphs,
  Mat2D transform,
  Vec2D point, {
  bool nearest = false,
}) {
  if (!point.x.isFinite || !point.y.isFinite) return null;
  final inverse = Mat2D();
  if (!Mat2D.invert(inverse, transform)) return null;
  final local = inverse.mapXY(point.x, point.y);
  if (!local.x.isFinite || !local.y.isFinite) return null;
  TextSelectionHit? result;
  for (final glyph in glyphs) {
    final rect = glyph.bounds;
    if (rect.isEmpty || glyph.count <= 0) continue;
    final x = local.x.clamp(rect.left, rect.right);
    final y = local.y.clamp(rect.top, rect.bottom);
    if (!nearest && (x != local.x || y != local.y)) continue;
    final root = transform.mapXY(x, y);
    final dx = root.x - point.x, dy = root.y - point.y;
    final distance = dx * dx + dy * dy;
    if (result == null || distance < result.distanceSquared) {
      var fraction = (x - rect.left) / rect.width;
      if (glyph.rtl) fraction = 1 - fraction;
      result = TextSelectionHit(
        glyph.start + (fraction * glyph.count).round(),
        distance,
      );
    }
  }
  return result;
}
