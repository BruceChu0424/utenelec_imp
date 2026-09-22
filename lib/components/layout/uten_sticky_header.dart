// UtenStickyHeaderTracker - 单滚动页「表头吸顶」的量位与同帧跟手核心。
//
// 2026-09-22 从 UtenEditableGrid 的量位吸顶抽出并根治「滚动卡顿」：
// 原实现每帧 post-frame 量全局位置再 setState/写 notifier，表头覆盖层始终
// 比滚动内容**滞后一整帧**——快速滚动时吸顶表头与数据行错位抖动（用户口径
// 「动画奇奇怪怪、卡卡的」）。本核心改为两段式：
//  1. [measure]（post-frame，build/增删行/布局变化后调用）：量一次全局位置，
//     缓存「内容空间锚点」——以祖先滚动视口 pixels=0 处为原点的常量坐标
//     （滚动本身不改布局，锚点跨帧有效）；
//  2. [handleScrollTick]（祖先滚动 position 的 listener 里直接调，滚动 tick
//     **同帧**）：锚点 + 当前 pixels 纯算术得出表头位置，不访问渲染树、零延迟。
//
// 表头位置公式（与原 UtenEditableGrid._updateSticky 等价）：
//   headerY = clamp(pixels − stackTopC, 0, bodyBottomC − stackTopC − headerH)
// 自然位 0（表头在区块顶不动）；上滑顶到视口顶后钉住（= pixels − stackTopC）；
// 表体尾部把表头继续上推（pushed sticky，不悬空）。pinned = headerY > 0.5。
//
// 宿主接线（三把 GlobalKey 挂 Stack/吸顶单元/表体，覆盖层读 [headerY]）：
//   post-frame → tracker.measure()（顺带刷新 headerHeight/viewportHeight）
//   祖先滚动 listener → tracker.handleScrollTick()
//   页面滚动条门控 → tracker.pinnedSink（宿主传入的 ValueNotifier<bool>）

import 'package:flutter/material.dart';

/// 吸顶表头的量位与状态核心。三把 key 分别挂在：承载覆盖层的 Stack、吸顶单元
/// （表头行本体，流内留同高占位）、表体（其底边决定表头何时被推走）。
class UtenStickyHeaderTracker {
  UtenStickyHeaderTracker({
    required this.stackKey,
    required this.headerKey,
    required this.bodyKey,
    this.pinnedSink,
  });

  /// 承载吸顶覆盖层的 Stack（其自然顶 = 表头未吸顶时的位置）。
  final GlobalKey stackKey;

  /// 吸顶单元（表头行 + 紧贴的分隔线等）。
  final GlobalKey headerKey;

  /// 表体（底边推动表头解除吸顶）。
  final GlobalKey bodyKey;

  /// 「表头已置顶」信号（true = 已吸附视口顶，宿主拿去门控页面滚动条等）。
  /// 可空；传 null 则只维护 [headerY]。宿主 widget 参数变化时可重绑。
  ValueNotifier<bool>? pinnedSink;

  /// 表头覆盖层在 Stack 内的 local top（0=自然位）。宿主接 ValueListenableBuilder。
  final ValueNotifier<double> headerY = ValueNotifier<double>(0);

  /// 最近一次量到的吸顶单元高度（首帧 0，宿主占位高度用自身兜底值）。
  double get headerHeight => _headerH;
  double _headerH = 0;

  /// 最近一次量到的祖先滚动视口高度（找不到视口时保持 null）。
  double? get viewportHeight => _viewportH;
  double? _viewportH;

  /// 内容空间锚点（以祖先滚动视口 pixels=0 处为原点）：Stack 顶、表体底。
  double? _stackTopC;
  double? _bodyBottomC;
  ScrollPosition? _position;

  bool get isPinned => headerY.value > 0.5;

  /// 量位（post-frame 调用）。返回是否找到祖先滚动视口——false（弹窗定高盒/
  /// 首帧前）时属自然布局：清锚点、表头回自然位，宿主不必吸顶。
  bool measure() {
    final stackCtx = stackKey.currentContext;
    final headerCtx = headerKey.currentContext;
    final bodyCtx = bodyKey.currentContext;
    final stackBox = stackCtx?.findRenderObject() as RenderBox?;
    final headerBox = headerCtx?.findRenderObject() as RenderBox?;
    final bodyBox = bodyCtx?.findRenderObject() as RenderBox?;
    if (stackBox == null ||
        !stackBox.attached ||
        headerBox == null ||
        !headerBox.attached ||
        bodyBox == null ||
        !bodyBox.attached) {
      return false;
    }
    // 视口 = 最近的祖先 Scrollable（单据编辑页/详情页的页面 ListView）。
    final scrollable = Scrollable.maybeOf(stackCtx!);
    final vpBox = scrollable?.context.findRenderObject() as RenderBox?;
    if (scrollable == null ||
        vpBox == null ||
        !vpBox.attached ||
        !vpBox.hasSize) {
      _reset();
      return false;
    }
    // 全部相对视口量（localToGlobal 带 ancestor）：不带 ancestor 得到的是窗口
    // 坐标，根部整体缩放(UtenDisplayZoomBox)时与视口的画布尺寸相差 zoom 倍。
    final pixels = scrollable.position.hasPixels
        ? scrollable.position.pixels
        : 0.0;
    _stackTopC =
        stackBox.localToGlobal(Offset.zero, ancestor: vpBox).dy + pixels;
    _bodyBottomC =
        bodyBox.localToGlobal(Offset.zero, ancestor: vpBox).dy +
        bodyBox.size.height +
        pixels;
    _headerH = headerBox.size.height;
    _viewportH = vpBox.size.height;
    _position = scrollable.position;
    _apply(pixels);
    return true;
  }

  /// 滚动 tick 同帧快路径：锚点 + 当前 pixels 纯算术。锚点未就绪时 no-op
  /// （等下一次 post-frame [measure] 建锚）。
  void handleScrollTick() {
    final pos = _position;
    final stackTopC = _stackTopC;
    if (pos == null ||
        !pos.hasPixels ||
        !pos.hasViewportDimension ||
        stackTopC == null ||
        _bodyBottomC == null) {
      return;
    }
    _apply(pos.pixels);
  }

  /// 锚点失效（视口消失/键未挂载）：表头回自然位、撤 pinned。
  void _reset() {
    _stackTopC = null;
    _bodyBottomC = null;
    _position = null;
    _apply(0);
  }

  void _apply(double pixels) {
    final stackTopC = _stackTopC;
    final bodyBottomC = _bodyBottomC;
    if (stackTopC == null || bodyBottomC == null) {
      if (headerY.value != 0) headerY.value = 0;
      _publishPinned(false);
      return;
    }
    final maxTop = bodyBottomC - stackTopC - _headerH;
    var y = pixels - stackTopC;
    if (y < 0) y = 0;
    if (maxTop < 0) {
      y = 0;
    } else if (y > maxTop) {
      y = maxTop;
    }
    if (headerY.value != y) headerY.value = y;
    _publishPinned(y > 0.5);
  }

  void _publishPinned(bool value) {
    final sink = pinnedSink;
    if (sink != null && sink.value != value) sink.value = value;
  }

  /// 宿主 dispose 时一并释放（headerY 有监听者时不释放会漏）。
  void dispose() {
    headerY.dispose();
  }
}
