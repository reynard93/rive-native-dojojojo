import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:rive_native/rive_native.dart';
import 'package:rive_native/src/paint_dirt.dart';

abstract class BufferedRenderPaint extends RenderPaint {
  int _dirty = 0;
  ui.BlendMode _blendMode = ui.BlendMode.srcOver;

  @override
  ui.BlendMode get blendMode => _blendMode;

  @override
  set blendMode(ui.BlendMode value) {
    if (_blendMode == value) {
      return;
    }
    _blendMode = value;
    _dirty |= PaintDirt.blendMode;
  }

  ui.Color _color = const ui.Color(0x000000FF);

  @override
  ui.Color get color => _color;

  @override
  set color(ui.Color value) {
    if (_color == value) {
      return;
    }
    _color = value;
    _dirty |= PaintDirt.color;
  }

  PaintingStyle _style = PaintingStyle.fill;

  @override
  PaintingStyle get style => _style;

  @override
  set style(PaintingStyle value) {
    if (_style == value) {
      return;
    }
    _style = value;
    _dirty |= PaintDirt.style;
  }

  double _thickness = 0.0;

  double _feather = 0.0;

  @override
  double get thickness => _thickness;

  @override
  set thickness(double value) {
    if (_thickness == value) {
      return;
    }
    _thickness = value;
    _dirty |= PaintDirt.thickness;
  }

  @override
  double get feather => _feather;

  @override
  set feather(double value) {
    if (_feather == value) {
      return;
    }
    _feather = value;
    _dirty |= PaintDirt.feather;
  }

  double _additiveness = 0.0;

  @override
  double get additiveness => _additiveness;

  @override
  set additiveness(double value) {
    if (_additiveness == value) {
      return;
    }
    _additiveness = value;
    _dirty |= PaintDirt.additiveness;
  }

  ui.StrokeJoin _join = ui.StrokeJoin.miter;

  @override
  ui.StrokeJoin get join => _join;

  @override
  set join(ui.StrokeJoin value) {
    if (_join == value) {
      return;
    }
    _join = value;
    _dirty |= PaintDirt.join;
  }

  ui.StrokeCap _cap = ui.StrokeCap.butt;

  @override
  ui.StrokeCap get cap => _cap;

  @override
  set cap(ui.StrokeCap value) {
    if (_cap == value) {
      return;
    }
    _cap = value;
    _dirty |= PaintDirt.cap;
  }

  RenderGradient? _gradient;

  @override
  RenderGradient? get gradient => _gradient;

  @override
  set gradient(RenderGradient? gradient) {
    if (_gradient == gradient) {
      return;
    }
    _gradient = gradient;
    _dirty |= PaintDirt.gradient;
  }

  ByteData get scratchBufferByteData;
  void updatePaint(int dirty, int wroteStops);

  /// Flags whose value is serialized after the gradient block, so they cannot
  /// ride along with an intermediate gradient chunk.
  static const int _trailingDirt = PaintDirt.feather | PaintDirt.additiveness;

  void update() {
    if (_dirty == 0) {
      return;
    }

    final view = scratchBufferByteData;

    int offset = 0;

    if ((_dirty & PaintDirt.style) != 0) {
      view.setUint8(offset++, _style.index);
    }
    if ((_dirty & PaintDirt.color) != 0) {
      // ignore: deprecated_member_use
      view.setUint32(offset, _color.value, Endian.little);
      offset += 4;
    }
    if ((_dirty & PaintDirt.thickness) != 0) {
      view.setFloat32(offset, _thickness, Endian.little);
      offset += 4;
    }
    if ((_dirty & PaintDirt.join) != 0) {
      view.setUint8(offset++, _join.index);
    }
    if ((_dirty & PaintDirt.cap) != 0) {
      view.setUint8(offset++, _cap.index);
    }
    if ((_dirty & PaintDirt.blendMode) != 0) {
      view.setUint8(offset++, _blendMode.index);
    }

    // Fields written after the gradient terminator. The stop loop has to
    // leave room for these on top of the 16 byte terminator, or a gradient
    // that exactly fills the buffer pushes them off the end.
    var trailingBytes = 0;
    if ((_dirty & PaintDirt.feather) != 0) {
      trailingBytes += 4;
    }
    if ((_dirty & PaintDirt.additiveness) != 0) {
      trailingBytes += 4;
    }

    int wroteStops = 0;
    if (_gradient != null) {
      var gradient = _gradient!;
      var isRadial = gradient is RenderRadialGradient;
      int writeStopIndex = 0;
      while (true) {
        if (isRadial) {
          _dirty |= PaintDirt.radial;
        }

        var remaining = view.lengthInBytes - offset - 16 - trailingBytes;
        var stopsAvailable = remaining ~/ 8;
        var stopsToWrite =
            min(stopsAvailable, (gradient.stops.length - writeStopIndex));
        for (int i = 0; i < stopsToWrite; i++) {
          wroteStops++;
          view.setFloat32(
              offset, gradient.stops[writeStopIndex], Endian.little);
          offset += 4;
          view.setUint32(
              offset,
              // ignore: deprecated_member_use
              gradient.colors[writeStopIndex].value,
              Endian.little);
          offset += 4;
          writeStopIndex++;
        }
        if (gradient.stops.length - writeStopIndex == 0) {
          // Write the termination.
          view.setFloat32(offset, gradient.start.x, Endian.little);
          offset += 4;
          view.setFloat32(offset, gradient.start.y, Endian.little);
          offset += 4;
          if (isRadial) {
            view.setFloat32(offset, gradient.radius, Endian.little);
            offset += 4;
          } else {
            var linear = gradient as RenderLinearGradient;
            view.setFloat32(offset, linear.end.x, Endian.little);
            offset += 4;
            view.setFloat32(offset, linear.end.y, Endian.little);
            offset += 4;
          }
          // Stop looping, we've built the gradient.
          _dirty |= PaintDirt.done;
          break;
        } else {
          // Gotta flush we're out of space. The trailing fields have not been
          // written into this chunk, so their flags must not go with it --
          // native reads a float per flag and would consume stop bytes. Keep
          // them dirty for the final chunk, which does write them.
          updatePaint(_dirty & ~_trailingDirt, wroteStops);
          wroteStops = 0;
          _dirty &= _trailingDirt;
          offset = 0;
        }
      }
    }

    if ((_dirty & PaintDirt.feather) != 0) {
      view.setFloat32(offset, _feather, Endian.little);
      offset += 4;
    }
    if ((_dirty & PaintDirt.additiveness) != 0) {
      view.setFloat32(offset, _additiveness, Endian.little);
      offset += 4;
    }
    updatePaint(_dirty, wroteStops);
    _dirty = 0;
  }

  // The rive renderer doesn't let you turn off anti-aliasing.
  @override
  bool get isAntiAlias => true;

  @override
  set isAntiAlias(bool value) {}
}
