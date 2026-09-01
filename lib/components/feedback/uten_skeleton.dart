// UtenSkeleton - 骨架屏
// 文档：docs/02-组件库/UtenSkeleton.md（待写）
// 性能档联动：standard/rich 闪烁，lite 静态灰色

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/performance/performance_tier.dart';
import '../../shared/providers/performance_provider.dart';

/// Uten 骨架屏 - 单个块
class UtenSkeleton extends ConsumerStatefulWidget {
  const UtenSkeleton({
    super.key,
    this.width = double.infinity,
    this.height = 16,
    this.borderRadius = 6,
  });

  final double width;
  final double height;
  final double borderRadius;

  @override
  ConsumerState<UtenSkeleton> createState() => _UtenSkeletonState();
}

class _UtenSkeletonState extends ConsumerState<UtenSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _tickerModeEnabled = false;
  bool _disableAnimations = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _disableAnimations = MediaQuery.disableAnimationsOf(context);
    _syncAnimation(ref.read(performanceProvider));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _shouldAnimate(PerformanceTier tier) =>
      _tickerModeEnabled && !_disableAnimations && tier.enableSkeletonShimmer;

  void _syncAnimation(PerformanceTier tier) {
    if (_shouldAnimate(tier)) {
      if (!_controller.isAnimating) {
        _controller.repeat(reverse: true);
      }
      return;
    }
    if (_controller.isAnimating) {
      // 保留当前位置，重新可见/允许动画时从原处继续，不产生亮度跳变。
      _controller.stop(canceled: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tier = ref.watch(performanceProvider);
    ref.listen<PerformanceTier>(performanceProvider, (_, next) {
      _syncAnimation(next);
    });
    // 柔和的底色对：surfaceContainerHigh 底 + surface 高光，闪烁更细腻
    final baseColor = theme.colorScheme.surfaceContainerHigh;
    final highlightColor = theme.colorScheme.surface;

    // lite 档、系统 reduced-motion 或祖先 TickerMode 关闭：静态且 controller 停止。
    if (!_shouldAnimate(tier)) {
      return Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: baseColor,
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: Color.lerp(baseColor, highlightColor, _controller.value),
            borderRadius: BorderRadius.circular(widget.borderRadius),
          ),
        );
      },
    );
  }
}

/// 列表骨架屏（一组 skeleton 模拟列表加载）
class UtenSkeletonList extends StatelessWidget {
  const UtenSkeletonList({super.key, this.itemCount = 5});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        return const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              UtenSkeleton(width: 48, height: 48, borderRadius: 12),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    UtenSkeleton(width: 160, height: 14),
                    SizedBox(height: 8),
                    UtenSkeleton(height: 12),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
