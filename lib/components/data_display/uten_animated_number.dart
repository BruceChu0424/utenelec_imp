// UtenAnimatedNumber - 数字滚动文本。
// 文档：docs/02-组件库/UtenAnimatedNumber.md
//
// 仅 rich 档（PerformanceTier.enableNumberAnimation）且系统未开启「减少动画」时
// 才从上一个值滚动到新值；其余档位直接显示终值。null 显示占位符，不用 0 填空。
// 数字统一 tabularFigures，滚动过程中宽度不抖。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/performance/performance_tier.dart';
import '../../core/theme/uten_anim.dart';
import '../../shared/providers/performance_provider.dart';

typedef UtenNumberFormatter = String Function(double value);

class UtenAnimatedNumber extends ConsumerWidget {
  const UtenAnimatedNumber({
    super.key,
    required this.value,
    this.format,
    this.placeholder = '—',
    this.style,
    this.textAlign,
    this.duration = UtenAnim.slow,
    this.curve = UtenAnim.standard,
  });

  /// 目标值；null 时显示 [placeholder]，切换回数值时不从 0 滚动。
  final double? value;

  /// 格式化函数；默认整数不带小数、其余保留 1 位。
  final UtenNumberFormatter? format;
  final String placeholder;
  final TextStyle? style;
  final TextAlign? textAlign;

  /// 滚动时长（rich 档再乘 `durationFactor`）。
  final Duration duration;
  final Curve curve;

  static String defaultFormat(double value) => value == value.truncateToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(1);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tier = ref.watch(performanceProvider);
    final formatter = format ?? defaultFormat;
    final textStyle = (style ?? DefaultTextStyle.of(context).style).copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final target = value;
    if (target == null) {
      return Text(placeholder, style: textStyle, textAlign: textAlign);
    }
    final animate =
        tier.enableNumberAnimation &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (!animate) {
      return Text(formatter(target), style: textStyle, textAlign: textAlign);
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: target),
      duration: duration * tier.durationFactor,
      curve: curve,
      builder: (context, current, _) =>
          Text(formatter(current), style: textStyle, textAlign: textAlign),
    );
  }
}
