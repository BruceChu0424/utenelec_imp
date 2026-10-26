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
      final original = event;
      var responded = false;
      var zoom = 1.0;
      for (final entry in hitTestResult.path) {
        final target = entry.target;
        if (target is _RenderDisplayZoomPointerRegion) zoom *= target.zoom;
      }
      event = PointerScrollEvent(
        viewId: original.viewId,
        timeStamp: original.timeStamp,
        kind: original.kind,
        device: original.device,
        position: original.position,
        scrollDelta: original.scrollDelta / zoom,
        embedderId: original.embedderId,
        onRespond: ({required allowPlatformDefault}) {
          if (responded) return;
          responded = true;
          original.respond(allowPlatformDefault: allowPlatformDefault);
        },
      ).transformed(original.transform);
      super.dispatchEvent(event, hitTestResult);
      // The resolver responds true when no handler claims the event. Native
      // Scrollable handlers respond false after consumption, but the SDK's
      // RawScrollbar handler scrolls without responding. Complete that missing
      // acknowledgement once, including at 100% zoom; preserve native boundary
      // and disabled-scroll responses and never compensate the delta again.
      if (!responded) {
        responded = true;
        original.respond(allowPlatformDefault: false);
      }
      return;
    }
    super.dispatchEvent(event, hitTestResult);
  }
}

/// Production binding. Tests of zoomed input use the same mixin on their binding.
class UtenWidgetsFlutterBinding extends WidgetsFlutterBinding
    with UtenDisplayZoomPointerEvents {}
