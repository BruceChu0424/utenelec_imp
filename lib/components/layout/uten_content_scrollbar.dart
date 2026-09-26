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
// 只有右缘活动带参与手势竞争：thumb 可拖、轨道可点击翻页，底部让位区透传。
// 活动带采用 translucent 命中，保留底下 Scrollable 的滚轮信号处理；点击和
// 拖动则由先命中的条带手势消费，不能穿透触发底下的单元格操作。

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 自绘竖向内容滚动条。覆盖在视口右缘（不占布局空间），[controller] 驱动。
class UtenContentScrollbar extends StatefulWidget {
  const UtenContentScrollbar({
    super.key,
    required this.controller,
    this.visible = true,
    this.bottomInset = 0,
    this.width = 16,
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
  // thumb 粗细：2026-09-25 用户口径「上下滚动条太细」，6 → 10（命中带默认宽随调
  // 14 → 16，thumb 在带内 x∈[3,13]，右缘留 gutter 呼吸）。
  static const double _thumbWidth = 10;
  static const double _thumbGutter = 3;
  bool _hovered = false;
  bool _metricsRefreshScheduled = false;
  double? _thumbGrabFraction;
  ScrollPosition? _dragPosition;

  ScrollPosition? get _position {
    if (!widget.visible || widget.controller.positions.length != 1) return null;
    final pos = widget.controller.position;
    if (!pos.hasContentDimensions ||
        !pos.hasViewportDimension ||
        !pos.hasPixels ||
        pos.axis != Axis.vertical ||
        !pos.minScrollExtent.isFinite ||
        !pos.maxScrollExtent.isFinite ||
        pos.maxScrollExtent <= pos.minScrollExtent) {
      return null;
    }
    return pos;
  }

  Object? get _positionSnapshot {
    final pos = _position;
    return pos == null
        ? null
        : (
            pos,
            pos.pixels,
            pos.minScrollExtent,
            pos.maxScrollExtent,
            pos.viewportDimension,
            pos.axisDirection,
          );
  }

  // ScrollController 不会因 attach 或首次布局的尺寸变化通知。绘制后核对一次，
  // 使首次显示及窗口/内容尺寸变化无需等待用户先滚动；尺寸稳定后不再请求帧。
  void _refreshMetricsAfterLayout() {
    if (_metricsRefreshScheduled) return;
    _metricsRefreshScheduled = true;
    final snapshot = _positionSnapshot;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _metricsRefreshScheduled = false;
      if (mounted && snapshot != _positionSnapshot) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant UtenContentScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller || !widget.visible) {
      _dragPosition = null;
      _thumbGrabFraction = null;
      _hovered = false;
    }
  }

  ({double length, double top}) _metrics(ScrollPosition pos, double track) {
    final inset = widget.bottomInset.clamp(0, pos.viewportDimension);
    final viewport = pos.viewportDimension;
    final range = pos.maxScrollExtent - pos.minScrollExtent;
    // 分子、分母都剔除让位空白。只从总内容中扣除 inset 会使内容略短于
    // viewport 时比例夹到 1：虽仍有 padding 可滚，thumb 却占满轨道而无法拖动。
    final contentExtent = (range + viewport - inset).clamp(1, double.infinity);
    final ratio = ((viewport - inset) / contentExtent).clamp(0.05, 1.0);
    final length = track * ratio;
    var fraction = ((pos.pixels - pos.minScrollExtent) / range).clamp(0.0, 1.0);
    if (pos.axisDirection == AxisDirection.up) fraction = 1 - fraction;
    return (length: length, top: (track - length) * fraction);
  }

  void _endDrag() {
    _thumbGrabFraction = null;
    if (_dragPosition != null) setState(() => _dragPosition = null);
  }

  void _page(ScrollPosition pos, int screenDirection) {
    if (!identical(pos, _position)) return;
    final direction = pos.axisDirection == AxisDirection.up
        ? -screenDirection
        : screenDirection;
    final target = (pos.pixels + direction * pos.viewportDimension * 0.8).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if (MediaQuery.disableAnimationsOf(context)) {
      pos.jumpTo(target);
    } else {
      pos.animateTo(
        target,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // LayoutBuilder 必须覆盖不可滚动分支：缓存 child 只改变外部约束时，
    // controller 不通知尺寸变化，仍要重新判断原先隐藏的滚动条是否该出现。
    return LayoutBuilder(
      builder: (context, constraints) {
        _refreshMetricsAfterLayout();
        return AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) {
            _refreshMetricsAfterLayout();
            final pos = _position;
            if (pos == null) return const SizedBox.shrink();
            final height = constraints.maxHeight;
            if (!height.isFinite) return const SizedBox.shrink();
            final track = height - widget.bottomInset.clamp(0, height);
            if (track <= 0) return const SizedBox.shrink();
            final m = _metrics(pos, track);
            final dragging = identical(_dragPosition, pos);
            return Align(
              alignment: Alignment.topRight,
              child: SizedBox(
                width: widget.width,
                height: track,
                child: Semantics(
                  onScrollUp: () => _page(pos, -1),
                  onScrollDown: () => _page(pos, 1),
                  child: MouseRegion(
                    opaque: false,
                    hitTestBehavior: HitTestBehavior.translucent,
                    cursor: dragging
                        ? SystemMouseCursors.grabbing
                        : SystemMouseCursors.grab,
                    onEnter: (_) => setState(() => _hovered = true),
                    onExit: (_) => setState(() => _hovered = false),
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      dragStartBehavior: DragStartBehavior.down,
                      onVerticalDragDown: (details) {
                        final y = details.localPosition.dy;
                        _thumbGrabFraction = y >= m.top && y <= m.top + m.length
                            ? (y - m.top) / m.length
                            : null;
                      },
                      onVerticalDragStart: (_) {
                        if (_thumbGrabFraction == null ||
                            !identical(pos, _position)) {
                          return;
                        }
                        pos.jumpTo(pos.pixels);
                        setState(() => _dragPosition = pos);
                      },
                      onVerticalDragUpdate: (details) {
                        final grab = _thumbGrabFraction;
                        final travel = track - m.length;
                        if (grab == null ||
                            !identical(_dragPosition, _position) ||
                            !identical(_dragPosition, pos) ||
                            travel <= 0) {
                          return;
                        }
                        var fraction =
                            ((details.localPosition.dy - grab * m.length) /
                                    travel)
                                .clamp(0.0, 1.0);
                        if (pos.axisDirection == AxisDirection.up) {
                          fraction = 1 - fraction;
                        }
                        pos.jumpTo(
                          pos.minScrollExtent +
                              fraction *
                                  (pos.maxScrollExtent - pos.minScrollExtent),
                        );
                      },
                      onVerticalDragEnd: (_) => _endDrag(),
                      onVerticalDragCancel: _endDrag,
                      onTapUp: (details) {
                        final y = details.localPosition.dy;
                        if (y < m.top) {
                          _page(pos, -1);
                        } else if (y > m.top + m.length) {
                          _page(pos, 1);
                        }
                      },
                      child: CustomPaint(
                        // 前景 painter 不自行命中，translucent 才能把底下的
                        // Scrollable 留在命中链中，滚轮仍由原有滚动链处理。
                        foregroundPainter: _ThumbPainter(
                          top: m.top,
                          length: m.length,
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: dragging ? 0.7 : (_hovered ? 0.55 : 0.35),
                          ),
                          thumbWidth: _thumbWidth,
                          gutter: _thumbGutter,
                        ),
                        size: Size(widget.width, track),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
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
      oldDelegate.color != color ||
      oldDelegate.thumbWidth != thumbWidth ||
      oldDelegate.gutter != gutter;
}
