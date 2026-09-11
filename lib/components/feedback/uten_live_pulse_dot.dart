// UtenLivePulseDot - 「数据还在更新」的小圆点。
// 文档：docs/02-组件库/UtenLivePulseDot.md
//
// 设计原则：
// - 8px 实心圆点 + 一圈随采样成功一次性扩散的光晕（非无限循环，符合 07-性能自适应 §七）
// - [pulse] 计数器每 +1 播放一次；值不变不播放，不用 Timer 自己造节拍
// - lite 档、系统「减少动画」或 TickerMode 关闭时只显示静态圆点
// - [stale] 为真时圆点变灰，表示数据已过期，不能再用「在线绿」误导

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/performance/performance_tier.dart';
import '../../core/theme/uten_anim.dart';
import '../../shared/providers/performance_provider.dart';

class UtenLivePulseDot extends ConsumerStatefulWidget {
  const UtenLivePulseDot({
    super.key,
    required this.pulse,
    this.stale = false,
    this.color,
    this.staleColor,
    this.size = 8,
    this.semanticsLabel,
  });

  /// 采样成功次数；每变化一次播放一次脉冲，初次构建不播放。
  final int pulse;

  /// 数据已过期：圆点变灰且不再脉冲。
  final bool stale;

  /// 圆点颜色，默认 `colorScheme.primary`。
  final Color? color;

  /// 过期时的颜色，默认 `colorScheme.outline`。
  final Color? staleColor;

  /// 圆点直径；光晕最大扩散到 2.2 倍，整体尺寸按此预留。
  final double size;

  /// 无障碍朗读文案；为空时按装饰元素处理，不进语义树。
  final String? semanticsLabel;

  @override
  ConsumerState<UtenLivePulseDot> createState() => _UtenLivePulseDotState();
}

class _UtenLivePulseDotState extends ConsumerState<UtenLivePulseDot>
    with SingleTickerProviderStateMixin {
  static const double _maxScale = 2.2;
  late final AnimationController _controller;
  bool _tickerModeEnabled = true;
  bool _disableAnimations = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: UtenAnim.normal);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (!_shouldAnimate(ref.read(performanceProvider))) _controller.value = 0;
  }

  @override
  void didUpdateWidget(covariant UtenLivePulseDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pulse == widget.pulse) return;
    if (widget.stale || !_shouldAnimate(ref.read(performanceProvider))) {
      _controller.value = 0;
      return;
    }
    _controller.forward(from: 0);
  }

  bool _shouldAnimate(PerformanceTier tier) =>
      _tickerModeEnabled && !_disableAnimations && !tier.isLite;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tier = ref.watch(performanceProvider);
    if (!_shouldAnimate(tier) && _controller.value != 0) _controller.value = 0;
    final color = widget.stale
        ? (widget.staleColor ?? theme.colorScheme.outline)
        : (widget.color ?? theme.colorScheme.primary);
    final dot = SizedBox.square(
      dimension: widget.size * _maxScale,
      child: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final progress = _controller.value;
            return Stack(
              alignment: Alignment.center,
              children: [
                if (progress > 0 && progress < 1)
                  Opacity(
                    opacity: (1 - progress).clamp(0.0, 1.0) * 0.45,
                    child: Container(
                      width: widget.size * (1 + (_maxScale - 1) * progress),
                      height: widget.size * (1 + (_maxScale - 1) * progress),
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                child!,
              ],
            );
          },
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      ),
    );
    final label = widget.semanticsLabel;
    return label == null || label.isEmpty
        ? ExcludeSemantics(child: dot)
        : Semantics(label: label, excludeSemantics: true, child: dot);
  }
}
