import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'price_analysis_models.dart';

/// Presentation only. Recorded prices/amounts keep [priceNumber] unchanged.
/// Rounding uses decimal digits, never binary floating point; a changed label
/// always carries ≈ and its exact source stays in the tooltip/semantics.
String compactPriceStatistic(Object? value, {int significantDigits = 6}) {
  assert(significantDigits > 0);
  final exact = priceNumber(value);
  if (exact == '—') return exact;
  final negative = exact.startsWith('-');
  final unsigned = negative ? exact.substring(1) : exact;
  final parts = unsigned.split('.');
  final all = '${parts.first}${parts.length == 2 ? parts.last : ''}';
  final first = all.indexOf(RegExp('[1-9]'));
  if (first < 0) return '0';
  var exponent = parts.first.length - first - 1;
  final digits = all.substring(first);
  final scientific = exponent < -3 || exponent >= 6;
  final limit = scientific ? math.min(significantDigits, 4) : significantDigits;
  var kept = digits.substring(0, math.min(limit, digits.length));
  if (digits.length > limit && int.parse(digits[limit]) >= 5) {
    kept = (BigInt.parse(kept) + BigInt.one).toString();
    if (kept.length > limit) {
      exponent++;
      kept = kept.substring(0, limit);
    }
  }
  String trimFraction(String text) => text.contains('.')
      ? text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
      : text;
  final String unsignedLabel;
  if (exponent < -3 || exponent >= 6) {
    unsignedLabel =
        '${trimFraction('${kept[0]}.${kept.substring(1)}')}e$exponent';
  } else {
    final point = exponent + 1;
    unsignedLabel = point <= 0
        ? '0.${'0' * -point}$kept'
        : point >= kept.length
        ? kept.padRight(point, '0')
        : '${kept.substring(0, point)}.${kept.substring(point)}';
  }
  final label =
      '${negative ? '-' : ''}${unsignedLabel.contains('e') ? unsignedLabel : trimFraction(unsignedLabel)}';
  return label == exact ? exact : '≈$label';
}

String compactPriceRange(Object? lower, Object? upper) {
  if (priceNumber(lower) == '—' || priceNumber(upper) == '—') return '—';
  String format(int precision) {
    final a = compactPriceStatistic(lower, significantDigits: precision);
    final b = compactPriceStatistic(upper, significantDigits: precision);
    final approximate = a.startsWith('≈') || b.startsWith('≈');
    return '${approximate ? '≈' : ''}${a.replaceFirst('≈', '')}–${b.replaceFirst('≈', '')}';
  }

  final label = format(4);
  return label.length <= 15 ? label : format(1);
}

/// Keyboard users can focus the value to reveal the same exact value as hover.
/// Font size is preserved; the page changes its column count for large text.
class PriceSummaryValue extends StatefulWidget {
  const PriceSummaryValue({
    super.key,
    required this.compact,
    required this.exact,
    required this.semanticLabel,
    this.suffix = '',
  });
  final String compact;
  final String exact;
  final String semanticLabel;
  final String suffix;
  @override
  State<PriceSummaryValue> createState() => _PriceSummaryValueState();
}

class _PriceSummaryValueState extends State<PriceSummaryValue> {
  final _tooltipKey = GlobalKey<TooltipState>();
  @override
  Widget build(BuildContext context) => Focus(
    onFocusChange: (focused) {
      if (focused) _tooltipKey.currentState?.ensureTooltipVisible();
    },
    child: Tooltip(
      key: _tooltipKey,
      message: widget.exact,
      excludeFromSemantics: true,
      child: Semantics(
        label: widget.semanticLabel,
        excludeSemantics: true,
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: widget.compact),
              if (widget.suffix.isNotEmpty)
                TextSpan(
                  text: ' ${widget.suffix}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
      ),
    ),
  );
}
