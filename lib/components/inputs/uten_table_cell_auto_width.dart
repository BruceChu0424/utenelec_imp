import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../../core/performance/ui_work_budget.dart';

/// Single-line text geometry shared by a table and its rich display columns.
/// Callers add only their actual control chrome; values and precision stay intact.
double utenTableCellTextWidth(
  String text, {
  required TextStyle style,
  required TextScaler textScaler,
  TextDirection textDirection = TextDirection.ltr,
}) {
  if (text.isEmpty) return 0;
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: textDirection,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// Reports the width actually needed by the inputs inside one table cell.
///
/// The table owns growth limits, user-resized widths and its outer cell padding.
/// This observer only measures visible input values and never replaces a field,
/// controller or focus node. Its widget structure stays unchanged while typing.
class UtenTableCellAutoWidth extends StatefulWidget {
  const UtenTableCellAutoWidth({
    super.key,
    required this.child,
    required this.onWidthNeeded,
  });

  final Widget child;

  /// Needed width of [child], excluding the table host's outer cell padding.
  /// Called after the frame, only when the current allocation is insufficient.
  final ValueChanged<double> onWidthNeeded;

  @override
  State<UtenTableCellAutoWidth> createState() => _UtenTableCellAutoWidthState();
}

/// Marks the value of an input which has no [InputDecorator], such as a flat
/// dropdown. Ordinary labels, hints, validation messages and read-only table
/// text are deliberately not measured by [UtenTableCellAutoWidth].
class UtenTableInputContent extends StatelessWidget {
  const UtenTableInputContent({
    super.key,
    this.enabled = true,
    required this.child,
  });

  /// Set false while displaying an empty field's placeholder.
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class _UtenTableCellAutoWidthState extends State<UtenTableCellAutoWidth> {
  final Map<TextEditingController, _ControllerSubscription> _subscriptions = {};
  bool _measurementScheduled = false;
  double? _lastReportedWidth;
  double? _lastAllocatedWidth;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleMeasurement();
  }

  @override
  void didUpdateWidget(covariant UtenTableCellAutoWidth oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A cell may have been reused for a different row/column callback.
    if (!identical(oldWidget.onWidthNeeded, widget.onWidthNeeded)) {
      _lastReportedWidth = null;
      _lastAllocatedWidth = null;
    }
    _scheduleMeasurement();
  }

  void _scheduleMeasurement({bool urgent = false}) {
    if (!mounted) return;
    if (_measurementScheduled) {
      if (urgent) _TableCellMeasurementQueue.enqueue(this, urgent: true);
      return;
    }
    _measurementScheduled = true;
    _TableCellMeasurementQueue.enqueue(this, urgent: urgent);
  }

  void _measure() {
    final observer = debugUiWorkSliceObserver;
    if (observer == null) return _measureContents();
    final clock = Stopwatch()..start();
    try {
      _measureContents();
    } finally {
      observer('table-cell-auto-width-scan', clock.elapsed);
    }
  }

  void _measureContents() {
    final boundary = context.findRenderObject();
    if (boundary is! _RenderTableCellWidthObserver ||
        !boundary.attached ||
        !boundary.hasSize ||
        !boundary.size.width.isFinite ||
        boundary.size.width <= 0) {
      return;
    }

    final controllers = <TextEditingController>{};
    final textBoxes = <RenderBox>{};

    void collect(Element element, {bool includeParagraphs = false}) {
      final current = element.widget;
      if ((current is Offstage && current.offstage) ||
          (current is Visibility && !current.visible)) {
        return;
      }
      if (current is IndexedStack) {
        final index = current.index;
        if (index == null || index < 0 || index >= current.children.length) {
          return;
        }
        final selected = current.children[index];
        void findSelected(Element descendant) {
          if (identical(descendant.widget, selected)) {
            collect(descendant, includeParagraphs: includeParagraphs);
            return;
          }
          descendant.visitChildren(findSelected);
        }

        element.visitChildren(findSelected);
        return;
      }
      if (current is EditableText) {
        controllers.add(current.controller);
        if (current.controller.text.isNotEmpty) {
          final renderObject = element.findRenderObject();
          void findEditable(RenderObject object) {
            if (object is RenderEditable) {
              textBoxes.add(object);
              return;
            }
            object.visitChildren(findEditable);
          }

          if (renderObject != null) findEditable(renderObject);
        }
        // EditableText already owns the exact rendered (including obscured)
        // text. Do not collect its internal decoration/selection descendants.
        return;
      }
      if (current is InputDecorator) {
        final valueChild = current.child;
        if (valueChild == null) return;
        void findValueChild(Element descendant) {
          if (identical(descendant.widget, valueChild)) {
            collect(descendant, includeParagraphs: !current.isEmpty);
            return;
          }
          descendant.visitChildren(findValueChild);
        }

        // Only the real value subtree participates: labels, empty hints,
        // helpers, errors, counters and prefix/suffix decorations are excluded.
        element.visitChildren(findValueChild);
        return;
      }
      if (current is UtenTableInputContent) {
        element.visitChildren(
          (child) => collect(child, includeParagraphs: current.enabled),
        );
        return;
      }
      if (includeParagraphs && element is RenderObjectElement) {
        final renderObject = element.renderObject;
        if (renderObject is RenderParagraph &&
            renderObject.text.toPlainText().isNotEmpty) {
          textBoxes.add(renderObject);
        }
      }
      element.visitChildren(
        (child) => collect(child, includeParagraphs: includeParagraphs),
      );
    }

    (context as Element).visitChildren(collect);
    _syncControllers(controllers);

    var needed = boundary.size.width;
    for (final box in textBoxes) {
      final width = _neededCellWidth(box, boundary);
      if (width != null) needed = math.max(needed, width);
    }
    final allocated = boundary.size.width;
    if (!needed.isFinite || needed <= allocated + 0.5) return;
    if (_lastReportedWidth != null &&
        (needed - _lastReportedWidth!).abs() <= 0.5 &&
        _lastAllocatedWidth != null &&
        (allocated - _lastAllocatedWidth!).abs() <= 0.5) {
      return;
    }
    _lastReportedWidth = needed;
    _lastAllocatedWidth = allocated;
    widget.onWidthNeeded(needed);
  }

  void _syncControllers(Set<TextEditingController> controllers) {
    for (final controller in _subscriptions.keys.toList()) {
      if (controllers.contains(controller)) continue;
      controller.removeListener(_subscriptions.remove(controller)!.listener);
    }
    for (final controller in controllers) {
      if (_subscriptions.containsKey(controller)) continue;
      final subscription = _ControllerSubscription(controller.text);
      subscription.listener = () {
        final text = controller.text;
        // Caret movement/composing selection does not require text measurement.
        if (subscription.text == text) return;
        subscription.text = text;
        _scheduleMeasurement(urgent: true);
      };
      _subscriptions[controller] = subscription;
      controller.addListener(subscription.listener);
    }
  }

  @override
  void dispose() {
    _TableCellMeasurementQueue.remove(this);
    for (final entry in _subscriptions.entries) {
      entry.key.removeListener(entry.value.listener);
    }
    _subscriptions.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _TableCellWidthObserver(
    onLayoutOrPaint: _scheduleMeasurement,
    child: widget.child,
  );
}

/// All custom cells share one bounded post-frame scan queue. Their render and
/// controller discovery semantics are unchanged; one large table no longer
/// queues hundreds of independent whole-subtree scans in a single frame.
class _TableCellMeasurementQueue {
  static final _normal = <_UtenTableCellAutoWidthState>{};
  static final _urgent = <_UtenTableCellAutoWidthState>{};
  static bool _scheduled = false;
  static bool _draining = false;

  static void enqueue(
    _UtenTableCellAutoWidthState cell, {
    required bool urgent,
  }) {
    if (urgent) {
      _normal.remove(cell);
      _urgent.add(cell);
    } else if (!_urgent.contains(cell)) {
      _normal.add(cell);
    }
    _schedule();
  }

  static void remove(_UtenTableCellAutoWidthState cell) {
    _normal.remove(cell);
    _urgent.remove(cell);
  }

  static void _schedule() {
    if (_scheduled || _draining || (_normal.isEmpty && _urgent.isEmpty)) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _drain());
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  static void _drain() {
    _scheduled = false;
    _draining = true;
    final clock = Stopwatch()..start();
    var measured = 0;
    try {
      while (_urgent.isNotEmpty || _normal.isNotEmpty) {
        final pending = _urgent.isNotEmpty ? _urgent : _normal;
        final cell = pending.first;
        pending.remove(cell);
        cell._measurementScheduled = false;
        if (cell.mounted) cell._measure();
        measured++;
        if (measured >= 64 ||
            clock.elapsed >= const Duration(milliseconds: 2)) {
          break;
        }
      }
    } finally {
      _draining = false;
      if (measured > 0) {
        debugUiWorkSliceObserver?.call(
          'table-cell-auto-width-batch',
          clock.elapsed,
        );
      }
      _schedule();
    }
  }
}

class _ControllerSubscription {
  _ControllerSubscription(this.text);

  String text;
  late final VoidCallback listener;
}

/// Measures only native text renderers. Calling intrinsic/dry layout on the
/// entire cell would break LayoutBuilder cells and tree rows with IntrinsicHeight.
double? _neededCellWidth(RenderBox textBox, RenderBox boundary) {
  if (!textBox.attached || !textBox.hasSize) {
    return null;
  }
  final intrinsic = textBox.getMaxIntrinsicWidth(double.infinity);
  if (!intrinsic.isFinite || intrinsic <= textBox.size.width + 0.5) return null;

  var current = textBox;
  var needed = intrinsic;
  while (!identical(current, boundary)) {
    final parent = current.parent;
    if (parent is! RenderBox || !parent.hasSize) return null;
    if (parent is RenderOffstage && parent.offstage) return null;
    final overflow = math.max(0.0, needed - current.size.width);
    var parentNeeded = parent.size.width + overflow;
    if (parent is RenderFlex && parent.direction == Axis.horizontal) {
      final data = current.parentData;
      if (data is FlexParentData && (data.flex ?? 0) > 0) {
        var totalFlex = 0;
        parent.visitChildren((child) {
          final childData = child.parentData;
          if (childData is FlexParentData) totalFlex += childData.flex ?? 0;
        });
        // In a number/unit Row (flex 3:2), an extra 30px in the number
        // requires 50px for the cell, preserving the existing flex allocation.
        parentNeeded = parent.size.width + overflow * totalFlex / data.flex!;
      }
    } else if (parent is RenderFractionallySizedOverflowBox) {
      final factor = parent.widthFactor;
      if (factor != null && factor > 0) {
        parentNeeded = math.max(parentNeeded, needed / factor);
      }
    }
    if (parent is RenderConstrainedBox) {
      final constraints = parent.additionalConstraints;
      // A field inside SizedBox(width: ...) cannot grow with its column.
      // Feeding that overflow back would otherwise expand the table forever.
      if (constraints.hasTightWidth && constraints.maxWidth.isFinite) {
        return null;
      }
      if (constraints.maxWidth.isFinite) {
        if (parent.size.width >= constraints.maxWidth - 0.5) return null;
        // A loose maximum can still usefully grow up to its own limit. Once
        // reached, later scans stop here rather than asking the host again.
        parentNeeded = math.min(parentNeeded, constraints.maxWidth);
      }
    }
    current = parent;
    needed = parentNeeded;
  }
  return needed;
}

class _TableCellWidthObserver extends SingleChildRenderObjectWidget {
  const _TableCellWidthObserver({
    required this.onLayoutOrPaint,
    required super.child,
  });

  final VoidCallback onLayoutOrPaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTableCellWidthObserver(onLayoutOrPaint);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderTableCellWidthObserver renderObject,
  ) {
    renderObject.onLayoutOrPaint = onLayoutOrPaint;
  }
}

class _RenderTableCellWidthObserver extends RenderProxyBox {
  _RenderTableCellWidthObserver(this.onLayoutOrPaint);

  VoidCallback onLayoutOrPaint;

  @override
  void performLayout() {
    super.performLayout();
    onLayoutOrPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    onLayoutOrPaint();
  }
}
