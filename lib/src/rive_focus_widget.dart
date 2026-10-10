import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:rive_native/focus.dart' as focus;
import 'package:rive_native/rive_native.dart' as rive;

/// A painter whose state machine can take keyboard focus.
base mixin RiveKeyboardFocusMixin on rive.ProceduralPainter {
  /// The state machine that keyboard focus and key events are routed to.
  rive.StateMachine? get stateMachine;
}

/// Connects Flutter keyboard focus to the focus tree of a Rive state machine.
///
/// The widget is a Flutter focus target only while the content has focusable
/// nodes (`StateMachine.hasFocusNodes`). A graphic without any is not a tab
/// stop and costs nothing. Once focused:
///
/// - Tab and Shift+Tab traverse Rive's focus tree. When traversal runs off
///   the end, Rive drops focus and the event is released so Flutter moves
///   focus on to the next widget. A scope authored with edgeBehavior `stop`
///   keeps focus and the key.
/// - Arrow keys move focus directionally between nodes once one is focused;
///   an arrow with no target in that direction is released to Flutter.
/// - Other keys go to the focused node (`keyInput`), and typed characters to
///   `textInput`, so a focused TextInput can be edited. A key an authored
///   keyboard listener claims is reported to Flutter as handled, so the app
///   around the graphic does not also act on it.
/// - Tabbing into the widget focuses the first (or, with Shift, the last)
///   node. A pointer press focuses the widget without moving Rive focus; the
///   next Tab enters the tree. A press that Rive itself turns into focus (a
///   TextInput, or a listener with an authored focus action) keeps that
///   node; pointer focus is otherwise not automatic.
/// - When Flutter focus leaves the widget, Rive focus is cleared.
///
/// ```dart
/// RiveFocusWidget(
///   painter: painter,
///   child: RiveArtboardWidget(artboard: artboard, painter: painter),
/// )
/// ```
class RiveFocusWidget extends StatefulWidget {
  /// The painter whose state machine takes focus. [rive.StateMachinePainter]
  /// and `RiveWidgetController` both qualify.
  final RiveKeyboardFocusMixin painter;

  final Widget child;

  const RiveFocusWidget({
    required this.painter,
    required this.child,
    super.key,
  });

  /// How many times any instance re-read `hasFocusNodes`; lets tests check
  /// that a settled graphic stops scheduling that work.
  @visibleForTesting
  static int debugSyncCount = 0;

  @override
  State<RiveFocusWidget> createState() => _RiveFocusWidgetState();
}

class _RiveFocusWidgetState extends State<RiveFocusWidget> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'RiveFocusWidget');

  /// Whether Flutter focus is on this widget, as last reported by
  /// [_onFocusChange]. Read at teardown, when the node itself has already
  /// been detached and its final change never arrives.
  bool _hasFlutterFocus = false;

  bool _syncScheduled = false;

  /// Whether the scene claimed the Tab press currently held down, latched on
  /// its first down so the repeats and the release follow the same path.
  /// Null between presses.
  bool? _tabClaimedByScene;

  rive.StateMachine? get _stateMachine => widget.painter.stateMachine;

  @override
  void initState() {
    super.initState();
    widget.painter.addListener(_syncCanRequestFocus);
    _syncCanRequestFocus();
  }

  @override
  void didUpdateWidget(covariant RiveFocusWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.painter == widget.painter) return;
    oldWidget.painter.removeListener(_syncCanRequestFocus);
    // The focused node belongs to the outgoing machine; clear it there.
    if (_hasFlutterFocus) {
      _clearRiveFocusOn(oldWidget.painter.stateMachine, repaint: false);
    }
    widget.painter.addListener(_syncCanRequestFocus);
    _syncCanRequestFocus();
  }

  @override
  void dispose() {
    widget.painter.removeListener(_syncCanRequestFocus);
    // Unmounting takes the focus target away, so a node this widget focused
    // must not keep its ring. No repaint: teardown must not notify.
    if (_hasFlutterFocus) {
      _clearRiveFocusOn(_stateMachine, repaint: false);
    }
    _focusNode.dispose();
    super.dispose();
  }

  /// The content decides whether this widget is a focus target. The tree is
  /// rebuilt when the artboard changes and grows as lists populate, which
  /// happens inside an advance with no painter notification. So re-read on
  /// every painter notification, and after each frame while the painter's
  /// ticker runs (content only changes while it advances); a settled
  /// graphic costs nothing per frame.
  void _syncCanRequestFocus({bool armed = false}) {
    RiveFocusWidget.debugSyncCount++;
    final can = _stateMachine?.hasFocusNodes ?? false;
    if (_focusNode.canRequestFocus != can) {
      _focusNode.canRequestFocus = can;
    }
    // A notification precedes the ticker restart, so always arm one check
    // from there; from a frame, only while frames keep coming.
    if (armed && !_painterTicking) return;
    if (_syncScheduled) return;
    _syncScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (mounted) _syncCanRequestFocus(armed: true);
    });
  }

  bool get _painterTicking {
    final painter = widget.painter;
    // A painter that cannot say is treated as always advancing.
    return painter is! rive.RiveTickerAwarePainterMixin ||
        painter.isTickerActive;
  }

  /// Focus changes queue focus/blur events on the state machine; process
  /// them now and keep frames coming so the content can animate.
  void _afterInput(rive.StateMachine sm) {
    widget.painter.scheduleRepaint();
    sm.advanceAndApply(0);
  }

  void _clearRiveFocusOn(rive.StateMachine? sm, {bool repaint = true}) {
    if (sm == null || !sm.focusState.hasFocus) return;
    sm.focusManager?.clearFocus();
    sm.advanceAndApply(0);
    if (repaint) widget.painter.scheduleRepaint();
  }

  /// Direction of the traversal that is moving focus onto this widget, read
  /// from the key still held down: `true` forward, `false` backward, `null`
  /// when focus did not arrive by keyboard (a pointer press, a programmatic
  /// request), in which case the tree is entered on the next Tab instead.
  bool? _keyboardEntryDirection() {
    final keyboard = HardwareKeyboard.instance;
    final pressed = keyboard.logicalKeysPressed;
    if (pressed.contains(LogicalKeyboardKey.tab)) {
      return !keyboard.isShiftPressed;
    }
    if (pressed.contains(LogicalKeyboardKey.arrowRight) ||
        pressed.contains(LogicalKeyboardKey.arrowDown)) {
      return true;
    }
    if (pressed.contains(LogicalKeyboardKey.arrowLeft) ||
        pressed.contains(LogicalKeyboardKey.arrowUp)) {
      return false;
    }
    return null;
  }

  void _onFocusChange(bool focused) {
    _hasFlutterFocus = focused;
    if (!focused) {
      _clearRiveFocusOn(_stateMachine);
      return;
    }
    final sm = _stateMachine;
    // Rive already focused a node (a press on a TextInput, an authored focus
    // action): entering traversal now would move focus off it.
    if (sm == null || sm.focusState.hasFocus) return;
    final fm = sm.focusManager;
    if (fm == null) return;
    final direction = _keyboardEntryDirection();
    if (direction == null) return;
    final moved = direction ? fm.focusNext() : fm.focusPrevious();
    if (moved) {
      _afterInput(sm);
      return;
    }
    // Focus nodes exist but none can be entered right now (all hidden, or
    // in scopes that cannot be traversed): keep Flutter's traversal going
    // in the same direction instead of parking focus on an empty widget.
    if (direction) {
      _focusNode.nextFocus();
    } else {
      _focusNode.previousFocus();
    }
  }

  /// Whether [text] is something to type, rather than the character a
  /// control key reports (tab, newline, escape).
  static bool _isTypedText(String text) =>
      text.isNotEmpty &&
      text.codeUnits.every((unit) => unit >= 0x20 && unit != 0x7f);

  /// Offers [key] to the focused node, returning whether the scene claimed
  /// it. Always applies what the key queued: an authored listener can run
  /// without claiming, and a settled graphic produces no frame of its own.
  bool _sendKeyToScene(
    rive.StateMachine sm,
    focus.FocusManager fm,
    LogicalKeyboardKey key,
    HardwareKeyboard keyboard,
    KeyEvent event,
  ) {
    final riveKey = rive.Key.fromLogicalKey(key);
    final handled =
        riveKey != null &&
        fm.keyInput(
          riveKey.value,
          rive.KeyModifiers.bitsOf(keyboard),
          event is! KeyUpEvent,
          event is KeyRepeatEvent,
        );
    _afterInput(sm);
    return handled;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final sm = _stateMachine;
    final fm = sm?.focusManager;
    if (sm == null || fm == null) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final isUp = event is KeyUpEvent;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.tab) {
      // The scene gets first refusal on Tab, the same as every other key: a
      // focused node may have a keyboard listener that asked for it. Only the
      // first down decides, and the answer is latched for the whole physical
      // press, so a held Tab cannot switch between the scene and traversal
      // part way through.
      if (isUp) {
        final claimed = _tabClaimedByScene;
        _tabClaimedByScene = null;
        // A release with no press of its own (the window regained focus mid
        // hold) is offered to the scene rather than guessed at.
        if (claimed ?? true) {
          _sendKeyToScene(sm, fm, key, keyboard, event);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }
      _tabClaimedByScene ??=
          sm.focusState.hasFocus &&
          _sendKeyToScene(sm, fm, key, keyboard, event);
      if (_tabClaimedByScene!) return KeyEventResult.handled;

      final moved = keyboard.isShiftPressed
          ? fm.focusPrevious()
          : fm.focusNext();
      if (moved) {
        _afterInput(sm);
        return KeyEventResult.handled;
      }
      // Not moved. A scope whose edgeBehavior is `stop` keeps the node and
      // the key. Otherwise traversal ran off the end and Rive dropped focus,
      // which queued the node's blur: process it now, since a settled
      // graphic produces no frame of its own, then release the Tab so
      // Flutter moves on.
      if (sm.focusState.hasFocus) return KeyEventResult.handled;
      _afterInput(sm);
      return KeyEventResult.ignored;
    }

    if (!sm.focusState.hasFocus) return KeyEventResult.ignored;

    // The focused node first: a TextInput uses arrows for its caret.
    final riveKey = rive.Key.fromLogicalKey(key);
    var handled =
        riveKey != null &&
        fm.keyInput(
          riveKey.value,
          rive.KeyModifiers.bitsOf(keyboard),
          !isUp,
          event is KeyRepeatEvent,
        );
    if (!handled && !isUp) {
      handled = switch (key) {
        LogicalKeyboardKey.arrowLeft => fm.focusLeft(),
        LogicalKeyboardKey.arrowRight => fm.focusRight(),
        LogicalKeyboardKey.arrowUp => fm.focusUp(),
        LogicalKeyboardKey.arrowDown => fm.focusDown(),
        _ => false,
      };
    }
    // A shortcut chord is not typing: macOS still reports the letter of
    // Cmd+C as the event's character. Option is kept, it is how macOS types
    // accented characters. So is AltGr, which layouts use to type @ or the
    // euro sign: Windows reports it as Ctrl plus right Alt, browsers as Ctrl
    // plus AltGraph. Ctrl with the left Alt stays a chord.
    final isAltGr =
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.altRight) ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.altGraph);
    final isChord =
        keyboard.isMetaPressed || (keyboard.isControlPressed && !isAltGr);
    if (!handled && !isUp && !isChord) {
      final text = event.character;
      handled = text != null && _isTypedText(text) && fm.textInput(text);
    }
    // The key reached a focused node and may have fired an authored
    // keyboard listener or moved focus. Apply what that queued and restart
    // frames on a settled graphic so the animation plays, whether or not
    // core claimed the key.
    _afterInput(sm);
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// A press on the content focuses the widget, like a press on a canvas,
  /// so keys reach Rive from here on. Rive focus itself is left to the
  /// content: a press only focuses a TextInput or an authored focus target,
  /// and core applies that on the press itself, so the focus change below
  /// sees the node the press focused.
  void _onPointerDown(PointerDownEvent event) {
    if (_focusNode.canRequestFocus && !_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onFocusChange: _onFocusChange,
      onKeyEvent: _onKeyEvent,
      // Semantics stay with the child (RiveSemanticsWidget, when enabled);
      // this node must not add an anonymous focusable element.
      includeSemantics: false,
      child: Listener(
        onPointerDown: _onPointerDown,
        behavior: HitTestBehavior.deferToChild,
        child: widget.child,
      ),
    );
  }
}
