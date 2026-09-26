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

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  /// 表头置顶所需的祖先页面滚动量（= Stack 顶在内容空间的锚点）。
  /// 量位前为 null；[UtenStickyWheelGate] 据此把越点滚轮截停在置顶点上。
  double? get pinOffset => _stackTopC;

  /// 祖先页面滚动的 position（量位成功后非空；无祖先滚动/键未挂载时为 null）。
  ScrollPosition? get pagePosition => _position;

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

/// 吸顶表的滚轮截停门（2026-09-25 用户口径「滚一下没停就置顶了 → 停在置顶点，
/// 停住重新开始滚才继续」）。
///
/// 单滚动页（embedded 明细表/编辑网格随页面 ListView 滚）的吸顶表头只有一个
/// 滚动位：滚轮一格跨过置顶点时，惯性/连续快滚会一口气冲进表体深处，用户想看
/// 最顶上的内容容易错失。本门挂在表格子树内（命中序在祖先页面 Scrollable 之前，
/// 经 pointerSignalResolver 先注册先得），规则：
///  - 一格会越过置顶点 → 正好停在点上，余量丢弃，开「停顿窗」；
///  - 停顿窗内同方向的后续格（同一滚势的连续快滚/惯性）整格吞掉并续窗——
///    「滚一下」算一次手势，到点必须停；
///  - 停顿窗有两条放行线，先到先放：①滚势停下（[holdWindow] 内无新格）；②没停
///    但一直同方向滚 = 明确要继续，累计推过量达到 [holdDistance] 即放行（放行那
///    格正常滚）——连续滚不停的用户不会卡死在置顶点；
///  - 置顶点还够不着（短表：页面余量不足，头怎么滚都差一点）→ 通知宿主撑高
///    表体（[onEngage]，extra=0 先按公式，仍不够再按实测量补差），撑完把本次
///    滚动意图投到置顶点为止；
///  - shift+滚轮（横滚修饰键）不接管；[PointerScrollInertiaCancelEvent]（用户
///    重新触碰滚轮/触控板）立即关窗。
///
/// 更深的独立竖向滚动件天然优先（resolver 先注册先得，本门不抢）；触屏拖动与
/// 滚动条拖拽不经本门，保持直接操纵手感。
class UtenStickyWheelGate extends StatefulWidget {
  const UtenStickyWheelGate({
    super.key,
    required this.tracker,
    required this.onEngage,
    required this.child,
    this.holdWindow = const Duration(milliseconds: 350),
    this.holdDistance = 250,
  });

  /// 吸顶核心（[UtenStickyHeaderTracker.pinOffset]/[pagePosition] 的来源）。
  final UtenStickyHeaderTracker tracker;

  /// 「置顶点够不着，请求撑高」回调。参数为追加的撑高像素：0 = 先按宿主公式
  /// 撑；>0 = 公式撑过后仍差的部分（按实测量补差）。宿主在其内 setState。
  final ValueChanged<double> onEngage;

  /// 被包裹的表格子树（Listener 需覆盖表格全区——含短表下方的空白撑高区）。
  final Widget child;

  /// 停顿窗长度：截停后距上一格滚轮不超过该窗口的同方向格视为同一滚势，吞掉。
  /// 默认 350ms：快滚连击 10-60ms/格、慢滚一档 ~150-300ms，人手刻意的新一滚
  /// 之间至少停半秒。
  final Duration holdWindow;

  /// 停顿窗的距离放行线（逻辑像素）：截停后同方向累计推过的滚轮量达到该值也
  /// 放行（滚不停的用户 = 明确要继续）。默认 250 ≈ 两格半滚轮（本机一格 ≈100，
  /// 交接空行程 50=半格的同一标定）：典型一甩的余势（1-2 格）整段吞掉，持续
  /// 连滚第 2-3 格恢复跟手。
  final double holdDistance;

  @override
  State<UtenStickyWheelGate> createState() => _UtenStickyWheelGateState();
}

class _UtenStickyWheelGateState extends State<UtenStickyWheelGate> {
  static const double _epsilon = 0.5;

  /// 停顿窗内被吞的滚势方向（1=向置顶；0=窗关）。
  int _holdDirection = 0;

  /// 停顿窗内同方向累计已吞的滚轮量（达到 [UtenStickyWheelGate.holdDistance] 放行）。
  double _holdConsumed = 0;
  Timer? _holdTimer;

  @override
  void dispose() {
    _releaseHold();
    super.dispose();
  }

  /// 截停点上开新窗：距离计量从零起算。
  void _armHold(int direction) {
    _holdDirection = direction;
    _holdConsumed = 0;
    _keepHold();
  }

  /// 续窗（只刷新计时，不动距离计量）。
  void _keepHold() {
    _holdTimer?.cancel();
    _holdTimer = Timer(widget.holdWindow, _releaseHold);
  }

  void _releaseHold() {
    _holdDirection = 0;
    _holdConsumed = 0;
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollInertiaCancelEvent) {
      // 用户重新触碰了滚轮/触控板：上一滚势作废，立即关窗。
      _releaseHold();
      return;
    }
    if (event is! PointerScrollEvent) return;
    final dy = event.scrollDelta.dy;
    if (dy == 0) return;
    // shift+滚轮是横滚（ScrollBehavior.pointerAxisModifiers），交给横向滚动件。
    final modifiers = ScrollConfiguration.of(context).pointerAxisModifiers;
    if (HardwareKeyboard.instance.logicalKeysPressed.any(modifiers.contains)) {
      return;
    }
    // 本门只管「滚向置顶」方向；反向是明确意图，关窗放行。
    if (dy < 0) {
      _releaseHold();
      return;
    }
    final position = widget.tracker.pagePosition;
    final pin = widget.tracker.pinOffset;
    if (position == null ||
        pin == null ||
        !position.hasPixels ||
        !position.hasContentDimensions) {
      return;
    }
    if (_holdDirection > 0) {
      // 同一滚势的后续格：吞掉并续窗；累计推过量达到距离放行线则关窗、这格
      // 放行（不 register → 页面正常滚过置顶点）。截停点恰在 pin 上，此检查
      // 必须在「已在置顶点」放行之前——否则停顿窗形同虚设。
      _holdConsumed += dy;
      if (_holdConsumed < widget.holdDistance) {
        _keepHold();
        GestureBinding.instance.pointerSignalResolver.register(event, (_) {});
      } else {
        _releaseHold();
      }
      return;
    }
    if (position.pixels >= pin - _epsilon) {
      // 已在/已过置顶点（停顿窗已过期或从未截停）：放行，正常继续滚表体。
      return;
    }
    final reachable = pin <= position.maxScrollExtent + _epsilon;
    if (reachable) {
      if (dy >= pin - position.pixels) {
        // 这一格会越过置顶点：正好停在点上，余量丢弃，开停顿窗。
        GestureBinding.instance.pointerSignalResolver.register(event, (_) {
          _clampToPin();
        });
      }
      return;
    }
    // 置顶点够不着（短表）：这一格会顶到页面尽头 → 请求撑高后把滚动意图投到点。
    final atEnd =
        position.pixels >= position.maxScrollExtent - _epsilon ||
        position.pixels + dy >= position.maxScrollExtent - _epsilon;
    if (atEnd) {
      GestureBinding.instance.pointerSignalResolver.register(
        event,
        (_) => _engageAndPush(dy, 0),
      );
    }
  }

  void _clampToPin() {
    final position = widget.tracker.pagePosition;
    final pin = widget.tracker.pinOffset;
    if (position == null ||
        pin == null ||
        !position.hasPixels ||
        !position.hasContentDimensions) {
      return;
    }
    if (position.pixels >= pin - _epsilon) return;
    position.jumpTo(math.min(pin, position.maxScrollExtent));
    _armHold(1);
  }

  /// 置顶点够不着：先按宿主公式撑高（extra=0），post-frame 复查仍差则按实测量
  /// 补差再撑一次，最后把本次滚动意图投到「刚好置顶」为止。两轮仍够不着（异常
  /// 布局）即放弃，不再追（避免无限撑高）。
  void _engageAndPush(double dy, int attempt) {
    widget.onEngage(0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.tracker.measure();
      final position = widget.tracker.pagePosition;
      final pin = widget.tracker.pinOffset;
      if (position == null ||
          pin == null ||
          !position.hasPixels ||
          !position.hasContentDimensions) {
        return;
      }
      if (pin <= position.maxScrollExtent + _epsilon) {
        final target = math.min(pin, position.pixels + dy);
        position.jumpTo(
          math.max(0.0, math.min(target, position.maxScrollExtent)),
        );
        if (target >= pin - _epsilon) _armHold(1);
        return;
      }
      if (attempt >= 1) return;
      widget.onEngage(pin - position.maxScrollExtent + 24);
      _landAfterExtraEngage(dy);
    });
  }

  void _landAfterExtraEngage(double dy) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.tracker.measure();
      final position = widget.tracker.pagePosition;
      final pin = widget.tracker.pinOffset;
      if (position == null ||
          pin == null ||
          !position.hasPixels ||
          !position.hasContentDimensions) {
        return;
      }
      final target = math.min(pin, position.pixels + dy);
      position.jumpTo(
        math.max(0.0, math.min(target, position.maxScrollExtent)),
      );
      if (target >= pin - _epsilon) _armHold(1);
    });
  }

  @override
  Widget build(BuildContext context) {
    // opaque：短表撑高后的空白区也要进命中链——用户常对着表格下方空白滚向置顶。
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: _onPointerSignal,
      child: widget.child,
    );
  }
}
