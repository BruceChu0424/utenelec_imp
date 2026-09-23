// UtenContentScrollbar - 自绘竖向滚动条：thumb 活动带与长度剔除底部让位空白。
//
// 2026-09-22 用户口径：「表格最下面留了给悬浮按钮让位的空白，滚动条应该只到
// 内容高度，不伸进底部空白区」。框架 Scrollbar 的 thumb 按 position 全量
// metrics（含 ListView 底 padding）绘制——滚到底时 thumb 贴视口底、落在空白
// 让位区里，观感像还有内容。本组件自绘 thumb：
//  - 活动带（track）= 视口高 − [bottomInset]（让位空白在 track 之外）；
//  - thumb 长度按**真实内容**（总 extent − bottomInset）的可见比例；
//  - 滚到底时 thumb 下缘正好贴内容底（视口底上方 bottomInset 处）。
// controller 驱动（不存在无 controller 时横轴通知污染竖向 thumb 的问题）。
//
// 条带整体不吃指针（IgnorePointer）：thumb 命中区会把右缘条带下的内容拖拽/
// 表格 widget 测试的命中链截走（拖点落在 thumb 上时页面滚不动）。滚动交互
// 由内容拖拽/滚轮原生承担；条带只负责显示。

import 'package:flutter/material.dart';

/// 自绘竖向内容滚动条。覆盖在视口右缘（不占布局空间），[controller] 驱动。
class UtenContentScrollbar extends StatefulWidget {
  const UtenContentScrollbar({
    super.key,
    required this.controller,
    this.visible = true,
    this.bottomInset = 0,
    this.width = 14,
  });

  /// 驱动滚动条的位置源。
  final ScrollController controller;

  /// false 时整体不显示（外滚阶段门控用）。
  final bool visible;

  /// 底部让位空白（悬浮操作组 clearance 等）：track 与 thumb 都不进入该区。
  final double bottomInset;

  /// 覆盖条宽度。
  final double width;

  @override
  State<UtenContentScrollbar> createState() => _UtenContentScrollbarState();
}

class _UtenContentScrollbarState extends State<UtenContentScrollbar> {
  static const double _thumbWidth = 6;
  static const double _thumbGutter = 3;

  ({double len, double top}) _metrics(ScrollPosition pos, double trackHeight) {
    final inset = widget.bottomInset.clamp(0, trackHeight);
    final track = trackHeight - inset;
    final viewport = pos.viewportDimension;
    final max = pos.maxScrollExtent;
    // 真实内容高（剔除让位空白）与内容可见比例。
    final contentExtent = (max + viewport - inset).clamp(1, double.infinity);
    final ratio = (viewport / contentExtent).clamp(0.05, 1.0);
    final len = track * ratio;
    final top = max <= 0 ? 0.0 : (track - len) * (pos.pixels / max);
    return (len: len, top: top);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 条带只负责显示（见文件头）；不吃任何指针。
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          if (!widget.visible) return const SizedBox.shrink();
          final pos = widget.controller.positions.length == 1
              ? widget.controller.position
              : null;
          if (pos == null ||
              !pos.hasContentDimensions ||
              !pos.hasViewportDimension ||
              pos.maxScrollExtent <= 0) {
            return const SizedBox.shrink();
          }
          return LayoutBuilder(
            builder: (context, constraints) {
              final m = _metrics(pos, constraints.maxHeight);
              return CustomPaint(
                painter: _ThumbPainter(
                  top: m.top,
                  length: m.len,
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.35,
                  ),
                  thumbWidth: _thumbWidth,
                  gutter: _thumbGutter,
                ),
                size: Size(widget.width, constraints.maxHeight),
              );
            },
          );
        },
      ),
    );
  }
}

class _ThumbPainter extends CustomPainter {
  _ThumbPainter({
    required this.top,
    required this.length,
    required this.color,
    required this.thumbWidth,
    required this.gutter,
  });

  final double top;
  final double length;
  final Color color;
  final double thumbWidth;
  final double gutter;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(thumbWidth / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          size.width - gutter - thumbWidth,
          top,
          thumbWidth,
          length.clamp(0, size.height - top),
        ),
        radius,
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_ThumbPainter oldDelegate) =>
      oldDelegate.top != top ||
      oldDelegate.length != length ||
      oldDelegate.color != color;
}
