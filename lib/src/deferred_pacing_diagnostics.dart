import 'package:flutter/foundation.dart';

/// One sampling window of deferred pacing counters. All rates are per
/// [seconds]; elapsed values are the summed animation time the window ticked
/// versus actually painted (a persistent gap means time is banking, not
/// painting).
typedef RiveDeferredPacingWindow = ({
  double seconds,
  int textures,
  int ticks,
  int paints,
  int skipsCanAccept,
  int skipsPaused,
  int skipsAttachBlocked,
  int clearFails,
  int flushFails,
  double tickedElapsed,
  double paintedElapsed,
});

class _Counts {
  final Set<int> drivers = {};
  int ticks = 0;
  int paints = 0;
  int skipsCanAccept = 0;
  int skipsPaused = 0;
  int skipsAttachBlocked = 0;
  int clearFails = 0;
  int flushFails = 0;
  double tickedElapsed = 0;
  double paintedElapsed = 0;

  RiveDeferredPacingWindow toWindow(double seconds) => (
        seconds: seconds,
        textures: drivers.length,
        ticks: ticks,
        paints: paints,
        skipsCanAccept: skipsCanAccept,
        skipsPaused: skipsPaused,
        skipsAttachBlocked: skipsAttachBlocked,
        clearFails: clearFails,
        flushFails: flushFails,
        tickedElapsed: tickedElapsed,
        paintedElapsed: paintedElapsed,
      );
}

/// Internal pacing diagnostics for the dedicated-texture deferred paint path
/// (RiveNativeRenderBox). Counts, per sampling window, what the driver did
/// with each ticker tick - painted, or skipped and why - so a pipeline that
/// looks slow can be split into "who is pacing whom" (see DIAGNOSTICS.md at
/// the package root; `deferredThreadStats` in rive_deferred.dart is the
/// companion measure of how long record/replay take).
///
/// Not exported: this is a repo-internal tool, off by default and free when
/// off. Counters are process-global across every RiveNativeRenderBox.
class RiveDeferredPacingDiagnostics {
  RiveDeferredPacingDiagnostics._();
  static final RiveDeferredPacingDiagnostics instance =
      RiveDeferredPacingDiagnostics._();

  static bool _enabled = false;

  /// Master switch; nothing is counted while false. Turning it on drops the
  /// counts and the window that were in flight, so the first window after
  /// it is a real sampling interval rather than however long it was off.
  static bool get enabled => _enabled;
  static set enabled(bool value) {
    if (value == _enabled) {
      return;
    }
    _enabled = value;
    instance._counts = _Counts();
    instance._stopwatch = null;
  }

  /// Print one `RIVEPACE` line per window via [debugPrint] - the headless
  /// (console) consumer, useful over adb/CI logs.
  static bool logToConsole = false;

  /// Receives each completed window - the on-screen consumer.
  static void Function(RiveDeferredPacingWindow window)? onWindow;

  static const int _windowMicroseconds = 1000000;

  _Counts _counts = _Counts();
  Stopwatch? _stopwatch;

  void _tickWindow() {
    final stopwatch = _stopwatch ??= Stopwatch()..start();
    if (stopwatch.elapsedMicroseconds < _windowMicroseconds) {
      return;
    }
    final seconds = stopwatch.elapsedMicroseconds / 1e6;
    final window = _counts.toWindow(seconds);
    if (logToConsole) {
      debugPrint('RIVEPACE dart: '
          'tex=${window.textures} '
          'ticks=${(window.ticks / seconds).toStringAsFixed(1)}/s '
          'paints=${(window.paints / seconds).toStringAsFixed(1)}/s '
          'skipCanAccept=${(window.skipsCanAccept / seconds).toStringAsFixed(1)}/s '
          'skipPaused=${window.skipsPaused} '
          'skipBlocked=${window.skipsAttachBlocked} '
          'clearFail=${window.clearFails} '
          'flushFail=${window.flushFails} '
          'tickedElapsed=${window.tickedElapsed.toStringAsFixed(3)}s '
          'paintedElapsed=${window.paintedElapsed.toStringAsFixed(3)}s');
    }
    onWindow?.call(window);
    _counts = _Counts();
    stopwatch
      ..reset()
      ..start();
  }

  void tick(Object driver, double elapsedSeconds) {
    if (!_enabled) return;
    // Roll first: this tick's paint or skip is recorded later in the same
    // frame, so closing the window after counting it would file the tick in
    // one window and its outcome in the next.
    _tickWindow();
    _counts.drivers.add(identityHashCode(driver));
    _counts.ticks++;
    _counts.tickedElapsed += elapsedSeconds;
  }

  void skipPaused() {
    if (!_enabled) return;
    _counts.skipsPaused++;
  }

  void skipAttachBlocked() {
    if (!_enabled) return;
    _counts.skipsAttachBlocked++;
  }

  void skipCanAccept() {
    if (!_enabled) return;
    _counts.skipsCanAccept++;
  }

  void clearFail() {
    if (!_enabled) return;
    _counts.clearFails++;
  }

  void paint(double elapsedSeconds) {
    if (!_enabled) return;
    _counts.paints++;
    _counts.paintedElapsed += elapsedSeconds;
  }

  void flushFail() {
    if (!_enabled) return;
    _counts.flushFails++;
  }
}
