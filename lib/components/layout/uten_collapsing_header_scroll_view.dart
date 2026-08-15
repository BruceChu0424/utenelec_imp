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

import 'package:flutter/material.dart';

/// 联动折叠容器：向上滚先把 [collapsingHeader] 收完，再滚 [body] 内部；反向先把 [body]
/// 回顶，再把 [collapsingHeader] 拉回。基于 [NestedScrollView]。
///
/// [collapsingHeader] 随上滚收起、随下滚拉回（SliverToBoxAdapter）。
/// [body] 是滚动主体；其中「想吸顶保留」的内容放在可滚动件之上的 Column 兄弟位即可。
/// 可滚动件须拾取注入的 PrimaryScrollController（MasterDataTableView 传 primary:true）。
class UtenCollapsingHeaderScrollView extends StatelessWidget {
  const UtenCollapsingHeaderScrollView({
    super.key,
    required this.body,
    this.collapsingHeader,
    this.controller,
    this.floatHeaderSlivers = false,
  });

  /// 滚动主体。须含一个拾取 PrimaryScrollController 的竖向可滚动件
  /// （MasterDataTableView(primary:true) 或 ListView(primary:true)）。
  final Widget body;

  /// 随滚动收起/拉回的顶部内容（如分类信息卡）。为空则只有 body。
  final Widget? collapsingHeader;

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
        ];
      },
      body: body,
    );
  }
}
