import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Collects the natural widths of the hierarchy rows actually hosted by a pane.
/// The measurements include the rendered controls, badges, padding and text
/// scaler, so hosts do not have to duplicate their row geometry.
class UtenHierarchyContentWidthController extends ChangeNotifier {
  final Map<Object, double> _rows = {};
  final SplayTreeMap<double, int> _widths = SplayTreeMap<double, int>();
  final Map<Object, double> _rowChrome = {};
  final SplayTreeMap<double, int> _chromeWidths = SplayTreeMap<double, int>();
  final Map<Object, double> _labels = {};
  final SplayTreeMap<double, int> _labelWidths = SplayTreeMap<double, int>();
  final Map<Object, Object?> _metricsKeys = {};
  double _maximumChrome = 0;
  bool _scheduled = false;
  bool _disposed = false;

  double get minimumWidth => math.max(
    _widths.isEmpty ? 0 : _widths.lastKey()!,
    _labelWidths.isEmpty
        ? 0
        : _labelWidths.lastKey()! +
              math.max(
                _maximumChrome,
                _chromeWidths.isEmpty ? 0 : _chromeWidths.lastKey()!,
              ) +
              12,
  );

  void _replaceWidth(
    Map<Object, double> owners,
    SplayTreeMap<double, int> widths,
    Object owner,
    double? width,
  ) {
    final next = width?.ceilToDouble();
    final old = owners[owner];
    if (next == old) return;
    if (old != null) {
      final remaining = widths[old]! - 1;
      if (remaining == 0) {
        widths.remove(old);
      } else {
        widths[old] = remaining;
      }
      owners.remove(owner);
    }
    if (next != null) {
      owners[owner] = next;
      widths[next] = (widths[next] ?? 0) + 1;
    }
  }

  /// A model-level title measurement also covers collapsed/offscreen nodes.
  /// Metrics changes start a fresh control-width measurement; scrolling alone
  /// keeps the highest observed chrome so the lower drag bound cannot jump.
  void reportLabelWidth(Object owner, double? width, {Object? metricsKey}) {
    if (_disposed || (width != null && (!width.isFinite || width < 0))) return;
    final before = minimumWidth;
    if (width == null) {
      _metricsKeys.remove(owner);
    } else if (!_metricsKeys.containsKey(owner) ||
        _metricsKeys[owner] != metricsKey) {
      _metricsKeys[owner] = metricsKey;
      _maximumChrome = 0;
    }
    _replaceWidth(_labels, _labelWidths, owner, width);
    if (_labels.isEmpty) _maximumChrome = 0;
    _notifyAfterFrame(before);
  }

  void _report(Object row, double? width, {double? chrome}) {
    if (_disposed || (width != null && (!width.isFinite || width < 0))) return;
    final before = minimumWidth;
    _replaceWidth(_rows, _widths, row, width);
    _replaceWidth(
      _rowChrome,
      _chromeWidths,
      row,
      width == null ? null : chrome,
    );
    if (chrome != null && chrome.isFinite && chrome >= 0) {
      _maximumChrome = math.max(_maximumChrome, chrome.ceilToDouble());
    }
    _notifyAfterFrame(before);
  }

  void _notifyAfterFrame(double before) {
    if (minimumWidth == before || _scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) notifyListeners();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    _rows.clear();
    _widths.clear();
    _rowChrome.clear();
    _chromeWidths.clear();
    _labels.clear();
    _labelWidths.clear();
    _metricsKeys.clear();
    super.dispose();
  }
}

class UtenHierarchyContentWidthScope extends InheritedWidget {
  const UtenHierarchyContentWidthScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final UtenHierarchyContentWidthController controller;

  static UtenHierarchyContentWidthController? maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<UtenHierarchyContentWidthScope>()
          ?.controller;

  @override
  bool updateShouldNotify(UtenHierarchyContentWidthScope oldWidget) =>
      controller != oldWidget.controller;
}

/// Marks only the flexible, single-line title slot inside a hierarchy row.
class UtenHierarchyLabelWidth extends SingleChildRenderObjectWidget {
  const UtenHierarchyLabelWidth({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _HierarchyLabelWidth();
}

class _HierarchyLabelWidth extends RenderProxyBox {
  double get naturalWidth => child?.getMaxIntrinsicWidth(double.infinity) ?? 0;
}

/// Reports a row's full natural width without forcing intrinsic layout on its
/// controls. Only the title is measured intrinsically; every other width comes
/// from its actual layout. Reporting is deferred until after the frame.
class UtenHierarchyRowWidth extends SingleChildRenderObjectWidget {
  const UtenHierarchyRowWidth({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _HierarchyRowWidth(UtenHierarchyContentWidthScope.maybeOf(context));

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _HierarchyRowWidth).controller =
        UtenHierarchyContentWidthScope.maybeOf(context);
  }
}

class _HierarchyRowWidth extends RenderProxyBox {
  _HierarchyRowWidth(this._controller);

  UtenHierarchyContentWidthController? _controller;
  bool _scheduled = false;

  set controller(UtenHierarchyContentWidthController? value) {
    if (value == _controller) return;
    _controller?._report(this, null);
    _controller = value;
    markNeedsLayout();
  }

  _HierarchyLabelWidth? _label(RenderObject parent) {
    _HierarchyLabelWidth? result;
    parent.visitChildren((child) {
      result ??= child is _HierarchyLabelWidth ? child : _label(child);
    });
    return result;
  }

  @override
  void performLayout() {
    super.performLayout();
    if (_controller == null || _scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!attached || _controller == null) return;
      // Read descendant sizes only after layout; they are not direct children
      // of this proxy and must not be accessed inside its performLayout.
      final label = _label(this);
      if (label == null || !label.hasSize) {
        _controller?._report(this, null);
        return;
      }
      final chrome = math.max(0.0, size.width - label.size.width);
      _controller?._report(
        this,
        chrome + label.naturalWidth + 12,
        chrome: chrome,
      );
    });
  }

  @override
  void dispose() {
    _controller?._report(this, null);
    super.dispose();
  }
}
