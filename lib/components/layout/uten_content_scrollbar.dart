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
// 活动带通过 PointerSignalResolver 处理滚轮，支持内容外独立轨道；覆盖形态也只消费
// 一次。点击和拖动由先命中的条带手势消费，不能穿透触发底下的单元格操作。

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/uten_scrollbar_style.dart';
import '../feedback/uten_motion.dart';
import 'uten_scrollbar_rail_delegate.dart';
import 'uten_scrollbar_arrow_buttons.dart';
import '../../core/responsive/display_zoom.dart';

/// 自绘竖向内容滚动条。覆盖在视口右缘（不占布局空间），[controller] 驱动。
class UtenContentScrollbar extends StatefulWidget {
  const UtenContentScrollbar({
    super.key,
    required this.controller,
    this.visible = true,
    this.bottomInset = 0,
    this.width = UtenScrollbarStyle.laneWidth,
    this.onPointerSignal,
    this.railDelegate,
    this.windowSizedChrome = false,
  });

  /// 驱动滚动条的位置源。
  final ScrollController controller;

  /// false 时整体不显示（外滚阶段门控用）。
  final bool visible;

  /// 底部让位空白（悬浮操作组 clearance 等）：track 与 thumb 都不进入该区。
  final double bottomInset;

  /// 覆盖条宽度。
  final double width;

  /// A page host can offer the original wheel signal to the source viewport's
  /// existing gate before this independent rail falls back to direct scrolling.
  final ValueChanged<PointerSignalEvent>? onPointerSignal;
  final UtenScrollbarRailDelegate? railDelegate;
  final bool windowSizedChrome;

  @override
  State<UtenContentScrollbar> createState() => _UtenContentScrollbarState();
}

class _UtenContentScrollbarState extends State<UtenContentScrollbar> {
  bool _hovered = false;
  bool _metricsRefreshScheduled = false;
  Object? _paintedPositionSnapshot;
  ScrollNotificationObserverState? _metricsObserver;
  double? _thumbGrabFraction;
  double get _unit =>
      widget.windowSizedChrome ? 1 / UtenDisplayScale.fontZoomOf(context) : 1;
  Object? _dragPosition;

  UtenScrollbarRailTarget? get _position => UtenScrollbarRailTarget.resolve(
    controller: widget.controller,
    delegate: widget.railDelegate,
    visible: widget.visible,
  );

  Object? get _positionSnapshot {
    final pos = _position;
    return pos == null
        ? null
        : (
            pos.identity,
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _metricsRefreshScheduled = false;
      if (mounted && _paintedPositionSnapshot != _positionSnapshot) {
        setState(() {});
      }
    });
  }

  void _handleObservedMetrics(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical ||
        notification.context == null) {
      return;
    }
    final position = Scrollable.maybeOf(notification.context!)?.position;
    if (widget.railDelegate == null &&
        (position == null || !widget.controller.positions.contains(position))) {
      return;
    }
    if (_paintedPositionSnapshot != _positionSnapshot) {
      _refreshMetricsAfterLayout();
      // Metrics can arrive after the frame that resized the viewport. Request
      // one frame for the queued comparison; there is no recurring polling.
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final observer = ScrollNotificationObserver.maybeOf(context);
    if (identical(observer, _metricsObserver)) return;
    _metricsObserver?.removeListener(_handleObservedMetrics);
    _metricsObserver = observer;
    observer?.addListener(_handleObservedMetrics);
  }

  @override
  void dispose() {
    _metricsObserver?.removeListener(_handleObservedMetrics);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant UtenContentScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.railDelegate, widget.railDelegate) ||
        (widget.railDelegate == null &&
            oldWidget.controller != widget.controller) ||
        !widget.visible) {
      _dragPosition = null;
      _thumbGrabFraction = null;
      _hovered = false;
    }
  }

  ({double length, double top}) _metrics(
    UtenScrollbarRailTarget pos,
    double track,
    double topInset,
  ) {
    final inset = widget.bottomInset.clamp(0, pos.viewportDimension);
    final viewport = pos.viewportDimension;
    final range = pos.maxScrollExtent - pos.minScrollExtent;
    // 分子、分母都剔除让位空白。只从总内容中扣除 inset 会使内容略短于
    // viewport 时比例夹到 1：虽仍有 padding 可滚，thumb 却占满轨道而无法拖动。
    final contentExtent = (range + viewport - inset).clamp(1, double.infinity);
    final ratio = ((viewport - inset) / contentExtent).clamp(0.05, 1.0);
    final length = (track * ratio)
        .clamp(
          math.min(UtenScrollbarStyle.minimumThumbLength * _unit, track * .8),
          track,
        )
        .toDouble();
    var fraction = ((pos.pixels - pos.minScrollExtent) / range).clamp(0.0, 1.0);
    if (pos.axisDirection == AxisDirection.up) fraction = 1 - fraction;
    return (length: length, top: topInset + (track - length) * fraction);
  }

  void _endDrag() {
    _thumbGrabFraction = null;
    if (_dragPosition != null) setState(() => _dragPosition = null);
  }

  void _page(UtenScrollbarRailTarget pos, int screenDirection) {
    if (!identical(pos.identity, _position?.identity)) return;
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

  void _handlePointerSignal(PointerSignalEvent event) {
    widget.onPointerSignal?.call(event);
    final pos = _position;
    if (event is! PointerScrollEvent || pos == null || !pos.acceptsUserOffset) {
      return;
    }
    final modifiers = ScrollConfiguration.of(context).pointerAxisModifiers;
    final flipAxes =
        event.kind == PointerDeviceKind.mouse &&
        HardwareKeyboard.instance.logicalKeysPressed.any(modifiers.contains);
    var delta = flipAxes ? event.scrollDelta.dx : event.scrollDelta.dy;
    if (pos.axisDirection == AxisDirection.up) delta = -delta;
    final target = (pos.pixels + delta).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if (delta == 0 || target == pos.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      if (!mounted || !identical(pos.identity, _position?.identity)) return;
      pos.pointerScroll(delta);
      (event as PointerScrollEvent).respond(allowPlatformDefault: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    // LayoutBuilder 必须覆盖不可滚动分支：缓存 child 只改变外部约束时，
    // controller 不通知尺寸变化，仍要重新判断原先隐藏的滚动条是否该出现。
    return LayoutBuilder(
      builder: (context, constraints) {
        _refreshMetricsAfterLayout();
        return AnimatedBuilder(
          animation: widget.railDelegate ?? widget.controller,
          builder: (context, _) {
            _paintedPositionSnapshot = _positionSnapshot;
            _refreshMetricsAfterLayout();
            final pos = _position;
            if (pos == null) return const SizedBox.shrink();
            final height = constraints.maxHeight;
            if (!height.isFinite) return const SizedBox.shrink();
            final track = height - widget.bottomInset.clamp(0, height);
            if (track <= 0) return const SizedBox.shrink();
            final arrowExtent = math.min(
              UtenScrollbarStyle.arrowExtent * _unit,
              track / 3,
            );
            final thumbTrack = track - 2 * arrowExtent;
            final m = _metrics(pos, thumbTrack, arrowExtent);
            final dragging = identical(_dragPosition, pos.identity);
            return Align(
              alignment: Alignment.topRight,
              child: SizedBox(
                width: widget.width,
                height: track,
                child: Semantics(
                  onScrollUp: () => _page(pos, -1),
                  onScrollDown: () => _page(pos, 1),
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerSignal: _handlePointerSignal,
                    child: MouseRegion(
                      opaque: false,
                      hitTestBehavior: HitTestBehavior.translucent,
                      cursor: dragging
                          ? SystemMouseCursors.grabbing
                          : SystemMouseCursors.grab,
                      onEnter: (_) => setState(() => _hovered = true),
                      onExit: (_) => setState(() => _hovered = false),
                      child: Stack(
                        children: [
                          GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            dragStartBehavior: DragStartBehavior.down,
                            onVerticalDragDown: (details) {
                              final y = details.localPosition.dy;
                              _thumbGrabFraction =
                                  y >= m.top && y <= m.top + m.length
                                  ? (y - m.top) / m.length
                                  : null;
                            },
                            onVerticalDragStart: (_) {
                              if (_thumbGrabFraction == null ||
                                  !identical(
                                    pos.identity,
                                    _position?.identity,
                                  )) {
                                return;
                              }
                              pos.jumpTo(pos.pixels);
                              setState(() => _dragPosition = pos.identity);
                            },
                            onVerticalDragUpdate: (details) {
                              final grab = _thumbGrabFraction;
                              final travel = thumbTrack - m.length;
                              if (grab == null ||
                                  !identical(
                                    _dragPosition,
                                    _position?.identity,
                                  ) ||
                                  !identical(_dragPosition, pos.identity) ||
                                  travel <= 0) {
                                return;
                              }
                              var fraction =
                                  ((details.localPosition.dy -
                                              arrowExtent -
                                              grab * m.length) /
                                          travel)
                                      .clamp(0.0, 1.0);
                              if (pos.axisDirection == AxisDirection.up) {
                                fraction = 1 - fraction;
                              }
                              pos.jumpTo(
                                pos.minScrollExtent +
                                    fraction *
                                        (pos.maxScrollExtent -
                                            pos.minScrollExtent),
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
                            child: UtenMotion(
                              duration: UtenScrollbarStyle.hoverDuration,
                              builder: (context, duration) =>
                                  TweenAnimationBuilder<double>(
                                    tween: Tween(
                                      begin: 0,
                                      end: _hovered || dragging ? 1 : 0,
                                    ),
                                    duration: duration,
                                    curve: UtenScrollbarStyle.hoverCurve,
                                    builder: (context, emphasis, _) => CustomPaint(
                                      // Both paints share this overflow-only branch.
                                      // The painter never owns the content hit path.
                                      foregroundPainter: _ThumbPainter(
                                        unitScale: _unit,
                                        top: m.top,
                                        length: m.length,
                                        visual: UtenScrollbarStyle.visuals(
                                          brightness,
                                          emphasis: emphasis,
                                          dragging: dragging,
                                        ),
                                      ),
                                      size: Size(widget.width, track),
                                    ),
                                  ),
                            ),
                          ),
                          Positioned.fill(
                            child: UtenScrollbarArrowButtons(
                              controller: widget.controller,
                              railDelegate: widget.railDelegate,
                              windowSizedChrome: widget.windowSizedChrome,
                              onPointerSignal: widget.onPointerSignal,
                              visual: UtenScrollbarStyle.visuals(
                                brightness,
                                emphasis: _hovered || dragging ? 1 : 0,
                                dragging: dragging,
                              ),
                            ),
                          ),
                        ],
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
    required this.visual,
    required this.unitScale,
  });

  final double top;
  final double length;
  final UtenScrollbarVisuals visual;
  final double unitScale;

  @override
  void paint(Canvas canvas, Size size) {
    UtenScrollbarStyle.paintTrack(canvas, size, visual, unitScale: unitScale);
    final thumbWidth = (visual.thickness * unitScale)
        .clamp(0, size.width)
        .toDouble();
    final radius = Radius.circular(thumbWidth / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          (size.width - thumbWidth) / 2,
          top,
          thumbWidth,
          length.clamp(0, size.height - top),
        ),
        radius,
      ),
      Paint()..color = visual.thumbColor,
    );
  }

  @override
  bool shouldRepaint(_ThumbPainter oldDelegate) =>
      oldDelegate.unitScale != unitScale ||
      oldDelegate.top != top ||
      oldDelegate.length != length ||
      oldDelegate.visual.thumbColor != visual.thumbColor ||
      oldDelegate.visual.trackColor != visual.trackColor ||
      oldDelegate.visual.borderColor != visual.borderColor ||
      oldDelegate.visual.thickness != visual.thickness;
}
