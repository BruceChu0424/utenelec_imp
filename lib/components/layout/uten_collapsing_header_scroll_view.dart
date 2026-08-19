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

import 'package:flutter/material.dart';

/// 联动折叠容器：向上滚先把 [collapsingHeader] 收完，再滚 [body] 内部；反向先把 [body]
/// 回顶，再把 [collapsingHeader] 拉回。基于 [NestedScrollView]。
///
/// [collapsingHeader] 随上滚收起、随下滚拉回（SliverToBoxAdapter）。
/// [pinnedHeader] 非空时在 [collapsingHeader] 之下渲染、滚到视口上沿后吸顶
/// （SliverPersistentHeader pinned），[pinnedHeaderExtent] 为吸顶头高度。
/// [body] 是滚动主体；其中「想吸顶保留」的内容放在可滚动件之上的 Column 兄弟位即可。
/// 可滚动件须拾取注入的 PrimaryScrollController（MasterDataTableView 传 primary:true）。
class UtenCollapsingHeaderScrollView extends StatelessWidget {
  const UtenCollapsingHeaderScrollView({
    super.key,
    required this.body,
    this.collapsingHeader,
    this.pinnedHeader,
    this.pinnedHeaderExtent,
    this.controller,
    this.floatHeaderSlivers = false,
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

  @override
  Widget build(BuildContext context) {
    return NestedScrollView(
      controller: controller,
      floatHeaderSlivers: floatHeaderSlivers,
      headerSliverBuilder: (BuildContext context, bool innerBoxIsScrolled) {
        return <Widget>[
          if (collapsingHeader != null)
            SliverToBoxAdapter(child: collapsingHeader!),
          if (pinnedHeader != null)
            SliverPersistentHeader(
              pinned: true,
              delegate: _PinnedHeaderDelegate(
                extent: pinnedHeaderExtent!,
                child: pinnedHeader!,
              ),
            ),
        ];
      },
      body: body,
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
