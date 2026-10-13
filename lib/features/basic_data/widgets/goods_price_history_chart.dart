import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../components/inputs/uten_filter_chip.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/pricing/price_analysis_models.dart';
import '../../../shared/pricing/price_analysis_l10n.dart';

/// Native, bounded transaction trend: no synthetic dates or smoothed prices.
/// Exact values are provided beside the visual and in the source table.
class PriceHistoryChart extends StatefulWidget {
  const PriceHistoryChart({super.key, required this.analysis});
  final GoodsPriceAnalysis analysis;
  @override
  State<PriceHistoryChart> createState() => _PriceHistoryChartState();
}

class _PriceHistoryChartState extends State<PriceHistoryChart> {
  PriceObservation? _selected;
  bool _showReference = true;
  final _horizontal = ScrollController();

  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PriceHistoryChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.analysis != widget.analysis) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final points =
        widget.analysis.observations
            .where(
              (e) =>
                  e.comparable &&
                  e.date != null &&
                  double.tryParse(e.price)?.isFinite == true,
            )
            .toList()
          ..sort((a, b) {
            final date = a.date!.compareTo(b.date!);
            return date != 0 ? date : a.identity.compareTo(b.identity);
          });
    if (points.isEmpty) {
      return SizedBox(
        height: 180,
        child: Center(child: Text(priceText(context, 'noData'))),
      );
    }
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.show_chart,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Flexible(child: Text(priceText(context, 'actualTrend'))),
              ],
            ),
            if (widget.analysis.ready)
              UtenFilterChip(
                label: Text(priceText(context, 'referenceToggle')),
                selected: _showReference,
                onSelected: (value) => setState(() => _showReference = value),
              ),
            Text(
              widget.analysis.denomination,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        LayoutBuilder(
          builder: (context, box) {
            final painter = PriceHistoryPainter(
              points,
              widget.analysis,
              theme.colorScheme,
              theme.textTheme.bodySmall ?? const TextStyle(fontSize: 12),
              _selected,
              _showReference,
              MediaQuery.textScalerOf(context),
              Directionality.of(context),
              Localizations.maybeLocaleOf(context),
            );
            final chartSize = Size(
              math.max(box.maxWidth, painter.minimumWidth),
              painter.minimumHeight,
            );
            void select(Offset local) {
              final nearest = painter.nearest(local, chartSize);
              if (_selected != nearest) setState(() => _selected = nearest);
            }

            return SizedBox(
              height: chartSize.height + UtenSpacing.s12,
              child: Scrollbar(
                controller: _horizontal,
                thumbVisibility: true,
                notificationPredicate: (notification) =>
                    notification.metrics.axis == Axis.horizontal,
                child: SingleChildScrollView(
                  controller: _horizontal,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: chartSize.width,
                    height: chartSize.height,
                    child: Semantics(
                      label:
                          '${priceText(context, 'facts')}: ${points.length}. ${priceText(context, 'history')}',
                      child: MouseRegion(
                        onHover: (event) => select(event.localPosition),
                        child: GestureDetector(
                          onTapDown: (event) => select(event.localPosition),
                          child: CustomPaint(
                            key: const ValueKey('price-history-chart-canvas'),
                            painter: painter,
                            size: chartSize,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        if (_selected case final selected?)
          Text(
            '${selected.text('businessDate')} · ${selected.text('sourceNo')} · ${priceNumber(selected.price)} ${selected.text('currencyName')}/${selected.text('unitName')} · ${selected.text('partnerName')}',
            style: theme.textTheme.bodySmall,
          ),
      ],
    );
  }
}

class PriceHistoryPainter extends CustomPainter {
  PriceHistoryPainter(
    this.points,
    this.analysis,
    this.colors,
    this.textStyle,
    this.selected,
    this.showReference,
    this.textScaler,
    this.textDirection,
    this.locale,
  );
  final List<PriceObservation> points;
  final GoodsPriceAnalysis analysis;
  final ColorScheme colors;
  final TextStyle textStyle;
  final PriceObservation? selected;
  final bool showReference;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final Locale? locale;
  double? number(String key) {
    if (!analysis.ready || !showReference) return null;
    final n = double.tryParse(analysis.text(key));
    return n?.isFinite == true ? n : null;
  }

  (Rect, double, double, double, double)? _layout;

  String _tick(double value) =>
      value != 0 && (value.abs() < .0001 || value.abs() >= 1000000000)
      ? value.toStringAsExponential(2)
      : value.toStringAsFixed(value.abs() < 1 ? 4 : 2);

  String _day(double time) => DateTime.fromMillisecondsSinceEpoch(
    time.toInt(),
  ).toIso8601String().substring(0, 10);

  TextPainter _labelPainter(String text) => TextPainter(
    text: TextSpan(
      text: text,
      style: textStyle.copyWith(color: colors.onSurfaceVariant),
    ),
    textDirection: textDirection,
    textScaler: textScaler,
    locale: locale,
    maxLines: 1,
  )..layout();

  Size _labelSize(String text) {
    final painter = _labelPainter(text);
    final size = painter.size;
    painter.dispose();
    return size;
  }

  (double, double, double, double) get _range {
    final times = points.map((p) => p.date!.millisecondsSinceEpoch.toDouble());
    final values = [
      ...points.map((p) => double.parse(p.price)),
      ...[
        number('referencePrice'),
        number('lowerReferencePrice'),
        number('upperReferencePrice'),
      ].whereType<double>(),
    ];
    final min = values.reduce(math.min), max = values.reduce(math.max);
    final padding = math.max(
      (max - min) * .12,
      max == 0 ? .01 : max.abs() * .03,
    );
    final first = times.reduce(math.min), last = times.reduce(math.max);
    return (
      first,
      math.max(last, first + 86400000),
      math.max(0, min - padding),
      max + padding,
    );
  }

  late final _rangeValues = _range;
  late final _tickSizes = [
    for (var i = 0; i <= 3; i++)
      _labelSize(
        _tick(_rangeValues.$3 + (_rangeValues.$4 - _rangeValues.$3) * i / 3),
      ),
  ];
  late final _dateSizes = [
    _labelSize(_day(_rangeValues.$1)),
    _labelSize(_day(_rangeValues.$2)),
  ];
  late final _leftInset = math.max(
    64.0,
    _tickSizes.map((size) => size.width).reduce(math.max) + 8,
  );
  late final _tickHeight = _tickSizes
      .map((size) => size.height)
      .reduce(math.max);
  late final _dateHeight = _dateSizes
      .map((size) => size.height)
      .reduce(math.max);

  /// Charts retain their two-dimensional axes. Narrow views pan horizontally
  /// instead of reducing labels or changing actual transaction points.
  double get minimumWidth =>
      _leftInset +
      math.max(
        120.0,
        _dateSizes.fold<double>(0, (sum, size) => sum + size.width) + 16,
      ) +
      12;
  double get minimumHeight =>
      math.max(250.0, _tickHeight * 4 + _dateHeight + 32);

  (Rect, double, double, double, double) layout(Size size) {
    if (_layout != null) return _layout!;
    final (first, last, low, high) = _rangeValues;
    return _layout = (
      Rect.fromLTRB(
        _leftInset,
        math.max(16, _tickHeight / 2 + 4),
        size.width - 12,
        size.height - _dateHeight - 16,
      ),
      first,
      last,
      low,
      high,
    );
  }

  Offset position(PriceObservation point, Size size) {
    final (r, start, end, low, high) = layout(size);
    return Offset(
      r.left +
          (point.date!.millisecondsSinceEpoch - start) /
              (end - start) *
              r.width,
      r.bottom - (double.parse(point.price) - low) / (high - low) * r.height,
    );
  }

  PriceObservation? nearest(Offset p, Size size) {
    PriceObservation? result;
    var distance = double.infinity;
    for (final point in points) {
      final d = (position(point, size) - p).distanceSquared;
      if (d < distance) {
        result = point;
        distance = d;
      }
    }
    return distance < 2500 ? result : null;
  }

  void label(Canvas canvas, String text, Offset at, {bool right = false}) {
    final painter = _labelPainter(text);
    painter.paint(canvas, Offset(right ? at.dx - painter.width : at.dx, at.dy));
    painter.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final (rect, start, end, low, high) = layout(size);
    double y(double value) =>
        rect.bottom - (value - low) / (high - low) * rect.height;
    final lower = number('lowerReferencePrice'),
        upper = number('upperReferencePrice'),
        reference = number('referencePrice');
    if (lower != null && upper != null) {
      canvas.drawRect(
        Rect.fromLTRB(rect.left, y(upper), rect.right, y(lower)),
        Paint()..color = colors.primary.withValues(alpha: .055),
      );
    }
    for (var i = 0; i <= 3; i++) {
      final value = low + (high - low) * i / 3;
      canvas.drawLine(
        Offset(rect.left, y(value)),
        Offset(rect.right, y(value)),
        Paint()
          ..color = colors.outlineVariant
          ..strokeWidth = 1,
      );
      label(
        canvas,
        _tick(value),
        Offset(rect.left - 8, y(value) - _tickSizes[i].height / 2),
        right: true,
      );
    }
    if (reference != null) {
      final pen = Paint()
        ..color = colors.primary.withValues(alpha: .38)
        ..strokeWidth = 1;
      for (double x = rect.left; x < rect.right; x += 12) {
        canvas.drawLine(
          Offset(x, y(reference)),
          Offset(math.min(x + 6, rect.right), y(reference)),
          pen,
        );
      }
    }
    if (points.length > 1) {
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final point = position(points[i], size);
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..color = colors.primary,
      );
    }
    for (final point in points) {
      canvas.drawCircle(
        position(point, size),
        point.text('sourceItemId') == selected?.text('sourceItemId') ? 6 : 3.5,
        Paint()..color = colors.primary,
      );
    }
    label(canvas, _day(start), Offset(rect.left, rect.bottom + 8));
    label(canvas, _day(end), Offset(rect.right, rect.bottom + 8), right: true);
  }

  @override
  bool shouldRepaint(covariant PriceHistoryPainter old) =>
      old.analysis != analysis ||
      old.showReference != showReference ||
      old.selected != selected ||
      old.colors != colors ||
      old.textStyle != textStyle ||
      old.textScaler != textScaler ||
      old.textDirection != textDirection ||
      old.locale != locale;
}
