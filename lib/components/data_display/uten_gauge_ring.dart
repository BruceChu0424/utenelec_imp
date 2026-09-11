// UtenGaugeRing - 270° 圆环仪表（服务器状态等监控指标）。
// 文档：docs/02-组件库/UtenGaugeRing.md
//
// 设计原则：
// - 轨道 surfaceContainerHighest，进度色 = 语义状态色；unknown 走 outlineVariant 虚线轨道
// - 中心数字走 UtenAnimatedNumber（仅 rich 档滚动），弧线过渡走 TweenAnimationBuilder
// - lite 档、系统「减少动画」或 TickerMode 关闭时过渡时长归零；painter 只在值/颜色变化时重绘
// - 尺寸 = min(父约束宽, 140 × 字号倍率.clamp(1, 1.6))，超大字号不溢出

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/performance/performance_tier.dart';
import '../../core/theme/uten_anim.dart';
import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../../shared/providers/performance_provider.dart';
import 'uten_animated_number.dart';

/// 圆环的语义状态；颜色由 [utenGaugeStatusColor] 统一解析。
enum UtenGaugeStatus { normal, warning, critical, unknown }

/// 状态 → 文字/进度色（深浅主题各一套，与状态徽章同源 token）。
Color utenGaugeStatusColor(BuildContext context, UtenGaugeStatus status) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  return switch (status) {
    UtenGaugeStatus.normal =>
      dark ? UtenColors.successOnDark : UtenColors.successText,
    UtenGaugeStatus.warning =>
      dark ? UtenColors.warningOnDark : UtenColors.warningText,
    UtenGaugeStatus.critical =>
      dark ? UtenColors.errorOnDark : UtenColors.errorText,
    UtenGaugeStatus.unknown => theme.colorScheme.onSurfaceVariant,
  };
}

class UtenGaugeRing extends ConsumerWidget {
  const UtenGaugeRing({
    super.key,
    required this.value,
    required this.status,
    required this.label,
    this.unit = '%',
    this.max = 100,
    this.warning,
    this.critical,
    this.statusText,
    this.valueText,
    this.caption,
    this.size,
    this.placeholder = '—',
  });

  /// 当前值（与 [max] 同一量纲）；null 时中心显示 [placeholder]，弧线为空。
  final double? value;
  final UtenGaugeStatus status;

  /// 语义标签（如「处理器」），只进入无障碍朗读，不在环内绘制。
  final String label;

  /// 中心数字右侧的单位；空字符串则不显示。
  final String unit;

  /// 满环对应的值；≤0 时按 100 处理。
  final double max;

  /// 预警/告警刻度（与 [value] 同量纲），落在 (0, max] 内才绘制。
  final double? warning;
  final double? critical;

  /// 朗读用状态文案（如「正常」）；null 时朗读省略状态。
  final String? statusText;

  /// 覆盖中心数字文本（例如按字节格式化）；给定后中心不做数字滚动。
  final String? valueText;

  /// 环下方的小字说明（例如「应用内存」或「12 / 100」）。
  final String? caption;

  /// 期望直径；实际取 min(父约束宽, size 或 140 × 字号倍率)。
  final double? size;
  final String placeholder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tier = ref.watch(performanceProvider);
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    // 离屏（保活页、Offstage）时 TickerMode 关闭，弧线直接跳到终值不排帧。
    final duration =
        tier.isLite ||
            disableAnimations ||
            !TickerMode.valuesOf(context).enabled
        ? Duration.zero
        : UtenAnim.slow * tier.durationFactor;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final preferred = (size ?? 140) * scale.clamp(1.0, 1.6);
    final effectiveMax = max > 0 ? max : 100.0;
    final fraction = value == null
        ? 0.0
        : (value! / effectiveMax).clamp(0.0, 1.0).toDouble();
    final progressColor = status == UtenGaugeStatus.unknown
        ? theme.colorScheme.outlineVariant
        : utenGaugeStatusColor(context, status);
    final textColor = utenGaugeStatusColor(context, status);
    final display = valueText ?? _format(value, placeholder);
    final semanticsLabel = statusText == null
        ? '$label $display$unit'
        : '$label $display$unit,$statusText';
    // 不用 LayoutBuilder 量父宽：LayoutBuilder 不支持 intrinsic 测量，会让
    // 外层 IntrinsicHeight（等高卡片行）直接抛断言。ConstrainedBox+AspectRatio
    // 同样得到 min(父约束宽, preferred) 的正方形，且 intrinsic 可算。
    final ring = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: preferred, maxHeight: preferred),
      child: AspectRatio(
        aspectRatio: 1,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: fraction),
          duration: duration,
          curve: UtenAnim.standard,
          builder: (context, animated, child) => CustomPaint(
            painter: UtenGaugeRingPainter(
              fraction: animated,
              progressColor: progressColor,
              trackColor: theme.colorScheme.surfaceContainerHighest,
              dashed: status == UtenGaugeStatus.unknown,
              warningFraction: _tick(warning, effectiveMax),
              criticalFraction: _tick(critical, effectiveMax),
              warningColor: utenGaugeStatusColor(
                context,
                UtenGaugeStatus.warning,
              ),
              criticalColor: utenGaugeStatusColor(
                context,
                UtenGaugeStatus.critical,
              ),
            ),
            child: child,
          ),
          child: Center(
            child: FractionallySizedBox(
              widthFactor: 0.62,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (valueText != null)
                      Text(
                        valueText!,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: textColor,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      )
                    else
                      UtenAnimatedNumber(
                        value: value,
                        placeholder: placeholder,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: textColor,
                        ),
                      ),
                    if (unit.isNotEmpty)
                      Text(
                        unit,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Semantics(
      label: semanticsLabel,
      excludeSemantics: true,
      child: caption == null || caption!.isEmpty
          ? ring
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ring,
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  caption!,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
    );
  }

  static double? _tick(double? mark, double max) {
    if (mark == null || mark <= 0 || mark > max) return null;
    return mark / max;
  }

  static String _format(double? value, String placeholder) =>
      value == null ? placeholder : UtenAnimatedNumber.defaultFormat(value);
}

/// 270° 弧线绘制；公开以便测试读取 [fraction]。
class UtenGaugeRingPainter extends CustomPainter {
  const UtenGaugeRingPainter({
    required this.fraction,
    required this.progressColor,
    required this.trackColor,
    required this.dashed,
    required this.warningColor,
    required this.criticalColor,
    this.warningFraction,
    this.criticalFraction,
  });

  static const double startAngle = math.pi * 0.75;
  static const double sweepAngle = math.pi * 1.5;
  static const int _dashCount = 36;

  final double fraction;
  final Color progressColor;
  final Color trackColor;
  final bool dashed;
  final double? warningFraction;
  final double? criticalFraction;
  final Color warningColor;
  final Color criticalColor;

  @override
  void paint(Canvas canvas, Size size) {
    final diameter = math.min(size.width, size.height);
    final stroke = (diameter * 0.085).clamp(6.0, 14.0);
    final tick = stroke * 0.55;
    final center = size.center(Offset.zero);
    final radius = diameter / 2 - stroke / 2 - tick - 2;
    if (radius <= 0) return;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    if (dashed) {
      track
        ..color = progressColor
        ..strokeCap = StrokeCap.butt;
      const double unit = sweepAngle / _dashCount;
      for (var index = 0; index < _dashCount; index++) {
        canvas.drawArc(
          rect,
          startAngle + unit * index,
          unit * 0.55,
          false,
          track,
        );
      }
    } else {
      track.color = trackColor;
      canvas.drawArc(rect, startAngle, sweepAngle, false, track);
      if (fraction > 0) {
        final progress = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..color = progressColor;
        canvas.drawArc(
          rect,
          startAngle,
          sweepAngle * fraction.clamp(0.0, 1.0),
          false,
          progress,
        );
      }
    }
    _tickMark(
      canvas,
      center,
      radius + stroke / 2,
      tick,
      warningFraction,
      warningColor,
    );
    _tickMark(
      canvas,
      center,
      radius + stroke / 2,
      tick,
      criticalFraction,
      criticalColor,
    );
  }

  void _tickMark(
    Canvas canvas,
    Offset center,
    double innerRadius,
    double length,
    double? fraction,
    Color color,
  ) {
    if (fraction == null) return;
    final angle = startAngle + sweepAngle * fraction.clamp(0.0, 1.0);
    final direction = Offset(math.cos(angle), math.sin(angle));
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      center + direction * (innerRadius + 2),
      center + direction * (innerRadius + 2 + length),
      paint,
    );
  }

  @override
  bool shouldRepaint(UtenGaugeRingPainter old) =>
      old.fraction != fraction ||
      old.progressColor != progressColor ||
      old.trackColor != trackColor ||
      old.dashed != dashed ||
      old.warningFraction != warningFraction ||
      old.criticalFraction != criticalFraction ||
      old.warningColor != warningColor ||
      old.criticalColor != criticalColor;
}
