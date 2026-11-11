// UtenCollapsingHeaderScrollView - 大屏列表页「顶部可折叠 + 表格吸顶内滚」联动滚动容器。
//
// 解决：主档/报表页顶部固定区（分类卡、筛选条等）挤压表格纵向空间。本组件把「会滚走的
// 顶部」放进 collapsingHeader，保留的外层/内层视口协调：向上滚先把 collapsingHeader 收完，
// 再滚 body 内部；反向先把 body 回顶，再把 collapsingHeader 拉回原位。手感默认平滑跟手
// （外层收完后再进入表体）。
//
// 用法（以货品资料为例）：
//   UtenCollapsingHeaderScrollView(
//     collapsingHeader: MasterDetailCard(...),     // ← 分类卡，上滑收起
//     body: Column(children: [
//       Row([Text('货品 (N)'), Expanded(UtenSearchBar(...)), UtenButton('添加')]), // ← 钉在 body 顶
//       Expanded(child: MasterDataTableView<...>(..., primary: true)),            // ← 内滚
//     ]),
//   )
//
// 关键：body 里「想吸顶保留」的内容（如搜索+添加行）放在可滚动件（表格）之上、同一个 Column 里——
// 它不随表格内滚而滚（表格是 Column 里的 Expanded，搜索行是其兄弟），卡片收起后它自然顶到屏幕顶。
// body 的可滚动件须拾取注入的 PrimaryScrollController：MasterDataTableView 传 primary:true，
// 或用 ListView(primary:true)。
//
// 二级吸顶（pinnedHeader）：需要「横幅滚走 + Tab 栏吸顶 + 内容内滚」三段式层级时
// （如资产与待摊工作台），传 pinnedHeader + pinnedHeaderExtent：
//   UtenCollapsingHeaderScrollView(
//     collapsingHeader: 提示横幅区,                       // ← 上滑滚走
//     pinnedHeader: TabBar(...),                          // ← 滚到视口顶后吸顶
//     pinnedHeaderExtent: tabBar.preferredSize.height,    // ← 吸顶头高度（含自带下间距）
//     body: IndexedStack(...面板，内含 primary 可滚动件...),
//   )
// 滚动时序：先收 collapsingHeader → pinnedHeader 顶到视口上沿钉住 → 此后仅 body 内滚；
// 下滚还原顺序相反（body 先回顶 → pinnedHeader 解吸 → collapsingHeader 重新展开）。
//
// 小视口回退（窄 2026-09-10 / 矮 2026-09-11）：视口宽 < compactBreakpoint 或高 <
// compactHeightBreakpoint（均默认 600）时保持同一视口/控制器，只改正文的最小高度。
// 手机竖屏/横屏不把正文压到表格固定件（工具条/表头）以下；顶部仍随整页滚走。
// 见 compactBreakpoint/compactHeightBreakpoint 文档。
//
// 滚动条口径 (2026-10-25)：外层页面及表体超出各自视口即显示可拖动条，
// UtenInnerScrollActiveScope 只保留滚动阶段信号，不再门控表格滚动条。
// 全局行为提供普通视口滚动条，MasterDataTableView 自己提供内容覆盖层。
//
// 滚轮交接手感（2026-09-22 用户口径「表格置顶后得再滑一点点距离才开始动表内；往下
// 也一样」）：NestedScrollView 原生把一格滚轮拆给外层和内层——收完头部剩下的余量
// 当场就滚进表内，表格刚置顶第一行就没了；反向亦然，表内一回顶头部立刻被拉下来，
// 「看不到最前面的内容」。本组件在联动视口上盖一层透明 Listener 先拿到
// 滚轮（命中序在内外 Scrollable 之前），自己决定怎么给：
//  - 一格滚到「刚好置顶」/「刚好回顶」即止，余量丢弃；
//  - 越过交接点之后，同方向还要再滚 [wheelGateDistance] 的空行程才开始动另一段，
//    掉头即撤门（反向是明确意图，不吃空行程）；
//  - 停顿窗（2026-09-25 用户口径「滚一下没停就置顶了 → 停住，重新开始滚才继续」）：
//    截停在交接点后，[wheelHoldWindow] 内同方向的后续格（同一滚势的连续快滚/惯性）
//    整格吞掉并续窗——连续快滚不再「置顶后马上冲进表内」；两条放行线先到先放：
//    滚势停住（窗口内无新格），或没停但同方向累计推过量达到 [wheelHoldDistance]
//    （滚不停的人 = 明确要继续）——放行后恢复空行程门的原有行为；
//  - 命中点下若有**独立**（非联动）的竖向滚动件且还能滚（页内侧栏、嵌套面板），
//    让给框架原样处理，不抢；shift+滚轮（横滚修饰键）也不接管；
//  - 只管滚轮 / 触控板；触屏拖动由同一保留位置协调外层与内层。
//
// 正文视口不随每格外层滚动缩放；表体布局保留原有只按宽度重建的优化。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../core/responsive/breakpoint.dart';
import '../../core/responsive/compact_presentation.dart';
import '../../core/ui/capsule_nav_metrics.dart';
import 'uten_scroll_signal_scope.dart';
import 'uten_compact_linked_rail_delegate.dart';
import 'uten_scrollbar_rail_delegate.dart';

/// 联动折叠容器：向上滚先把 [collapsingHeader] 收完，再滚 [body] 内部；反向先把 [body]
/// 回顶，再把 [collapsingHeader] 拉回。所有尺寸共享同一视口与控制器拓扑。
///
/// [collapsingHeader] 随上滚收起、随下滚拉回（SliverToBoxAdapter）。
/// [pinnedHeader] 非空时在 [collapsingHeader] 之下渲染、滚到视口上沿后吸顶
/// （SliverPersistentHeader pinned），[pinnedHeaderExtent] 为吸顶头高度。
/// [body] 是滚动主体；其中「想吸顶保留」的内容放在可滚动件之上的 Column 兄弟位即可。
/// 可滚动件须拾取注入的 PrimaryScrollController（MasterDataTableView 传 primary:true）。
class UtenCollapsingHeaderScrollView extends StatefulWidget {
  const UtenCollapsingHeaderScrollView({
    super.key,
    required this.body,
    this.collapsingHeader,
    this.pinnedHeader,
    this.pinnedHeaderExtent,
    this.controller,
    this.wheelGateDistance = 50,
    this.wheelHoldWindow = const Duration(milliseconds: 350),
    this.wheelHoldDistance = 250,
    this.compactBreakpoint = UtenBreakpoints.mediumStart,
    this.compactHeightBreakpoint = UtenBreakpoints.mediumStart,
    this.compactBodyMinHeight = 360,
    this.stableBodyViewport = false,
  }) : assert(
         pinnedHeader == null || pinnedHeaderExtent != null,
         'UtenCollapsingHeaderScrollView: pinnedHeaderExtent 必须随 pinnedHeader 一起提供。',
       );

  /// 滚动主体。须含一个拾取 PrimaryScrollController 的竖向可滚动件
  /// （MasterDataTableView(primary:true) 或 ListView(primary:true)）。
  final Widget body;

  /// The shared outer viewport, independent of its retained presentation.
  static ScrollController? outerControllerOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_CollapsingOuterControllerScope>()
      ?.controller;

  /// Retained hierarchy panes keep one viewport/controller topology across
  /// height changes. Tall panes fill the remainder; short panes scroll the
  /// header away while retaining a usable body extent.
  final bool stableBodyViewport;

  /// 随滚动收起/拉回的顶部内容（如分类信息卡）。为空则只有 body。
  final Widget? collapsingHeader;

  /// 吸顶保留的头部（如 TabBar）：随 [collapsingHeader] 一起上滚，顶到视口上沿后
  /// 钉住不动，此后仅 [body] 在其下方内滚；下滚时随 [collapsingHeader] 展开而解吸。
  /// 高度由 [pinnedHeaderExtent] 给出（二者须同时提供）。
  final Widget? pinnedHeader;

  /// [pinnedHeader] 的渲染高度（含其自带上下间距）。
  final double? pinnedHeaderExtent;

  /// 可选外层 ScrollController（一般无需传）。
  final ScrollController? controller;

  /// 滚轮交接空行程（逻辑像素）：表格刚置顶 / 表内刚回顶之后，同方向再滚这么多
  /// 才开始动另一段（见文件头「滚轮交接手感」）。0 = 只丢弃交接那一格的余量，
  /// 不加空行程。默认 50 ≈ 网页端半格滚轮（Chrome 一格 100）。
  final double wheelGateDistance;

  /// 滚轮停顿窗：截停在交接点（置顶/回顶）之后，距上一格滚轮不超过该窗口的
  /// 同方向格视为**同一滚势**，整格吞掉并续窗——连续快滚一口气冲过置顶点、
  /// 「置顶后马上继续往下滑」即此截断；滚势停住（窗口内无新格）后恢复空行程门
  /// 的原有行为（见文件头「滚轮交接手感」2026-09-25 段）。
  final Duration wheelHoldWindow;

  /// 停顿窗的距离放行线（逻辑像素）：没停但一直同方向滚 = 明确要继续，截停后
  /// 同方向累计推过量达到该值即放行（放行那格走正常门逻辑）。默认 250 ≈ 两格半
  /// 滚轮（一格 ≈100 的同一标定）：典型一甩的余势（1-2 格）整段吞掉，持续连滚
  /// 第 2-3 格恢复跟手。
  final double wheelHoldDistance;

  /// 紧凑正文高度阈值（默认 [UtenBreakpoints.mediumStart] = 600，即手机竖屏）。
  /// 宽度小于该值时保留正文最小高度，防止表头信息卡单列拉长后挤压表格固定件
  /// （2026-09-10 采购详情 375 宽复现），仍使用同一外层/内层视口：
  /// 顶部随页滚走，body 以 max([compactBodyMinHeight], 视口高 − 吸顶头高 − 48) 定高，
  /// 内部可滚动件仍拾取本组件注入的 PrimaryScrollController。传了 [pinnedHeader]
  /// 的三段式页面不回退（横幅短、时序依赖外内协调）。
  final double compactBreakpoint;

  /// 矮视口回退阈值（默认 600）：视口**高**小于该值时同样走紧凑回退。
  /// 2026-09-11 手机横屏（844x390 + 字号 1.5）复现：宽度够（不触发 [compactBreakpoint]），
  /// 旧正文只剩 ~250px，头部收完后表格固定件仍溢出 19px。
  /// 矮视口下「整页滚 + body 定高（≥[compactBodyMinHeight]）」才装得下。
  final double compactHeightBreakpoint;

  /// 紧凑回退时 body 的最小高度（默认 360：足够容纳表格工具条三行 + 表头 + 若干行 + 分页）。
  final double compactBodyMinHeight;

  @override
  State<UtenCollapsingHeaderScrollView> createState() =>
      _UtenCollapsingHeaderScrollViewState();
}

/// 外层折叠头部「已收完」的阶段信号（true = 表格已吸顶、body 内滚生效）。
///
/// 保留滚动阶段信号供联动逻辑兼容；内容滚动条不再据此隐藏。
class UtenInnerScrollActiveScope extends InheritedWidget {
  const UtenInnerScrollActiveScope({
    super.key,
    required this.active,
    required super.child,
  });

  /// true = 外层头部已收完，滚动只发生在 body（表格）内部。
  final ValueNotifier<bool> active;

  /// 查找最近的阶段信号；不在 [UtenCollapsingHeaderScrollView] 内时返回 null。
  static ValueNotifier<bool>? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<UtenInnerScrollActiveScope>()
      ?.active;

  @override
  bool updateShouldNotify(UtenInnerScrollActiveScope oldWidget) =>
      oldWidget.active != active;
}

class _UtenCollapsingHeaderScrollViewState
    extends State<UtenCollapsingHeaderScrollView> {
  late final _scrollSignals = UtenScrollSignalController(
    _onPointerSignal,
    resolveRailDelegate: _railFor,
  );
  final _compactRailViewportKey = GlobalKey();
  UtenCompactLinkedRailDelegate? _compactRail;

  UtenScrollbarRailDelegate? _railFor(ScrollController source) {
    if (!mounted) return null;
    final rail = _compactRail ??= UtenCompactLinkedRailDelegate(
      _outer,
      inner: _bodyController,
      viewportKey: _compactRailViewportKey,
      isEnabled: () => mounted,
    );
    if (!rail.canBindSource(source)) return null;
    rail.bindSource(source);
    return rail.metrics == null ? null : rail;
  }

  /// 外层头部是否已收完（内滚阶段）。默认 true：外层无可滚量（无折叠头/头部本就
  /// 装得下）的页面没有「外滚阶段」，表内滚动条应常显。
  final ValueNotifier<bool> _innerActive = ValueNotifier<bool>(true);

  /// 页面未传 [UtenCollapsingHeaderScrollView.controller] 时自建的外层控制器。
  /// 无论用谁的控制器，都挂监听跟踪「外层收完」；紧凑回退的整页 CustomScrollView
  /// 复用同一控制器，切换分支不断跟踪。
  late final ScrollController _ownedOuter = ScrollController();
  ScrollController get _outer => widget.controller ?? _ownedOuter;

  // The body borrows one retained controller. Position detach is always
  // forwarded to the delegate that created it, including a caller handoff.
  final _bodyController = _BodyScrollController();
  late final _compactInner = _CompactTouchScrollController(() => _outer);
  final _headerSurfaceKey = GlobalKey();
  final _bodySurfaceKey = GlobalKey();

  /// 正文代理由同一控制器创建位置；滚轮门与响应式布局共用该位置。
  ScrollController? _innerController;

  /// The viewport topology is retained; only its extent presentation changes.
  bool? _lastPresentationCompact;
  int _viewportRevision = 0;

  /// 滚轮门状态：方向（+1 收头部 / 表内下翻，-1 表内回顶 / 放头部；0 未上门）
  /// 与剩余空行程。
  int _gateDirection = 0;
  double _gateBudget = 0;

  /// 停顿窗状态：被吞滚势的方向（0=窗关）、同方向累计已吞量（达到
  /// [widget.wheelHoldDistance] 放行）与计时器。
  int _holdDirection = 0;
  double _holdConsumed = 0;
  Timer? _holdTimer;

  static const double _epsilon = 0.5;

  @override
  void initState() {
    super.initState();
    _innerController = _bodyController;
    _outer.addListener(_evaluateOuterPhase);
  }

  @override
  void didUpdateWidget(covariant UtenCollapsingHeaderScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _ownedOuter).removeListener(_evaluateOuterPhase);
      _outer.addListener(_evaluateOuterPhase);
      _compactRail?.updateOuter(_outer);
      _innerActive.value = true;
      _scheduleOuterPhaseEval();
    }
  }

  @override
  void dispose() {
    _scrollSignals.dispose();
    _compactRail?.dispose();
    widget.controller?.removeListener(_evaluateOuterPhase);
    _holdTimer?.cancel();
    _innerActive.dispose();
    _bodyController.dispose();
    _compactInner.dispose();
    _ownedOuter.dispose();
    super.dispose();
  }

  /// 外层收完判定：pixels 贴到 maxScrollExtent（外层无可滚量同样算收完）。
  /// 联动/紧凑两分支共用——紧凑分支的「收完」= 整页滚到底（表格盒占满视口）。
  void _evaluateOuterPhase() {
    final c = _outer;
    if (!c.hasClients) return;
    final p = c.position;
    final collapsed =
        !p.hasContentDimensions ||
        p.maxScrollExtent <= 0.5 ||
        p.pixels >= p.maxScrollExtent - 0.5;
    if (_innerActive.value != collapsed) _innerActive.value = collapsed;
  }

  /// 布局后的复核：内容加载/分支切换（联动↔紧凑/挤扁回退）后外层 extent 变化，
  /// 控制器监听只覆盖滚动 tick，帧末兜底再评一次。
  void _scheduleOuterPhaseEval() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _evaluateOuterPhase();
    });
  }

  // ------------------------- 滚轮交接门 -------------------------

  void _onPointerSignal(PointerSignalEvent event) {
    // 用户重新触碰滚轮/触控板（原生惯性被打断）：上一滚势作废，立即关停顿窗。
    if (event is PointerScrollInertiaCancelEvent) {
      _dropHold();
      return;
    }
    if (event is! PointerScrollEvent || !_outer.hasClients) return;
    final dy = event.scrollDelta.dy;
    if (dy == 0) return;
    // shift+滚轮是横滚（ScrollBehavior.pointerAxisModifiers），交给横向滚动件。
    final modifiers = ScrollConfiguration.of(context).pointerAxisModifiers;
    if (HardwareKeyboard.instance.logicalKeysPressed.any(modifiers.contains)) {
      return;
    }
    // 用户口径「不管在表格内还是表格外滚，都先把表格置顶」：头部没收完之前的上滚
    // 一律归联动，不看命中点下是谁；其余情况沿命中路径看有没有独立滚动件要先滚。
    final outer = _outer.position;
    final collapsing =
        dy > 0 && outer.maxScrollExtent - outer.pixels > _epsilon;
    if (!collapsing && !_wheelBelongsToLinkedScroll(event, dy)) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) => _applyWheel(dy),
    );
  }

  /// 这格滚轮是不是联动滚动的：沿命中路径由内向外找竖向视口——先碰到联动的
  /// （外层 / inner）就接管；先碰到独立的且它还能往这个方向滚，就让给框架
  /// （页内侧栏、嵌套面板自己滚）；什么都没碰到（头部 / 空白）也接管。
  bool _wheelBelongsToLinkedScroll(PointerScrollEvent event, double dy) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, event.position, event.viewId);
    final linked = <ViewportOffset>{
      _outer.position,
      ...?_innerController?.positions,
    };
    for (final entry in result.path) {
      final target = entry.target;
      ViewportOffset? offset;
      Axis? axis;
      if (target is RenderViewportBase) {
        offset = target.offset;
        axis = target.axis;
      } else if (target is RenderEditable) {
        // 多行文本框自己能竖滚（单行的横滚，不在竖向滚轮的考虑之内）。
        offset = target.offset;
        axis = target.maxLines == 1 ? Axis.horizontal : Axis.vertical;
      } else if (target is RenderAbstractViewport) {
        // SingleChildScrollView 的视口类在 SDK 里是私有的
        // （_RenderSingleChildViewport），只能动态取它公开的 offset / axis；
        // SDK 改名就按「不认识」处理，继续向外找。
        try {
          final dynamic viewport = target;
          // ignore: avoid_dynamic_calls
          offset = viewport.offset as ViewportOffset;
          // ignore: avoid_dynamic_calls
          axis = viewport.axis as Axis;
        } on NoSuchMethodError {
          continue;
        }
      }
      if (offset == null || axis != Axis.vertical) continue;
      if (linked.contains(offset)) return true;
      if (offset is ScrollPosition &&
          offset.hasPixels &&
          offset.hasContentDimensions) {
        final next = (offset.pixels + dy).clamp(
          offset.minScrollExtent,
          offset.maxScrollExtent,
        );
        if (next != offset.pixels) return false;
      }
    }
    return true;
  }

  /// 把一格滚轮分给外层 / 表内。[delta] > 0 = 内容上移（先收头部，再表内下翻）；
  /// < 0 = 内容下移（先表内回顶，再放头部）。交接点保留第一行，
  /// 其余信号仍由唯一的外/内位置协调入口分配。
  void _applyWheel(double delta) {
    if (!_outer.hasClients) return;
    final outer = _outer.position;
    final direction = delta > 0 ? 1 : -1;
    // 停顿窗（见文件头 2026-09-25 段）：截停后同一滚势的后续格吞掉并续窗；
    // 累计推过量达到距离放行线（wheelHoldDistance）或掉头即关窗——掉头是明确
    // 意图（空行程门的原有撤门逻辑照旧），推够距离=滚不停的人明确要继续，
    // 放行那格落到下方正常门逻辑（先吃空行程再动另一段）。
    if (_holdDirection != 0) {
      if (_holdDirection != direction) {
        _dropHold();
      } else {
        _holdConsumed += delta.abs();
        if (_holdConsumed < widget.wheelHoldDistance) {
          _keepHold();
          return;
        }
        _dropHold();
      }
    }
    if (_gateDirection != 0 && _gateDirection != direction) _disarm();
    final outerRoom = outer.maxScrollExtent - outer.pixels;
    final innerRoom = _innerScrolledExtent();
    if (direction > 0) {
      if (outerRoom > _epsilon) {
        // 收头部段：这一格最多滚到「刚好置顶」，余量丢弃并上门、开停顿窗。
        if (delta >= outerRoom - _epsilon) {
          _outer.jumpTo(outer.maxScrollExtent);
          // The original nested presentation resets the body at this boundary.
          // Compact/hierarchy viewports keep an already accepted body offset
          // while their header returns and collapses again.
          if (!widget.stableBodyViewport &&
              _lastPresentationCompact == false) {
            for (final position
                in _innerController?.positions ?? const <ScrollPosition>[]) {
              if (position.hasPixels && position.hasContentDimensions) {
                position.jumpTo(position.minScrollExtent);
              }
            }
          }
          _arm(direction);
          _armHold(direction);
          return;
        }
        outer.pointerScroll(delta);
        return;
      }
      // 已经在表内滚了（触屏拖过 / 拖过滚动条），门失效。
      if (innerRoom > _epsilon) _disarm();
      final rest = _consumeGate(direction, delta);
      if (rest > 0) {
        // The retained outer viewport is bounded; hand the remaining signal
        // to the same retained primary body after the header boundary.
        for (final position
            in _innerController?.positions ?? const <ScrollPosition>[]) {
          if (position.hasPixels && position.hasContentDimensions) {
            position.pointerScroll(rest);
          }
        }
      }
      return;
    }
    if (innerRoom > _epsilon) {
      // 表内回顶段：这一格最多滚到「刚好回顶」，余量丢弃并上门、开停顿窗。
      if (-delta >= innerRoom - _epsilon) {
        for (final position in _innerController!.positions) {
          position.jumpTo(position.minScrollExtent);
        }
        _arm(direction);
        _armHold(direction);
        return;
      }
      // Return the body first; the header only reappears after its boundary.
      for (final position
          in _innerController?.positions ?? const <ScrollPosition>[]) {
        if (position.hasPixels && position.hasContentDimensions) {
          position.pointerScroll(delta);
        }
      }
      return;
    }
    // 头部已经在放了（触屏拖过），门失效。
    if (outerRoom > _epsilon) _disarm();
    final rest = _consumeGate(direction, delta);
    if (rest < 0) outer.pointerScroll(rest);
  }

  /// 表内离顶部多远（多个 inner 位置取最大；没有可内滚主体 = 0）。
  double _innerScrolledExtent() {
    final controller = _innerController;
    if (controller == null || !controller.hasClients) return 0;
    var room = 0.0;
    for (final position in controller.positions) {
      if (!position.hasPixels || !position.hasContentDimensions) continue;
      room = math.max(room, position.pixels - position.minScrollExtent);
    }
    return room;
  }

  void _arm(int direction) {
    _gateDirection = direction;
    _gateBudget = widget.wheelGateDistance;
  }

  void _disarm() {
    _gateDirection = 0;
    _gateBudget = 0;
  }

  /// 开/续停顿窗。截停点上开新窗时距离计量从零起算（[widget.wheelHoldDistance]）。
  void _armHold(int direction) {
    _holdDirection = direction;
    _holdConsumed = 0;
    _keepHold();
  }

  /// 续窗（只刷新计时，不动距离计量）。
  void _keepHold() {
    _holdTimer?.cancel();
    _holdTimer = Timer(widget.wheelHoldWindow, _dropHold);
  }

  void _dropHold() {
    _holdDirection = 0;
    _holdConsumed = 0;
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  /// 门上着且同方向：先吃空行程，返回吃剩的（0 = 这格全吃掉）。
  double _consumeGate(int direction, double delta) {
    if (_gateDirection != direction || _gateBudget <= 0) return delta;
    final take = math.min(delta.abs(), _gateBudget);
    _gateBudget -= take;
    if (_gateBudget <= 0) _disarm();
    return delta - take * direction;
  }

  @override
  Widget build(BuildContext context) {
    _scheduleOuterPhaseEval();
    return _CollapsingOuterControllerScope(
      controller: _outer,
      child: UtenScrollSignalScope(
        controller: _scrollSignals,
        child: UtenInnerScrollActiveScope(
          active: _innerActive,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // A single retained outer/inner topology owns all viewport sizes.
              final smallViewport =
                  constraints.maxWidth < widget.compactBreakpoint ||
                  constraints.maxHeight < widget.compactHeightBreakpoint;
              // 滚轮交接门两分支都要在（2026-09-24）：紧凑分支此前没有这层 Listener，
              // 滚轮直接被表内 Scrollable 吃掉——先滚表内、头部永不收起，大字号把
              // 桌面端压进紧凑分支后用户口径「表格不会滑到顶」即此。
              final presentationCompact =
                  widget.pinnedHeader == null && smallViewport;
              if (_lastPresentationCompact != null &&
                  _lastPresentationCompact != presentationCompact) {
                final revision = ++_viewportRevision;
                // Preserve the established mode-transition coordinate contract:
                // the header returns, while the body keeps its exact saved offset.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted ||
                      revision != _viewportRevision ||
                      !_outer.hasClients) {
                    return;
                  }
                  _outer.jumpTo(_outer.position.minScrollExtent);
                });
              }
              _lastPresentationCompact = presentationCompact;
              final header = widget.collapsingHeader == null
                  ? null
                  : _RetainedScrollContent(
                      key: _headerSurfaceKey,
                      child: widget.collapsingHeader!,
                    );
              final bodySurface = _RetainedScrollContent(
                key: _bodySurfaceKey,
                child: widget.body,
              );
              _bodyController.useDelegate(_compactInner);
              final content = _RetainedHeaderPageViewport(
                viewportKey: _compactRailViewportKey,
                viewportHeight: constraints.maxHeight,
                collapsingHeader: header,
                pinnedHeader: widget.pinnedHeader,
                pinnedHeaderExtent: widget.pinnedHeaderExtent,
                controller: _outer,
                bodyMinHeight: widget.compactBodyMinHeight,
                innerController: _bodyController,
                body: bodySurface,
                fillViewportHeight:
                    !widget.stableBodyViewport &&
                    (!smallViewport || widget.pinnedHeader != null),
                fillViewportRemainder:
                    widget.stableBodyViewport &&
                    constraints.maxHeight >= widget.compactHeightBreakpoint,
              );
              return NotificationListener<ScrollMetricsNotification>(
                onNotification: (_) {
                  _compactRail?.metricsChanged();
                  return false;
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    content,
                    // 滚轮交接门（见文件头）：透明覆盖层在命中序上先于内外 Scrollable
                    // 拿到滚轮；不吃点击 / 拖动 / 悬停，其余指针事件原样到达下层。
                    Positioned.fill(
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerSignal: _scrollSignals.dispatch,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CollapsingOuterControllerScope extends InheritedWidget {
  const _CollapsingOuterControllerScope({
    required this.controller,
    required super.child,
  });
  final ScrollController controller;
  @override
  bool updateShouldNotify(_CollapsingOuterControllerScope oldWidget) =>
      controller != oldWidget.controller;
}

/// Retains the compact layout's generous body height while giving touch drags
/// the same outer-first order as the nested desktop viewport. Only the primary
/// body borrows this controller; horizontal tables, editors and local panels
/// keep their native recognizers and positions.
class _CompactTouchScrollController extends ScrollController {
  _CompactTouchScrollController(this.outer);
  final ScrollController Function() outer;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _CompactTouchScrollPosition(
    physics: AlwaysScrollableScrollPhysics(parent: physics),
    context: context,
    oldPosition: oldPosition,
    outer: outer,
  );
}

class _CompactTouchScrollPosition extends ScrollPositionWithSingleContext {
  _CompactTouchScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.outer,
  });
  final ScrollController Function() outer;

  @override
  void goBallistic(double velocity) {
    final controller = outer();
    if (velocity == 0 ||
        !controller.hasClients ||
        !controller.position.hasContentDimensions ||
        !hasContentDimensions) {
      super.goBallistic(velocity);
      return;
    }
    final page = controller.position;
    final metrics = FixedScrollMetrics(
      minScrollExtent: page.minScrollExtent + minScrollExtent,
      maxScrollExtent: page.maxScrollExtent + maxScrollExtent,
      pixels: page.pixels + pixels,
      viewportDimension: page.viewportDimension,
      axisDirection: axisDirection,
      devicePixelRatio: devicePixelRatio,
    );
    final simulation = physics.createBallisticSimulation(metrics, velocity);
    if (simulation == null) {
      goIdle();
    } else {
      beginActivity(
        _CompactTouchBallisticActivity(this, simulation, context.vsync),
      );
    }
  }

  @override
  void jumpTo(double value) {
    final controller = outer();
    if (hasContentDimensions &&
        value > minScrollExtent &&
        controller.hasClients &&
        controller.position.hasContentDimensions &&
        controller.position.pixels < controller.position.maxScrollExtent) {
      controller.jumpTo(controller.position.maxScrollExtent);
    }
    super.jumpTo(value);
  }

  bool _moveCombined(double value) {
    final controller = outer();
    if (!controller.hasClients) return false;
    final page = controller.position;
    final min = page.minScrollExtent + minScrollExtent;
    final max = page.maxScrollExtent + maxScrollExtent;
    final target = value.clamp(min, max);
    final pageRange = page.maxScrollExtent - page.minScrollExtent;
    final offset = target - min;
    final pageTarget = page.minScrollExtent + offset.clamp(0.0, pageRange);
    final innerTarget =
        minScrollExtent +
        (offset - pageRange).clamp(0.0, maxScrollExtent - minScrollExtent);
    if (target < page.pixels + pixels) {
      if (innerTarget != pixels) setPixels(innerTarget);
      if (pageTarget != page.pixels) page.jumpTo(pageTarget);
    } else {
      if (pageTarget != page.pixels) page.jumpTo(pageTarget);
      if (innerTarget != pixels) setPixels(innerTarget);
    }
    return (value - target).abs() < .01;
  }

  @override
  void applyUserOffset(double delta) {
    final controller = outer();
    if (!controller.hasClients || !controller.position.hasContentDimensions) {
      super.applyUserOffset(delta);
      return;
    }
    final page = controller.position;
    // Finger up: collapse the page before advancing any rows. Finger down:
    // return the table to its first row before expanding the page header.
    var remaining = delta;
    if (delta < 0) {
      final take = math.min(
        -delta,
        math.max(0.0, page.maxScrollExtent - page.pixels),
      );
      if (take > 0) page.jumpTo(page.pixels + take);
      remaining += take;
    } else {
      final take = math.min(delta, math.max(0.0, pixels - minScrollExtent));
      if (take > 0) super.applyUserOffset(take);
      remaining -= take;
      final pageTake = math.min(
        remaining,
        math.max(0.0, page.pixels - page.minScrollExtent),
      );
      if (pageTake > 0) page.jumpTo(page.pixels - pageTake);
      remaining -= pageTake;
    }
    if (remaining != 0) super.applyUserOffset(remaining);
  }
}

class _CompactTouchBallisticActivity extends BallisticScrollActivity {
  _CompactTouchBallisticActivity(
    _CompactTouchScrollPosition position,
    Simulation simulation,
    TickerProvider vsync,
  ) : super(position, simulation, vsync, true);

  @override
  bool applyMoveTo(double value) =>
      (delegate as _CompactTouchScrollPosition)._moveCombined(value);
}

/// Retains the content's Element, IME and semantics identity between viewports.
///
/// Reattaching invalidates the whole subtree's semantics in its new viewport.
/// Clearing those nodes would replace Web input DOM while EditableText still
/// owns the same input connection and editing value.
class _RetainedScrollContent extends SingleChildRenderObjectWidget {
  const _RetainedScrollContent({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRetainedScrollContent();
}

class _RenderRetainedScrollContent extends RenderProxyBox {
  bool _needsSemanticsReattachment = false;

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    // This stable subtree moves between two independently owned viewports.
    // Keep its descendants out of either viewport's sibling-merge groups.
    config
      ..isSemanticBoundary = true
      ..explicitChildNodes = true;
  }

  @override
  void detach() {
    _needsSemanticsReattachment = true;
    super.detach();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    if (!_needsSemanticsReattachment) return;
    _needsSemanticsReattachment = false;
    // Reparented nodes must publish their new topology and geometry as well
    // as retaining their IDs. Dirty the complete attached subtree so cached
    // descendants cannot keep references to the previous viewport's merge.
    void invalidate(RenderObject node) {
      node.markNeedsSemanticsUpdate();
      node.visitChildren(invalidate);
    }

    invalidate(this);
  }
}

/// Stable controller across compact and nested body ownership. Detach always
/// belongs to the delegate that created a position, including during a mode
/// transition. Delegates are owned by their respective scroll coordinators.
class _BodyScrollController extends ScrollController {
  ScrollController? _delegate;
  final _owners = <ScrollPosition, ScrollController>{};

  void useDelegate(ScrollController delegate) => _delegate = delegate;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    final delegate = _delegate!;
    final position = delegate.createScrollPosition(
      physics,
      context,
      oldPosition,
    );
    _owners[position] = delegate;
    return position;
  }

  @override
  void attach(ScrollPosition position) {
    // Scrollable can temporarily reattach an existing foreign position before
    // its factory runs. Keep it local; a plain position must never be given to
    // the current nested delegate.
    _owners[position]?.attach(position);
    super.attach(position);
  }

  @override
  void detach(ScrollPosition position) {
    super.detach(position);
    _owners.remove(position)?.detach(position);
  }

  @override
  void dispose() {
    _owners.clear();
    super.dispose();
  }
}

/// 紧凑视口回退：整页 CustomScrollView 滚动（顶部内容随页滚走、吸顶头照常钉住），
/// body 以定高盒承载并注入独立的 PrimaryScrollController，表格等 primary 可滚动件
/// 在盒内自行滚动。见 [UtenCollapsingHeaderScrollView.compactBreakpoint]。
class _RetainedHeaderPageViewport extends StatefulWidget {
  const _RetainedHeaderPageViewport({
    required this.viewportKey,
    required this.viewportHeight,
    required this.body,
    required this.bodyMinHeight,
    required this.innerController,
    this.collapsingHeader,
    this.pinnedHeader,
    this.pinnedHeaderExtent,
    this.controller,
    this.fillViewportRemainder = false,
    this.fillViewportHeight = false,
  });

  final double viewportHeight;
  final GlobalKey viewportKey;
  final Widget body;
  final double bodyMinHeight;
  final bool fillViewportRemainder;
  final bool fillViewportHeight;

  final ScrollController innerController;
  final Widget? collapsingHeader;
  final Widget? pinnedHeader;
  final double? pinnedHeaderExtent;
  final ScrollController? controller;

  @override
  State<_RetainedHeaderPageViewport> createState() =>
      _RetainedHeaderPageViewportState();
}

class _RetainedHeaderPageViewportState
    extends State<_RetainedHeaderPageViewport> {
  @override
  Widget build(BuildContext context) {
    // 顶部滚走后 body 几乎占满视口；预留 48 给页面自身的边距/底栏呼吸空间。
    final compactPresentation = UtenCompactPresentation.of(context);
    final bodyHeight = math.max(
      widget.bodyMinHeight,
      widget.viewportHeight -
          (widget.pinnedHeaderExtent ?? 0) -
          (compactPresentation ? 0 : 48),
    );
    // compact 悬浮胶囊避让：整页滚到最底时，body 盒（含表格分页条）要能越过
    // 屏底的悬浮胶囊。非外壳内（弹窗等）查不到 scope 取 0，无多余留白。
    final capsuleOcclusion = UtenCapsuleNavScope.occlusionOf(context);
    return CustomScrollView(
      key: widget.viewportKey,
      controller: widget.controller,
      primary: false,
      slivers: [
        if (widget.collapsingHeader != null)
          SliverToBoxAdapter(
            child: PrimaryScrollController.none(
              child: widget.collapsingHeader!,
            ),
          ),
        if (widget.pinnedHeader != null)
          SliverPersistentHeader(
            pinned: true,
            delegate: _PinnedHeaderDelegate(
              extent: widget.pinnedHeaderExtent!,
              child: PrimaryScrollController.none(child: widget.pinnedHeader!),
            ),
          ),
        SliverLayoutBuilder(
          builder: (context, constraints) => SliverToBoxAdapter(
            child: SizedBox(
              height: widget.fillViewportRemainder
                  ? math.max(
                      widget.bodyMinHeight,
                      constraints.viewportMainAxisExtent -
                          constraints.precedingScrollExtent,
                    )
                  : widget.fillViewportHeight
                  ? math.max(
                      0.0,
                      constraints.viewportMainAxisExtent -
                          (widget.pinnedHeaderExtent ?? 0),
                    )
                  : bodyHeight,
              child: PrimaryScrollController(
                controller: widget.innerController,
                child: widget.body,
              ),
            ),
          ),
        ),
        if (!compactPresentation && capsuleOcclusion > 0)
          SliverPadding(padding: EdgeInsets.only(bottom: capsuleOcclusion)),
      ],
    );
  }
}

/// [UtenCollapsingHeaderScrollView.pinnedHeader] 的定高吸顶 delegate。
/// 高度恒为 [extent]（min == max），不产生拉伸/折叠动画。
class _PinnedHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedHeaderDelegate({required this.extent, required this.child});

  final double extent;
  final Widget child;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return child;
  }

  @override
  bool shouldRebuild(covariant _PinnedHeaderDelegate oldDelegate) {
    return oldDelegate.extent != extent || oldDelegate.child != child;
  }
}
