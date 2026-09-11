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

import 'dart:math' as math;

import 'package:flutter/material.dart';

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
    this.floatHeaderSlivers = false,
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

  /// 是否在向下滚时优先让 header 浮回（floating）。默认 false = 平滑跟手：先把 body
  /// 回顶，再把 header 拉回（非吸附）。
  final bool floatHeaderSlivers;

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

class _UtenCollapsingHeaderScrollViewState
    extends State<UtenCollapsingHeaderScrollView> {
  /// 检测到「body 被头部挤扁」的视口尺寸（null = 未挤扁）。
  ///
  /// NestedScrollView 的 body 高 = 视口高 − 头部滚动高度：头部一高（信息卡 + 附件区 +
  /// 放大字号），body 就只剩几十像素甚至 0，表格固定件溢出/整块不可达
  /// （2026-09-11 钱流/销售详情 1280x900 + 字号 1.5 复现）。挤扁一次后本视口尺寸下
  /// 改走整页滚动回退；视口尺寸变化（窗口缩放/转屏）时重试联动模式。
  Size? _squeezedViewport;

  void _reportSqueezed(Size viewport) {
    if (_squeezedViewport == viewport) return;
    // 量到挤扁时正处在布局中，推迟到帧末再切换布局分支。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _squeezedViewport == viewport) return;
      setState(() => _squeezedViewport = viewport);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        // 有吸顶头（TabBar 三段式）的页面保持 NestedScrollView 联动：其顶部是横幅
        // 而非拉长的信息卡，且「横幅滚走→Tab 吸顶→面板内滚」的时序依赖外内协调。
        final canFallBack =
            widget.pinnedHeader == null && constraints.hasBoundedHeight;
        final smallViewport =
            constraints.maxWidth < widget.compactBreakpoint ||
            constraints.maxHeight < widget.compactHeightBreakpoint;
        if (canFallBack && (smallViewport || _squeezedViewport == viewport)) {
          return _CompactPageScroll(
            viewportHeight: constraints.maxHeight,
            collapsingHeader: widget.collapsingHeader,
            pinnedHeader: widget.pinnedHeader,
            pinnedHeaderExtent: widget.pinnedHeaderExtent,
            controller: widget.controller,
            bodyMinHeight: widget.compactBodyMinHeight,
            body: widget.body,
          );
        }
        return NestedScrollView(
          controller: widget.controller,
          floatHeaderSlivers: widget.floatHeaderSlivers,
          headerSliverBuilder: (BuildContext context, bool innerBoxIsScrolled) {
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
          body: canFallBack
              ? _SqueezeGuard(
                  viewport: viewport,
                  minHeight: widget.compactBodyMinHeight,
                  onSqueezed: _reportSqueezed,
                  child: widget.body,
                )
              : widget.body,
        );
      },
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
    this.collapsingHeader,
    this.pinnedHeader,
    this.pinnedHeaderExtent,
    this.controller,
  });

  final double viewportHeight;
  final Widget body;
  final double bodyMinHeight;
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
