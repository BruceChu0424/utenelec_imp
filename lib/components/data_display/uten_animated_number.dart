// UtenAnimatedNumber - 数字滚动动画
// 文档：docs/02-组件库/UtenAnimatedNumber.md（待写）
// 性能档联动：rich 档才滚动，lite 直接显示

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/performance/performance_tier.dart';
import '../../core/theme/uten_anim.dart';
import '../../shared/providers/performance_provider.dart';

/// 数字滚动动画组件
///
/// 数值变化时从旧值平滑过渡到新值。
/// 性能档为 lite 时直接显示当前值（不动画）。
class UtenAnimatedNumber extends ConsumerStatefulWidget {
  const UtenAnimatedNumber({
    super.key,
    required this.value,
    this.style,
    this.duration,
    this.curve = UtenAnim.standard,
    this.fractionDigits = 0,
  });

  /// 目标数值
  final num value;

  /// 文本样式
  final TextStyle? style;

  /// 动画时长（默认 normal）
  final Duration? duration;

  /// 曲线
  final Curve curve;

  /// 小数位数
  final int fractionDigits;

  @override
  ConsumerState<UtenAnimatedNumber> createState() => _UtenAnimatedNumberState();
}

class _UtenAnimatedNumberState extends ConsumerState<UtenAnimatedNumber>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;
  num _oldValue = 0;

  @override
  void initState() {
    super.initState();
    _oldValue = widget.value;
    _controller = AnimationController(
      vsync: this,
      duration: (widget.duration ?? UtenAnim.normal) * _durationFactor(),
    );
    _animation = Tween<double>(
      begin: _oldValue.toDouble(),
      end: widget.value.toDouble(),
    ).animate(CurvedAnimation(parent: _controller, curve: widget.curve));
    _controller.value = 1; // 首次显示完成态
  }

  double _durationFactor() {
    // 性能档影响：lite 时压缩到 50%
    return ref.read(performanceProvider).durationFactor;
  }

  @override
  void didUpdateWidget(UtenAnimatedNumber oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.value != widget.value) {
      _oldValue = oldWidget.value;
      _controller.duration =
          (widget.duration ?? UtenAnim.normal) * _durationFactor();

      _animation = Tween<double>(
        begin: _oldValue.toDouble(),
        end: widget.value.toDouble(),
      ).animate(CurvedAnimation(parent: _controller, curve: widget.curve));

      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tier = ref.watch(performanceProvider);

    // lite 档直接显示当前值
    if (!tier.enableNumberAnimation) {
      return Text(
        _format(widget.value),
        style: widget.style,
      );
    }

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        return Text(
          _format(_animation.value),
          style: widget.style,
        );
      },
    );
  }

  String _format(num value) {
    if (widget.fractionDigits == 0) {
      return value.round().toString();
    }
    return value.toStringAsFixed(widget.fractionDigits);
  }
}
