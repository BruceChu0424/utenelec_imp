// FloatingCapsuleNavBar - 底部悬浮胶囊导航（全断点统一）
// 交互参考 JustPlay floating_nav_bar.dart：
//   - 胶囊外壳：半透明玻璃底色 + 主色淡投影，圆角 = 高度 / 2
//   - 整体滑块高亮：横向位置 = 连续 position × 单格宽度，随手指实时跟手
//   - 文字颜色 / 字重按「与当前位置的距离」插值
//   - 宽度自适应：按最长 label 用 TextPainter 计算单格宽，clamp 在最小/最大之间
// 技术栈适配：JustPlay 用 GetX `.tr`，本项目改为直接传入已本地化的 label 列表。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/uten_colors.dart';

/// 底部悬浮胶囊导航栏。
///
/// [position] 是连续页位置（0..n-1，小数 = 拖拽/动画中间态），
/// 通常由 PageController 的监听喂入；点按通过 [onTap] 回调离散 index。
class FloatingCapsuleNavBar extends StatelessWidget {
  const FloatingCapsuleNavBar({
    super.key,
    required this.position,
    required this.onTap,
    required this.labels,

    /// 各 tab 的未读角标数（>0 才显示红点）；长度不足视为 0。
    this.badgeCounts = const <int>[],
  });

  final ValueListenable<double> position;
  final ValueChanged<int> onTap;
  final List<String> labels;
  final List<int> badgeCounts;

  /// 单格最小/最大宽度
  static const double _minItemWidth = 64.0;
  static const double _maxItemWidth = 96.0;
  static const double _gap = 6.0;

  /// 外壳高度与圆角（胶囊形：圆角 = 高度 / 2）
  static const double navHeight = 60;
  static const double navRadius = 30;

  /// 外壳水平 padding（6×2）与描边（1×2），宽度计算必须计入，
  /// 否则内部 Row 会比可用宽度多出 2px 导致溢出。
  static const double _hPadding = 12.0;
  static const double _hBorder = 2.0;

  /// 根据最长 label 计算单格宽度。
  ///
  /// [textScaler] 必须传入（全局字号档 小/标准/大/超大/超超大 通过 MediaQuery
  /// textScaler 生效）——否则按 1.0 量出的宽度在大字号下偏小，文字溢出。
  static double calcItemWidth(List<String> labels, TextScaler textScaler) {
    const style = TextStyle(fontSize: 14, fontWeight: FontWeight.w600);
    var maxTextWidth = 0.0;
    for (final label in labels) {
      final tp = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      if (tp.width > maxTextWidth) maxTextWidth = tp.width;
    }
    // 单格 = 文字宽 + 左右 padding（各约 18px）；上限随字号档等比放大，
    // 否则大字号下文字量宽被卡回 96、标签被迫省略号截断。
    return (maxTextWidth + 36).clamp(
      _minItemWidth,
      _maxItemWidth * textScaler.scale(1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final n = labels.length;
    final textScaler = MediaQuery.textScalerOf(context);
    final rawItemWidth = calcItemWidth(labels, textScaler);
    final screenW = MediaQuery.sizeOf(context).width;
    // 外壳最大宽度 = 屏宽 - 24（左右各留 12）
    final maxOuter = screenW - 24;
    // 内容区最大宽度 = 外壳 - 水平 padding - 描边
    final maxInner = maxOuter - _hPadding - _hBorder;
    // itemWidth 上限：保证 n 格 + (n-1) 间距不超出 maxInner；
    // 上限同样随字号档放大（与 calcItemWidth 一致），避免大字号标签被裁。
    final maxItemCap = _maxItemWidth * textScaler.scale(1);
    final maxItemW = ((maxInner - (n - 1) * _gap) / n).floorToDouble();
    final itemWidth = rawItemWidth.clamp(
      _minItemWidth,
      maxItemW.clamp(_minItemWidth, maxItemCap),
    );
    final innerWidth = n * itemWidth + (n - 1) * _gap;
    // 外壳宽度 = 内容区 + padding + 描边（与内部算式完全一致）
    final outerWidth = innerWidth + _hPadding + _hBorder;

    // 半透明玻璃底色
    final glassColor = isDark
        ? UtenColors.darkSurfaceLow.withValues(alpha: 0.78)
        : Colors.white.withValues(alpha: 0.85);
    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.5)
        : theme.colorScheme.primary.withValues(alpha: 0.15);

    return Center(
      child: AnimatedBuilder(
        animation: position,
        builder: (context, _) {
          final pos = position.value.clamp(0.0, (n - 1).toDouble());
          return Container(
            width: outerWidth,
            height: navHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(navRadius),
              boxShadow: [
                BoxShadow(
                  color: shadowColor,
                  // 浅色降 blurRadius 减 GPU 高斯模糊每帧成本；深色保持外观
                  blurRadius: isDark ? 24 : 12,
                  spreadRadius: -2,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(navRadius),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(navRadius),
                  color: glassColor,
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.6,
                    ),
                  ),
                ),
                child: SizedBox(
                  height: 46,
                  width: innerWidth,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // 整体滑块高亮（跟手）
                      Positioned(
                        left: pos * (itemWidth + _gap),
                        top: 0,
                        bottom: 0,
                        width: itemWidth,
                        child: Container(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius: BorderRadius.circular(22),
                          ),
                        ),
                      ),
                      // 各项文字
                      Row(
                        children: [
                          for (var i = 0; i < n; i++) ...[
                            if (i > 0) const SizedBox(width: _gap),
                            _CapsuleTab(
                              label: labels[i],
                              width: itemWidth,
                              closeness: 1 - (pos - i).abs().clamp(0.0, 1.0),
                              showBadge:
                                  i < badgeCounts.length && badgeCounts[i] > 0,
                              onTap: () => onTap(i),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CapsuleTab extends StatelessWidget {
  const _CapsuleTab({
    required this.label,
    required this.width,
    required this.closeness,
    required this.showBadge,
    required this.onTap,
  });

  final String label;
  final double width;

  /// 0 = 未选中 … 1 = 选中（连续插值）
  final double closeness;
  final bool showBadge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unselected = theme.colorScheme.onSurfaceVariant;
    final color = Color.lerp(
      unselected,
      theme.colorScheme.onPrimary,
      closeness,
    )!;
    final weight = FontWeight.lerp(
      FontWeight.w500,
      FontWeight.w700,
      closeness,
    )!;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: SizedBox(
          width: width,
          height: double.infinity,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: weight,
                      color: color,
                    ),
                  ),
                ),
              ),
              if (showBadge)
                Positioned(
                  top: 4,
                  right: 10,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.redAccent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
