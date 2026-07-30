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

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tier = ref.watch(performanceProvider);
    // 柔和的底色对：surfaceContainerHigh 底 + surface 高光，闪烁更细腻
    final baseColor = theme.colorScheme.surfaceContainerHigh;
    final highlightColor = theme.colorScheme.surface;

    // lite 档：静态
    if (!tier.enableSkeletonShimmer) {
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
            color: Color.lerp(
              baseColor,
              highlightColor,
              _controller.value,
            ),
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
