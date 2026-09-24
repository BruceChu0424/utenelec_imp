import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Marks the canvas scale on the hit-test path without taking pointer input.
class UtenDisplayZoomPointerRegion extends SingleChildRenderObjectWidget {
  const UtenDisplayZoomPointerRegion({
    super.key,
    required this.zoom,
    required super.child,
  }) : assert(zoom > 0 && zoom < double.infinity);

  final double zoom;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDisplayZoomPointerRegion(zoom);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderDisplayZoomPointerRegion).zoom = zoom;
  }
}

class _RenderDisplayZoomPointerRegion extends RenderProxyBox {
  _RenderDisplayZoomPointerRegion(this.zoom);

  double zoom;
}

/// Converts wheel signals from window pixels to the hit canvas's pixels.
///
/// Flutter transforms pointer positions but leaves PointerScrollEvent.scrollDelta
/// unchanged. Without this conversion, Transform.scale also multiplies the visible
/// scroll distance. Normalize once, before dispatch, so native Scrollables and
/// custom nested-scroll handoff listeners share the same event and resolver.
/// Hit testing, axis modifiers, scroll physics and platform responses stay native.
/// Touch drags and PointerPanZoomEvents already use transformed local distances.
mixin UtenDisplayZoomPointerEvents on GestureBinding {
  @override
  void dispatchEvent(PointerEvent event, HitTestResult? hitTestResult) {
    if (event is PointerScrollEvent && hitTestResult != null) {
      var zoom = 1.0;
      for (final entry in hitTestResult.path) {
        final target = entry.target;
        if (target is _RenderDisplayZoomPointerRegion) zoom *= target.zoom;
      }
      if (zoom != 1) {
        event = PointerScrollEvent(
          viewId: event.viewId,
          timeStamp: event.timeStamp,
          kind: event.kind,
          device: event.device,
          position: event.position,
          scrollDelta: event.scrollDelta / zoom,
          embedderId: event.embedderId,
          onRespond: event.respond,
        ).transformed(event.transform);
      }
    }
    super.dispatchEvent(event, hitTestResult);
  }
}

/// Production binding. Tests of zoomed input use the same mixin on their binding.
class UtenWidgetsFlutterBinding extends WidgetsFlutterBinding
    with UtenDisplayZoomPointerEvents {}
