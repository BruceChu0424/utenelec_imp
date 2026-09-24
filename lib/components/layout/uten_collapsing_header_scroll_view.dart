// UtenCollapsingHeaderScrollView - 大屏列表页「顶部可折叠 + 表格吸顶内滚」联动滚动容器。
//
// 解决：主档/报表页顶部固定区（分类卡、筛选条等）挤压表格纵向空间。本组件把「会滚走的
// 顶部」放进 collapsingHeader，外层 NestedScrollView 协调：向上滚先把 collapsingHeader 收完，
// 再滚 body 内部；反向先把 body 回顶，再把 collapsingHeader 拉回原位。手感默认平滑跟手
// （floatHeaderSlivers:false）。
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
// compactHeightBreakpoint（均默认 600）时不用 NestedScrollView——它的 body 只有
// 「视口高 − 顶部高」，手机竖屏/横屏上会被压到表格固定件（工具条/表头/分页）纵向溢出。
// 回退为「整页滚 + body 定高内滚」，见 compactBreakpoint/compactHeightBreakpoint 文档。
//
// 滚动条口径（2026-09-14）：本容器向子树注入 UtenInnerScrollActiveScope（外层头部
// 是否收完）。表格上滑置顶之前不显示上下滚动条，进入表体内滚后再显示（显示的是
// 表格自带的表内滚动条，大小与表内容对应）。紧凑回退分支复用同一外层控制器，
// 「收完」= 整页滚到底（表格盒占满视口）。
//
// 滚轮交接手感（2026-09-22 用户口径「表格置顶后得再滑一点点距离才开始动表内；往下
// 也一样」）：NestedScrollView 原生把一格滚轮拆给外层和内层——收完头部剩下的余量
// 当场就滚进表内，表格刚置顶第一行就没了；反向亦然，表内一回顶头部立刻被拉下来，
// 「看不到最前面的内容」。本组件在 NestedScrollView 上盖一层透明 Listener 先拿到
// 滚轮（命中序在内外 Scrollable 之前），自己决定怎么给：
//  - 一格滚到「刚好置顶」/「刚好回顶」即止，余量丢弃；
//  - 越过交接点之后，同方向还要再滚 [wheelGateDistance] 的空行程才开始动另一段，
//    掉头即撤门（反向是明确意图，不吃空行程）；
//  - 命中点下若有**独立**（非联动）的竖向滚动件且还能滚（页内侧栏、嵌套面板），
//    让给框架原样处理，不抢；shift+滚轮（横滚修饰键）也不接管；
//  - 只管滚轮 / 触控板；触屏拖动仍由 NestedScrollView 原生协调。
//
// 卡顿本身（「表格一步步往置顶移动时一卡一卡」）的根因在 NestedScrollView 的 body
// 每格都在变高，见 MasterDataTableView 表体 LayoutBuilder 的「只按宽度重建」。

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../core/responsive/breakpoint.dart';

/// 联动折叠容器：向上滚先把 [collapsingHeader] 收完，再滚 [body] 内部；反向先把 [body]
/// 回顶，再把 [collapsingHeader] 拉回。基于 [NestedScrollView]。
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
    this.compactBreakpoint = UtenBreakpoints.mediumStart,
    this.compactHeightBreakpoint = UtenBreakpoints.mediumStart,
    this.compactBodyMinHeight = 360,
  }) : assert(
         pinnedHeader == null || pinnedHeaderExtent != null,
         'UtenCollapsingHeaderScrollView: pinnedHeaderExtent 必须随 pinnedHeader 一起提供。',
       );

  /// 滚动主体。须含一个拾取 PrimaryScrollController 的竖向可滚动件
  /// （MasterDataTableView(primary:true) 或 ListView(primary:true)）。
  final Widget body;

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

  /// 紧凑视口回退阈值（默认 [UtenBreakpoints.mediumStart] = 600，即手机竖屏）：视口宽
  /// 小于该值时不再用 NestedScrollView——其 body 高度 = 视口高 − 顶部内容高，手机上
  /// 表头信息卡单列拉长后 body 只剩几十像素，表格固定件（工具条/表头/分页）直接
  /// 纵向溢出（2026-09-10 采购详情 375 宽复现）。回退为「整页滚动 + body 定高内滚」：
  /// 顶部随页滚走，body 以 max([compactBodyMinHeight], 视口高 − 吸顶头高 − 48) 定高，
  /// 内部可滚动件仍拾取本组件注入的 PrimaryScrollController。传了 [pinnedHeader]
  /// 的三段式页面不回退（横幅短、时序依赖外内协调）。
  final double compactBreakpoint;

  /// 矮视口回退阈值（默认 600）：视口**高**小于该值时同样走紧凑回退。
  /// 2026-09-11 手机横屏（844x390 + 字号 1.5）复现：宽度够（不触发 [compactBreakpoint]），
  /// 但 NestedScrollView 的 body 只剩 ~250px，头部收完后表格固定件（工具条/表头/分页）
  /// 仍溢出 19px。矮视口下「整页滚 + body 定高（≥[compactBodyMinHeight]）」才装得下。
  final double compactHeightBreakpoint;

  /// 紧凑回退时 body 的最小高度（默认 360：足够容纳表格工具条三行 + 表头 + 若干行 + 分页）。
  final double compactBodyMinHeight;

  @override
  State<UtenCollapsingHeaderScrollView> createState() =>
      _UtenCollapsingHeaderScrollViewState();
}

/// 外层折叠头部「已收完」的阶段信号（true = 表格已吸顶、body 内滚生效）。
///
/// 2026-09-14 用户口径（全站滚动条统一）：表格上滑置顶之前（外层收头部阶段）
/// 不显示上下滚动条；等滚动进入表格内部后再显示，且滚动条与表体内容对应
/// （显示的就是 MasterDataTableView 自带的表内竖向滚动条）。本容器跟踪外层
/// 位置：pixels 到达 maxScrollExtent（或外层本无可滚量）即视为内滚阶段。
/// MasterDataTableView 经 [maybeOf] 读取并门控其竖向滚动条显隐；不在本容器
/// 内的表格查不到 scope，滚动条维持常显（无外滚阶段可言）。
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
  /// 检测到「body 被头部挤扁」的视口尺寸（null = 未挤扁）。
  ///
  /// NestedScrollView 的 body 高 = 视口高 − 头部滚动高度：头部一高（信息卡 + 附件区 +
  /// 放大字号），body 就只剩几十像素甚至 0，表格固定件溢出/整块不可达
  /// （2026-09-11 钱流/销售详情 1280x900 + 字号 1.5 复现）。挤扁一次后本视口尺寸下
  /// 改走整页滚动回退；视口尺寸变化（窗口缩放/转屏）时重试联动模式。
  Size? _squeezedViewport;

  /// 外层头部是否已收完（内滚阶段）。默认 true：外层无可滚量（无折叠头/头部本就
  /// 装得下）的页面没有「外滚阶段」，表内滚动条应常显。
  final ValueNotifier<bool> _innerActive = ValueNotifier<bool>(true);

  /// 页面未传 [UtenCollapsingHeaderScrollView.controller] 时自建的外层控制器。
  /// 无论用谁的控制器，都挂监听跟踪「外层收完」；紧凑回退的整页 CustomScrollView
  /// 复用同一控制器，切换分支不断跟踪。
  late final ScrollController _ownedOuter = ScrollController();
  ScrollController get _outer => widget.controller ?? _ownedOuter;

  /// NestedScrollView 注入给 body 的 inner controller（body 里 primary 可滚动件
  /// 挂在它上面）。建 body 时记下，滚轮门要读表内位置。
  ///
  /// 紧凑回退分支同样上报：整页 CustomScrollView 的 inner 是 [_CompactPageScroll]
  /// 自建的控制器（联动协调器不存在，滚轮门要把「页到顶后的余量」直接交给它）。
  ScrollController? _innerController;

  /// 当前是否处于紧凑回退分支（整页滚 + body 定高内滚）。滚轮门的余量去向
  /// 两分支不同：联动分支 outer.pointerScroll 会经协调器转投表内；紧凑分支的
  /// outer 是普通页面滚动，到顶即钳住，余量必须显式交给 inner。
  bool _compactMode = false;

  /// 滚轮门状态：方向（+1 收头部 / 表内下翻，-1 表内回顶 / 放头部；0 未上门）
  /// 与剩余空行程。
  int _gateDirection = 0;
  double _gateBudget = 0;

  static const double _epsilon = 0.5;

  @override
  void initState() {
    super.initState();
    _outer.addListener(_evaluateOuterPhase);
  }

  @override
  void didUpdateWidget(covariant UtenCollapsingHeaderScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _ownedOuter).removeListener(_evaluateOuterPhase);
      _outer.addListener(_evaluateOuterPhase);
      _innerActive.value = true;
      _scheduleOuterPhaseEval();
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_evaluateOuterPhase);
    _innerActive.dispose();
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

  void _reportSqueezed(Size viewport) {
    if (_squeezedViewport == viewport) return;
    // 量到挤扁时正处在布局中，推迟到帧末再切换布局分支。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _squeezedViewport == viewport) return;
      setState(() => _squeezedViewport = viewport);
      _scheduleOuterPhaseEval();
    });
  }

  // ------------------------- 滚轮交接门 -------------------------

  void _onPointerSignal(PointerSignalEvent event) {
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
  /// < 0 = 内容下移（先表内回顶，再放头部）。非交接段照常交给 NestedScrollView
  /// 协调器（它自己会把头部收完的部分给表内、表内回顶的部分给头部——所以交接
  /// 那一格必须在这里先截住）。
  void _applyWheel(double delta) {
    if (!_outer.hasClients) return;
    final outer = _outer.position;
    final direction = delta > 0 ? 1 : -1;
    // 掉头是明确意图：撤门，不吃空行程。
    if (_gateDirection != 0 && _gateDirection != direction) _disarm();
    final outerRoom = outer.maxScrollExtent - outer.pixels;
    final innerRoom = _innerScrolledExtent();
    if (direction > 0) {
      if (outerRoom > _epsilon) {
        // 收头部段：这一格最多滚到「刚好置顶」，余量丢弃并上门。
        if (delta >= outerRoom - _epsilon) {
          _outer.jumpTo(outer.maxScrollExtent);
          _arm(direction);
          return;
        }
        outer.pointerScroll(delta);
        return;
      }
      // 已经在表内滚了（触屏拖过 / 拖过滚动条），门失效。
      if (innerRoom > _epsilon) _disarm();
      final rest = _consumeGate(direction, delta);
      if (rest > 0) {
        if (_compactMode) {
          // 紧凑回退：outer 是普通页面滚动、到顶即钳住；大字号把桌面端也压进
          // 这个分支（2026-09-24 用户口径「字体放大后表格不会滑到顶」），余量
          // 必须显式交给表内，否则滚轮在页到顶后全部变成无效滚动。
          for (final position in _innerController?.positions ??
              const <ScrollPosition>[]) {
            if (position.hasPixels && position.hasContentDimensions) {
              position.pointerScroll(rest);
            }
          }
        } else {
          outer.pointerScroll(rest);
        }
      }
      return;
    }
    if (innerRoom > _epsilon) {
      // 表内回顶段：这一格最多滚到「刚好回顶」，余量丢弃并上门。
      if (-delta >= innerRoom - _epsilon) {
        for (final position in _innerController!.positions) {
          position.jumpTo(position.minScrollExtent);
        }
        _arm(direction);
        return;
      }
      if (_compactMode) {
        // 紧凑回退：先收表内（联动分支里 outer.pointerScroll 的负向余量经协调器
        // 正是先回表内再放头部；紧凑分支的 outer 是普通页面滚动，必须显式先滚
        // 表内，否则头部先回来、表内停在半途）。
        for (final position in _innerController?.positions ??
            const <ScrollPosition>[]) {
          if (position.hasPixels && position.hasContentDimensions) {
            position.pointerScroll(delta);
          }
        }
      } else {
        outer.pointerScroll(delta);
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
    return UtenInnerScrollActiveScope(
      active: _innerActive,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewport = Size(constraints.maxWidth, constraints.maxHeight);
          // 有吸顶头（TabBar 三段式）的页面保持 NestedScrollView 联动：其顶部是横幅
          // 而非拉长的信息卡，且「横幅滚走→Tab 吸顶→面板内滚」的时序依赖外内协调。
          final canFallBack =
              widget.pinnedHeader == null && constraints.hasBoundedHeight;
          final smallViewport =
              constraints.maxWidth < widget.compactBreakpoint ||
              constraints.maxHeight < widget.compactHeightBreakpoint;
          // 滚轮交接门两分支都要在（2026-09-24）：紧凑分支此前没有这层 Listener，
          // 滚轮直接被表内 Scrollable 吃掉——先滚表内、头部永不收起，大字号把
          // 桌面端压进紧凑分支后用户口径「表格不会滑到顶」即此。
          _compactMode = canFallBack &&
              (smallViewport || _squeezedViewport == viewport);
          final Widget content;
          if (_compactMode) {
            content = _CompactPageScroll(
              viewportHeight: constraints.maxHeight,
              collapsingHeader: widget.collapsingHeader,
              pinnedHeader: widget.pinnedHeader,
              pinnedHeaderExtent: widget.pinnedHeaderExtent,
              controller: _outer,
              bodyMinHeight: widget.compactBodyMinHeight,
              onInnerController: (controller) =>
                  _innerController = controller,
              body: widget.body,
            );
          } else {
            final body = canFallBack
                ? _SqueezeGuard(
                    viewport: viewport,
                    minHeight: widget.compactBodyMinHeight,
                    onSqueezed: _reportSqueezed,
                    child: widget.body,
                  )
                : widget.body;
            content = NestedScrollView(
              controller: _outer,
              headerSliverBuilder:
                  (BuildContext context, bool innerBoxIsScrolled) {
                    return <Widget>[
                      if (widget.collapsingHeader != null)
                        SliverToBoxAdapter(child: widget.collapsingHeader!),
                      if (widget.pinnedHeader != null)
                        SliverPersistentHeader(
                          pinned: true,
                          delegate: _PinnedHeaderDelegate(
                            extent: widget.pinnedHeaderExtent!,
                            child: widget.pinnedHeader!,
                          ),
                        ),
                    ];
                  },
              body: Builder(
                builder: (bodyContext) {
                  // 记下 NestedScrollView 注入的 inner controller（滚轮门读表内位置）。
                  _innerController = PrimaryScrollController.maybeOf(
                    bodyContext,
                  );
                  return body;
                },
              ),
            );
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              content,
              // 滚轮交接门（见文件头）：透明覆盖层在命中序上先于内外 Scrollable
              // 拿到滚轮；不吃点击 / 拖动 / 悬停，其余指针事件原样到达下层。
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerSignal: _onPointerSignal,
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// NestedScrollView body 的「挤扁哨兵」：body 实得高度不足 [minHeight] 时不让它
/// 按扁高度布局（否则表格固定件直接纵向溢出），改为按 [minHeight] 布局 + 裁剪，
/// 同时上报宿主——下一帧切到整页滚动回退。
class _SqueezeGuard extends StatelessWidget {
  const _SqueezeGuard({
    required this.viewport,
    required this.minHeight,
    required this.onSqueezed,
    required this.child,
  });

  final Size viewport;
  final double minHeight;
  final ValueChanged<Size> onSqueezed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedHeight ||
            constraints.maxHeight >= minHeight) {
          return child;
        }
        onSqueezed(viewport);
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: minHeight,
            maxHeight: minHeight,
            child: child,
          ),
        );
      },
    );
  }
}

/// 紧凑视口回退：整页 CustomScrollView 滚动（顶部内容随页滚走、吸顶头照常钉住），
/// body 以定高盒承载并注入独立的 PrimaryScrollController，表格等 primary 可滚动件
/// 在盒内自行滚动。见 [UtenCollapsingHeaderScrollView.compactBreakpoint]。
class _CompactPageScroll extends StatefulWidget {
  const _CompactPageScroll({
    required this.viewportHeight,
    required this.body,
    required this.bodyMinHeight,
    required this.onInnerController,
    this.collapsingHeader,
    this.pinnedHeader,
    this.pinnedHeaderExtent,
    this.controller,
  });

  final double viewportHeight;
  final Widget body;
  final double bodyMinHeight;

  /// 把自建的 inner controller（body 里 primary 可滚动件挂在它上面）上报给宿主
  /// ——滚轮交接门在紧凑分支要把「页到顶后的余量」直接交给它。
  final ValueChanged<ScrollController> onInnerController;
  final Widget? collapsingHeader;
  final Widget? pinnedHeader;
  final double? pinnedHeaderExtent;
  final ScrollController? controller;

  @override
  State<_CompactPageScroll> createState() => _CompactPageScrollState();
}

class _CompactPageScrollState extends State<_CompactPageScroll> {
  final ScrollController _inner = ScrollController();

  @override
  void dispose() {
    _inner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 上报 inner controller（幂等）：宿主的滚轮门要读表内位置/直接驱动表内。
    widget.onInnerController(_inner);
    // 顶部滚走后 body 几乎占满视口；预留 48 给页面自身的边距/底栏呼吸空间。
    final bodyHeight = math.max(
      widget.bodyMinHeight,
      widget.viewportHeight - (widget.pinnedHeaderExtent ?? 0) - 48,
    );
    return CustomScrollView(
      controller: widget.controller,
      primary: false,
      slivers: [
        if (widget.collapsingHeader != null)
          SliverToBoxAdapter(child: widget.collapsingHeader!),
        if (widget.pinnedHeader != null)
          SliverPersistentHeader(
            pinned: true,
            delegate: _PinnedHeaderDelegate(
              extent: widget.pinnedHeaderExtent!,
              child: widget.pinnedHeader!,
            ),
          ),
        SliverToBoxAdapter(
          child: SizedBox(
            height: bodyHeight,
            child: PrimaryScrollController(
              controller: _inner,
              child: widget.body,
            ),
          ),
        ),
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
