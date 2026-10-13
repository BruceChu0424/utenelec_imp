import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../shared/pricing/price_analysis_models.dart';
import '../../../shared/pricing/price_analysis_l10n.dart';

/// Native, bounded scatter chart: no synthetic dates or smoothed fake prices.
/// Exact values are provided beside the visual and in the source table.
class PriceHistoryChart extends StatefulWidget {
  const PriceHistoryChart({super.key, required this.analysis});
  final GoodsPriceAnalysis analysis;
  @override
  State<PriceHistoryChart> createState() => _PriceHistoryChartState();
}

class _PriceHistoryChartState extends State<PriceHistoryChart> {
  PriceObservation? _selected;
  @override
  void didUpdateWidget(covariant PriceHistoryChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.analysis != widget.analysis) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final points = widget.analysis.observations
        .where(
          (e) =>
              e.comparable &&
              e.date != null &&
              double.tryParse(e.price)?.isFinite == true,
        )
        .toList();
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
        SizedBox(
          height: 250,
          child: LayoutBuilder(
            builder: (context, box) {
              final painter = _PricePainter(
                points,
                widget.analysis,
                theme.colorScheme,
                theme.textTheme.bodySmall ?? const TextStyle(fontSize: 12),
                _selected,
              );
              void select(Offset local) {
                final nearest = painter.nearest(local, Size(box.maxWidth, 250));
                if (_selected != nearest) setState(() => _selected = nearest);
              }

              return Semantics(
                label:
                    '${priceText(context, 'facts')}: ${points.length}. ${priceText(context, 'history')}',
                child: MouseRegion(
                  onHover: (event) => select(event.localPosition),
                  child: GestureDetector(
                    onTapDown: (event) => select(event.localPosition),
                    child: CustomPaint(
                      painter: painter,
                      size: Size(box.maxWidth, 250),
                    ),
                  ),
                ),
              );
            },
          ),
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

class _PricePainter extends CustomPainter {
  _PricePainter(
    this.points,
    this.analysis,
    this.colors,
    this.textStyle,
    this.selected,
  );
  final List<PriceObservation> points;
  final GoodsPriceAnalysis analysis;
  final ColorScheme colors;
  final TextStyle textStyle;
  final PriceObservation? selected;
  double? number(String key) {
    if (!analysis.ready) return null;
    final n = double.tryParse(analysis.text(key));
    return n?.isFinite == true ? n : null;
  }

  (Rect, double, double, double, double)? _layout;
  (Rect, double, double, double, double) layout(Size size) {
    if (_layout != null) return _layout!;
    final times = points
        .map((p) => p.date!.millisecondsSinceEpoch.toDouble())
        .toList();
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
    return _layout = (
      Rect.fromLTRB(64, 16, math.max(65, size.width - 12), size.height - 34),
      first,
      math.max(last, first + 86400000),
      math.max(0, min - padding),
      max + padding,
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
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: textStyle.copyWith(color: colors.onSurfaceVariant),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 110);
    painter.paint(canvas, Offset(right ? at.dx - painter.width : at.dx, at.dy));
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
        Paint()..color = colors.primary.withValues(alpha: .10),
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
        value != 0 && (value.abs() < .0001 || value.abs() >= 1000000000)
            ? value.toStringAsExponential(2)
            : value.toStringAsFixed(value.abs() < 1 ? 4 : 2),
        Offset(rect.left - 8, y(value) - 7),
        right: true,
      );
    }
    if (reference != null) {
      canvas.drawLine(
        Offset(rect.left, y(reference)),
        Offset(rect.right, y(reference)),
        Paint()
          ..color = colors.primary
          ..strokeWidth = 1.5,
      );
    }
    for (final point in points) {
      canvas.drawCircle(
        position(point, size),
        point.text('sourceItemId') == selected?.text('sourceItemId') ? 6 : 3.5,
        Paint()..color = colors.primary,
      );
    }
    String day(double time) => DateTime.fromMillisecondsSinceEpoch(
      time.toInt(),
    ).toIso8601String().substring(0, 10);
    label(canvas, day(start), Offset(rect.left, rect.bottom + 10));
    label(canvas, day(end), Offset(rect.right, rect.bottom + 10), right: true);
  }

  @override
  bool shouldRepaint(covariant _PricePainter old) =>
      old.analysis != analysis ||
      old.selected != selected ||
      old.colors != colors ||
      old.textStyle != textStyle;
}
