import 'package:meta/meta.dart';

/// Bitmask constants for semantic state flags.
///
/// These map to platform accessibility properties.
/// Bits 0-7 are trait-gated: they are only meaningful when the
/// corresponding [SemanticTrait] is set on the node.
/// Bits 8-13 are non-trait states (binary, always applicable or role-implied).
///
/// ## Check state
///
/// Check state is a two-bit *field* rather than a flag, because a checkbox is
/// tri-state: 0 unchecked, 1 checked, 2 indeterminate. Read it with
/// [checkState], or with [effectiveChecked] / [effectiveMixed] when feeding a
/// platform accessibility API that wants two booleans.
@internal
abstract final class SemanticState {
  // ── Trait-gated states (only meaningful when trait is active) ───────────

  /// Node is currently expanded (requires Expandable trait).
  static const int expanded = 1 << 0;

  /// Node is currently selected (requires Selectable trait).
  static const int selected = 1 << 1;

  /// Offset of the two-bit check field (requires Checkable trait). Read it
  /// with [checkState] rather than masking a single bit.
  static const int checkStateOffset = 2;

  /// Mask of the two-bit check field within a state bitmask.
  static const int checkStateMask = 0x3 << checkStateOffset;

  /// Values the check field takes.
  static const int checkUnchecked = 0;
  static const int checkChecked = 1;
  static const int checkMixed = 2;

  /// Toggle is in the "on" position (requires Toggleable trait).
  static const int toggled = 1 << 4;

  /// Field is required (requires Requirable trait).
  static const int required = 1 << 5;

  /// Node is disabled (requires Enablable trait).
  static const int disabled = 1 << 6;

  /// Node currently has focus (requires Focusable trait).
  static const int focused = 1 << 7;

  // ── Non-trait states (binary, always applicable or role-implied) ────────

  /// Node is hidden from accessibility tree.
  static const int hidden = 1 << 8;

  /// Label changes trigger screen reader announcements.
  static const int liveRegion = 1 << 9;

  /// Text field is read-only.
  static const int readOnly = 1 << 10;

  /// Dialog traps focus within.
  static const int modal = 1 << 11;

  /// Text field content is hidden (password).
  static const int obscured = 1 << 12;

  /// Text field is multi-line.
  static const int multiline = 1 << 13;

  /// Check whether a specific flag is set in a bitmask.
  static bool has(int flags, int flag) => flags & flag != 0;

  /// Decodes the check field. The field is two bits so it can physically
  /// hold a fourth value; that value has no meaning and reads as
  /// [checkMixed] rather than an unnamed state.
  static int checkState(int flags) {
    final value = (flags & checkStateMask) >> checkStateOffset;
    return value >= checkMixed ? checkMixed : value;
  }

  /// Whether the node is checked, for a platform API that wants a boolean
  /// alongside [effectiveMixed]. Indeterminate is not checked.
  static bool effectiveChecked(int flags) =>
      checkState(flags) == checkChecked;

  /// Whether the node is indeterminate. Mutually exclusive with
  /// [effectiveChecked] for any given [flags] value.
  static bool effectiveMixed(int flags) => checkState(flags) == checkMixed;
}
