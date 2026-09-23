// UtenGridPageScrollbar - 单据编辑页竖向滚动条的门控包装。
//
// 2026-09-14 全站滚动条口径：页面主体是「表头表单 + UtenEditableGrid 明细表」的
// 编辑页，整页一条 ListView 滚动（网格表体不内滚、sticky 表头上滑吸顶）。表头
// 表单还没滚完、明细表未置顶时不显示上下滚动条；sticky 表头吸附视口顶后
// （继续滚动在观感上就是表内滚动）常显——与 UtenCollapsingHeaderScrollView +
// MasterDataTableView 经 UtenInnerScrollActiveScope 的门控口径一致。
//
// 2026-09-15 口径（滚动条贴屏幕最右缘，不随内容容器宽度漂移）：滚动条不再随
// ListView/内容容器右缘走，改为覆盖在**视口最右缘**的恒定窄条：页面内容容器
// 限宽居中（超宽屏）时滚动条仍贴屏幕右边，位置不随列宽/窗口漂移。
//
// 2026-09-22 口径收紧（用户反馈「表格向上移动过程 滚动条也在」）：撤掉此前
// 「页面滚动进行中临时亮条 600ms」的过渡反馈——未置顶阶段**一律不显示**，
// 只有 sticky 表头吸附视口顶后才出现。同日第二刀：框架 Scrollbar 换自绘
// [UtenContentScrollbar]——thumb 活动带与长度剔除底部让位空白（悬浮操作组
// clearance），滚到底 thumb 贴内容底而非视口底，且可拖、hover 高亮。
//
// 用法（pinned 与 UtenEditableGrid.stickyHeaderPinned 传同一个 notifier）：
//   final _gridPinned = ValueNotifier<bool>(false);
//   UtenGridPageScrollbar(
//     pinned: _gridPinned,
//     controller: _scrollCtl,
//     child: ListView(controller: _scrollCtl, ...),
//   )

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'uten_content_scrollbar.dart';
import 'uten_floating_action_group.dart';

class UtenGridPageScrollbar extends StatefulWidget {
  const UtenGridPageScrollbar({
    super.key,
    required this.pinned,
    required this.controller,
    required this.child,
    this.extraPinned = const <ValueListenable<bool>>[],
    this.bottomInset,
  });

  /// 明细表 sticky 表头是否已置顶（由 UtenEditableGrid /
  /// MasterDataTableView(stickyHeaderPinned) 写入）。
  final ValueListenable<bool> pinned;

  /// 同页其余表格的置顶信号（一页多张表时：任一张置顶即显示——表间过渡的
  /// 空档会短暂隐藏，属「哪张表都没吸顶就不算表内滚动」的正确语义）。
  final Iterable<ValueListenable<bool>> extraPinned;

  /// 页面 ListView 的控制器（挂到内层 ListView 与滚动条上）。
  final ScrollController controller;

  /// 底部让位空白（页面 ListView 的底 padding）：thumb 不伸进该区。
  /// null = 自动取 UtenFloatingActionGroup.scrollClearance（编辑页全站口径）。
  final double? bottomInset;

  final Widget child;

  @override
  State<UtenGridPageScrollbar> createState() => _UtenGridPageScrollbarState();
}

class _UtenGridPageScrollbarState extends State<UtenGridPageScrollbar> {
  Listenable get _allPins =>
      Listenable.merge([widget.pinned, ...widget.extraPinned]);

  bool get _anyPinned =>
      widget.pinned.value || widget.extraPinned.any((p) => p.value);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _allPins,
      builder: (context, page) => Stack(
        children: [
          page!,
          // 视口最右缘的恒定滚动条窄条：thumb 画在屏幕右边（含内容右 padding 的
          // 12px 内），不占布局空间、不随内容容器宽度移动。仅在表头已置顶
          // （此后的页面滚动在观感上就是表内滚动）时显示。
          if (_anyPinned)
            Positioned(
              top: 0,
              right: 0,
              bottom: 0,
              width: 14,
              child: UtenContentScrollbar(
                controller: widget.controller,
                bottomInset:
                    widget.bottomInset ??
                    UtenFloatingActionGroup.scrollClearance,
              ),
            ),
        ],
      ),
      child: widget.child,
    );
  }
}
