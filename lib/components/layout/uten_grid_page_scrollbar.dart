// UtenGridPageScrollbar - 单据编辑页右缘竖向内容滚动条。
// 内容超出视口即显示，可拖动；不再等待明细表头置顶。
// 底部悬浮操作让位区不参与滑块活动范围。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'uten_floating_action_group.dart';
import 'uten_vertical_scroll_area.dart';

class UtenGridPageScrollbar extends StatefulWidget {
  const UtenGridPageScrollbar({
    super.key,
    required this.pinned,
    required this.controller,
    required this.child,
    this.extraPinned = const <ValueListenable<bool>>[],
    this.bottomInset,
  });

  /// 保留调用兼容的置顶信号；滚动条显示只由实际可滚动范围决定。
  final ValueListenable<bool> pinned;

  /// 保留调用兼容的其他置顶信号，不再用于隐藏滚动条。
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
  @override
  Widget build(BuildContext context) {
    return UtenVerticalScrollArea(
      controller: widget.controller,
      pageScrollbar: true,
      bottomInset:
          widget.bottomInset ?? UtenFloatingActionGroup.scrollClearance,
      child: widget.child,
    );
  }
}
