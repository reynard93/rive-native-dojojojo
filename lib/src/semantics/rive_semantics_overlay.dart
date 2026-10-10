import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';
import 'package:rive_native/rive_native.dart';
import 'package:rive_native/src/semantics/semantic_role.dart';
import 'package:rive_native/src/semantics/semantic_state.dart';
import 'package:rive_native/src/semantics/semantic_trait.dart';
import 'package:rive_native/src/semantics/semantic_tree_model.dart';

/// A widget that exposes a [SemanticTreeModel] as a Flutter semantics tree.
///
/// This widget does not paint anything — it exists purely to overlay
/// [SemanticsNode]s on top of a Rive artboard so that screen readers can
/// discover and announce the interactive elements within the animation.
///
/// The [fit], [alignment], and [layoutScaleFactor] parameters must match
/// the values used by the Rive render pass so that semantic rects align
/// with the visual positions of elements.

/// Callback invoked when a screen reader activates (taps) a semantic node.
/// The [SemanticNodeData] provides the node's artboard-space bounds so the
/// caller can simulate a pointer event at the correct location.
@internal
typedef SemanticTapCallback = void Function(SemanticNodeData data);

/// Callback invoked when a screen reader accessibility-focuses a semantic node.
@internal
typedef SemanticFocusCallback = void Function(int semanticNodeId);

/// Callback invoked when accessibility focus leaves a Rive semantic node.
/// [semanticNodeId] is the node that lost focus; consumers must ignore the
/// blur when another node has taken focus since (didLose/didGain arrive as
/// separate platform messages with no ordering guarantee).
@internal
typedef SemanticBlurCallback = void Function(int semanticNodeId);

/// Callback invoked when a screen reader fires an increase action on a semantic
/// node (e.g. slider step up).
@internal
typedef SemanticIncreaseCallback = void Function(SemanticNodeData data);

/// Callback invoked when a screen reader fires a decrease action on a semantic
/// node (e.g. slider step down).
@internal
typedef SemanticDecreaseCallback = void Function(SemanticNodeData data);

@internal
class RiveSemanticsOverlay extends LeafRenderObjectWidget {
  final SemanticTreeModel tree;

  /// Live source of the artboard's bounds, read during the semantics
  /// build. A getter (not a snapshot) so tree changes need not rebuild
  /// this widget to keep the artboard-to-widget transform fresh.
  final AABB Function() artboardBounds;
  final Fit fit;
  final Alignment alignment;
  final double layoutScaleFactor;
  final SemanticTapCallback? onSemanticTap;
  final SemanticFocusCallback? onSemanticFocus;
  final SemanticBlurCallback? onSemanticBlur;
  final SemanticIncreaseCallback? onSemanticIncrease;
  final SemanticDecreaseCallback? onSemanticDecrease;
  const RiveSemanticsOverlay({
    required this.tree,
    required this.artboardBounds,
    required this.fit,
    required this.alignment,
    required this.layoutScaleFactor,
    this.onSemanticTap,
    this.onSemanticFocus,
    this.onSemanticBlur,
    this.onSemanticIncrease,
    this.onSemanticDecrease,
    super.key,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RiveSemanticsRenderBox(
      tree: tree,
      artboardBounds: artboardBounds,
      fit: fit,
      alignment: alignment,
      layoutScaleFactor: layoutScaleFactor,
      onSemanticTap: onSemanticTap,
      onSemanticFocus: onSemanticFocus,
      onSemanticBlur: onSemanticBlur,
      onSemanticIncrease: onSemanticIncrease,
      onSemanticDecrease: onSemanticDecrease,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RiveSemanticsRenderBox renderObject,
  ) {
    renderObject
      ..tree = tree
      ..artboardBounds = artboardBounds
      ..fit = fit
      ..alignment = alignment
      ..layoutScaleFactor = layoutScaleFactor
      ..onSemanticTap = onSemanticTap
      ..onSemanticFocus = onSemanticFocus
      ..onSemanticBlur = onSemanticBlur
      ..onSemanticIncrease = onSemanticIncrease
      ..onSemanticDecrease = onSemanticDecrease;
  }
}

class RiveSemanticsRenderBox extends RenderBox {
  RiveSemanticsRenderBox({
    required SemanticTreeModel tree,
    required AABB Function() artboardBounds,
    required Fit fit,
    required Alignment alignment,
    required double layoutScaleFactor,
    SemanticTapCallback? onSemanticTap,
    SemanticFocusCallback? onSemanticFocus,
    SemanticBlurCallback? onSemanticBlur,
    SemanticIncreaseCallback? onSemanticIncrease,
    SemanticDecreaseCallback? onSemanticDecrease,
  })  : _tree = tree,
        _artboardBounds = artboardBounds,
        _fit = fit,
        _alignment = alignment,
        _layoutScaleFactor = layoutScaleFactor,
        _onSemanticTap = onSemanticTap,
        _onSemanticFocus = onSemanticFocus,
        _onSemanticBlur = onSemanticBlur,
        _onSemanticIncrease = onSemanticIncrease,
        _onSemanticDecrease = onSemanticDecrease;

  // ── Properties ──────────────────────────────────────────────────────────

  SemanticTreeModel _tree;
  int _lastAppliedVersion = -1;

  SemanticTreeModel get tree => _tree;
  set tree(SemanticTreeModel value) {
    if (_tree == value) return;
    if (attached) _tree.removeListener(_onTreeChanged);
    _tree = value;
    _lastAppliedVersion = -1;
    if (attached) _tree.addListener(_onTreeChanged);
    markNeedsSemanticsUpdate();
  }

  AABB Function() _artboardBounds;
  set artboardBounds(AABB Function() value) {
    // Plain assignment: bounds are read live during the semantics build,
    // so a new (equivalent) closure needs no invalidation. Freshness
    // comes from tree changes and relayout, which already mark
    // semantics dirty.
    _artboardBounds = value;
  }

  Fit _fit;
  set fit(Fit value) {
    if (_fit == value) return;
    _fit = value;
    markNeedsSemanticsUpdate();
  }

  Alignment _alignment;
  set alignment(Alignment value) {
    if (_alignment == value) return;
    _alignment = value;
    markNeedsSemanticsUpdate();
  }

  double _layoutScaleFactor;
  set layoutScaleFactor(double value) {
    if (_layoutScaleFactor == value) return;
    _layoutScaleFactor = value;
    markNeedsSemanticsUpdate();
  }

  SemanticTapCallback? _onSemanticTap;
  set onSemanticTap(SemanticTapCallback? value) {
    _onSemanticTap = value;
  }

  SemanticFocusCallback? _onSemanticFocus;
  set onSemanticFocus(SemanticFocusCallback? value) {
    _onSemanticFocus = value;
  }

  SemanticBlurCallback? _onSemanticBlur;
  set onSemanticBlur(SemanticBlurCallback? value) {
    _onSemanticBlur = value;
  }

  SemanticIncreaseCallback? _onSemanticIncrease;
  SemanticDecreaseCallback? _onSemanticDecrease;

  set onSemanticIncrease(SemanticIncreaseCallback? value) {
    _onSemanticIncrease = value;
  }

  set onSemanticDecrease(SemanticDecreaseCallback? value) {
    _onSemanticDecrease = value;
  }

  // ── SemanticsNode cache ─────────────────────────────────────────────────

  final Map<int, SemanticsNode> _cachedNodes = {};

  // One intermediate SemanticsNode carries the artboard→widget transform on
  // its `transform` field so Flutter's semantic compositor applies it once,
  // uniformly, to every descendant. All semantic children are expressed in
  // artboard-root coordinates (the space C++ emits) — no per-node AABB
  // multiply required.
  SemanticsNode? _transformContainer;

  // ── Lifecycle ───────────────────────────────────────────────────────────

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _tree.addListener(_onTreeChanged);
  }

  @override
  void detach() {
    _tree.removeListener(_onTreeChanged);
    super.detach();
  }

  void _onTreeChanged() {
    if (_tree.version != _lastAppliedVersion) {
      markNeedsSemanticsUpdate();
    }
  }

  // ── Layout (size-only, no painting) ─────────────────────────────────────

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void paint(PaintingContext context, Offset offset) {
    // No-op: this render box exists only for semantics.
  }

  @override
  bool hitTestSelf(Offset position) => false;

  // ── Semantics ───────────────────────────────────────────────────────────

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config.isSemanticBoundary = true;
    config.explicitChildNodes = true;
  }

  @override
  void assembleSemanticsNode(
    SemanticsNode node,
    SemanticsConfiguration config,
    Iterable<SemanticsNode> children,
  ) {
    _lastAppliedVersion = _tree.version;

    final activeIds = <int>{};
    final rootChildren = <SemanticsNode>[];
    var sortIndex = 0.0;
    double takeSortIndex() => sortIndex++;

    // Children are built in artboard-root coordinates. The shared
    // transform is attached to _transformContainer below, so Flutter's
    // compositor multiplies through to descendants without us touching
    // each rect.
    for (final rootId in _tree.roots) {
      rootChildren
          .addAll(_buildSemanticsSubtree(rootId, activeIds, takeSortIndex));
    }

    // Dispose nodes no longer in the tree.
    final staleIds =
        _cachedNodes.keys.where((id) => !activeIds.contains(id)).toList();
    for (final id in staleIds) {
      _cachedNodes.remove(id);
    }

    final artboardBounds = _artboardBounds();
    final container = _transformContainer ??= SemanticsNode();
    container
      ..rect = Rect.fromLTRB(
        artboardBounds.minX,
        artboardBounds.minY,
        artboardBounds.maxX,
        artboardBounds.maxY,
      )
      ..transform = _mat2DToMatrix4(_computeViewTransform(artboardBounds))
      ..updateWith(
        config: SemanticsConfiguration(),
        childrenInInversePaintOrder: rootChildren,
      );

    node.updateWith(
      config: config,
      childrenInInversePaintOrder: [container],
    );
  }

  /// Builds the semantics for [id] and returns the nodes to attach to the
  /// parent's child list. Normally that is the node itself; for a node
  /// with degenerate (zero-area) bounds it is the node's built children,
  /// promoted in its place. [takeSortIndex] hands out sibling sort
  /// indices in emission order so promoted children slot into the
  /// parent's ordering.
  List<SemanticsNode> _buildSemanticsSubtree(
    int id,
    Set<int> activeIds,
    double Function() takeSortIndex,
  ) {
    final data = _tree.nodeById(id);
    if (data == null) return const [];

    // Rect is in artboard-root space. Flutter asserts that non-root
    // SemanticsNodes must not have an empty rect, so a node with
    // degenerate (zero-area or non-finite) bounds cannot be emitted - but
    // its children may have perfectly valid bounds. Promote them into the
    // parent's child list instead of pruning the subtree, and let the
    // Hidden state remain the mechanism for intentional hiding. Matches
    // the Android runtime's projection.
    //
    // Skipping the degenerate node is mandatory (Flutter asserts a
    // non-root rect is finite and non-empty; a NaN transform reaches us
    // through core's point fallback). Promoting the children rather than
    // dropping them is defensive: core's semanticBounds already unions a
    // container's whole descendant subtree (a drawable falls back to that
    // union at zero size), so a parent that arrives degenerate has no
    // bounded child to promote in the common case - promote and drop are
    // equivalent there. They differ only when a child's bounds bypass the
    // parent's union (e.g. a nested-artboard boundary node); promote so
    // that child stays reachable if it arises. Covered by
    // semantic_overlay_promotion_test.dart, not an authored file.
    final rect = Rect.fromLTRB(data.minX, data.minY, data.maxX, data.maxY);
    // isEmpty alone misses NaN (all NaN comparisons are false), and
    // SemanticsNode.rect must be finite.
    if (rect.isEmpty || !rect.isFinite) {
      final promoted = <SemanticsNode>[];
      for (final childId in data.children) {
        promoted
            .addAll(_buildSemanticsSubtree(childId, activeIds, takeSortIndex));
      }
      return promoted;
    }

    activeIds.add(id);

    final semNode = _cachedNodes.putIfAbsent(id, SemanticsNode.new);
    semNode.rect = rect;

    // Build config for this node.
    final semConfig = SemanticsConfiguration();
    // Explicit sort key ensures the platform accessibility layer uses
    // our ordering even when DOM element recycling on web reorders
    // existing elements among newly inserted ones.
    semConfig.sortKey = OrdinalSortKey(takeSortIndex());
    _applySemantics(semConfig, data);

    // Recurse into children.
    final childSemNodes = <SemanticsNode>[];
    var childSortIndex = 0.0;
    double takeChildSortIndex() => childSortIndex++;
    for (final childId in data.children) {
      childSemNodes
          .addAll(_buildSemanticsSubtree(childId, activeIds, takeChildSortIndex));
    }

    semNode.updateWith(
      config: semConfig,
      childrenInInversePaintOrder: childSemNodes,
    );
    return [semNode];
  }

  // ── Coordinate mapping ──────────────────────────────────────────────────

  /// Compute the artboard→widget coordinate transform. This uses the same
  /// [Renderer.computeAlignment] logic as the Rive render pass.
  Mat2D _computeViewTransform(AABB artboardBounds) {
    return Renderer.computeAlignment(
      _fit,
      _alignment,
      AABB.fromValues(0, 0, size.width, size.height),
      artboardBounds,
      _layoutScaleFactor,
    );
  }

  // Embeds a Mat2D (2D affine) in a 4x4 column-major Matrix4 as expected by
  // Flutter's SemanticsNode.transform:
  //   | a  c  0  tx |
  //   | b  d  0  ty |
  //   | 0  0  1  0  |
  //   | 0  0  0  1  |
  static Matrix4 _mat2DToMatrix4(Mat2D m) {
    return Matrix4(
      m[0], m[1], 0, 0, //
      m[2], m[3], 0, 0, //
      0, 0, 1, 0, //
      m[4], m[5], 0, 1,
    );
  }

  // ── Role mapping ────────────────────────────────────────────────────────

  void _applySemantics(SemanticsConfiguration config, SemanticNodeData data) {
    final flags = data.stateFlags;
    final traits = data.traitFlags;
    config.textDirection = TextDirection.ltr;

    if (data.label.isNotEmpty) {
      config.label = data.label;
    }
    if (data.value.isNotEmpty) {
      config.value = data.value;
    }
    if (data.hint.isNotEmpty) {
      config.hint = data.hint;
    }

    // ── Trait-gated tristate properties ───────────────────────────────────
    // When a trait is set, the corresponding state produces a true/false
    // value. When the trait is absent, the property is not set on the
    // config at all (null / not applicable).

    if (SemanticTrait.has(traits, SemanticTrait.enablable)) {
      config.isEnabled = !SemanticState.has(flags, SemanticState.disabled);
    }

    if (SemanticTrait.has(traits, SemanticTrait.expandable)) {
      config.isExpanded = SemanticState.has(flags, SemanticState.expanded);
    }

    if (SemanticTrait.has(traits, SemanticTrait.selectable)) {
      config.isSelected = SemanticState.has(flags, SemanticState.selected);
    }

    if (SemanticTrait.has(traits, SemanticTrait.checkable)) {
      config.isChecked = SemanticState.effectiveChecked(flags);
      if (SemanticState.effectiveMixed(flags)) {
        config.isCheckStateMixed = true;
      }
    }

    if (SemanticTrait.has(traits, SemanticTrait.toggleable)) {
      config.isToggled = SemanticState.has(flags, SemanticState.toggled);
    }

    if (SemanticTrait.has(traits, SemanticTrait.requirable)) {
      config.isRequired = SemanticState.has(flags, SemanticState.required);
    }

    // ── Focusable trait ─────────────────────────────────────────────────
    // The C++ runtime auto-sets this trait when a sibling FocusData exists.
    // When the trait is set, we wire up focus callbacks and map the Focused
    // state to isFocused.
    if (SemanticTrait.has(traits, SemanticTrait.focusable)) {
      config.isFocusable = true;
      if (SemanticState.has(flags, SemanticState.focused)) {
        config.isFocused = true;
      }
      if (_onSemanticFocus != null) {
        config.onFocus = () => _onSemanticFocus?.call(data.id);
        config.onDidGainAccessibilityFocus =
            () => _onSemanticFocus?.call(data.id);
      }
      if (_onSemanticBlur != null) {
        config.onDidLoseAccessibilityFocus =
            () => _onSemanticBlur?.call(data.id);
      }
    }

    // ── Non-trait state bits (binary, always applicable) ─────────────────

    if (SemanticState.has(flags, SemanticState.hidden)) {
      config.isHidden = true;
    }
    if (SemanticState.has(flags, SemanticState.liveRegion)) {
      config.liveRegion = true;
    }

    // Tap handler for interactive roles — simulates pointer down/up at the
    // center of the node's artboard-space bounds.
    void tapHandler() => _onSemanticTap?.call(data);

    // ── Role-specific mapping ────────────────────────────────────────────
    switch (data.role) {
      case SemanticRole.button:
        config.isButton = true;
        config.onTap = tapHandler;
      case SemanticRole.switchControl:
        config.isButton = true;
        config.onTap = tapHandler;
      case SemanticRole.checkbox:
        config.isButton = true;
        config.onTap = tapHandler;
      case SemanticRole.tab:
        config.role = SemanticsRole.tab;
        config.onTap = tapHandler;
      case SemanticRole.listItem:
        config.role = SemanticsRole.listItem;
      case SemanticRole.slider:
        config.isSlider = true;
        config.onIncrease = () {
          _onSemanticIncrease?.call(data);
        };
        config.onDecrease = () {
          _onSemanticDecrease?.call(data);
        };
        config.value = data.value;
        config.increasedValue = data.value;
        config.decreasedValue = data.value;
      case SemanticRole.textField:
        config.isTextField = true;
        if (SemanticState.has(flags, SemanticState.readOnly)) {
          config.isReadOnly = true;
        }
        if (SemanticState.has(flags, SemanticState.obscured)) {
          config.isObscured = true;
        }
        if (SemanticState.has(flags, SemanticState.multiline)) {
          config.isMultiline = true;
        }
      case SemanticRole.image:
        config.isImage = true;
      case SemanticRole.link:
        config.isLink = true;
        config.onTap = tapHandler;
      case SemanticRole.list:
        config.role = SemanticsRole.list;
        config.explicitChildNodes = true;
      case SemanticRole.tabList:
        config.role = SemanticsRole.tabBar;
        config.explicitChildNodes = true;
      case SemanticRole.group:
        config.explicitChildNodes = true;
      case SemanticRole.dialog:
        config.role = SemanticsRole.dialog;
        config.explicitChildNodes = true;
        if (SemanticState.has(flags, SemanticState.modal)) {
          config.scopesRoute = true;
          config.namesRoute = true;
        }
      case SemanticRole.alertDialog:
        config.role = SemanticsRole.alertDialog;
        config.explicitChildNodes = true;
        if (SemanticState.has(flags, SemanticState.modal)) {
          config.scopesRoute = true;
          config.namesRoute = true;
        }
      case SemanticRole.radioGroup:
        config.role = SemanticsRole.radioGroup;
        config.explicitChildNodes = true;
      case SemanticRole.radioButton:
        config.isButton = true;
        config.isInMutuallyExclusiveGroup = true;
        config.onTap = tapHandler;
      case SemanticRole.text:
        if (data.headingLevel > 0) {
          config.isHeader = true;
          config.headingLevel = data.headingLevel;
        }
      case SemanticRole.none:
        break;
    }
  }

  // ── Cleanup ─────────────────────────────────────────────────────────────

  // Called when the semantics owner is torn down (screen reader
  // disconnects, or the last SemanticsHandle is released). Every cached
  // SemanticsNode - including the transform container - belongs to that
  // owner; reusing one under the next owner trips framework asserts
  // ('owner!._nodes.containsKey(id)'). Drop them all so re-enabling
  // assembles fresh nodes.
  @override
  void clearSemantics() {
    super.clearSemantics();
    _cachedNodes.clear();
    _transformContainer = null;
    _lastAppliedVersion = -1;
  }

  @override
  void dispose() {
    _tree.removeListener(_onTreeChanged);
    _cachedNodes.clear();
    super.dispose();
  }
}
