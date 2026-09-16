// UtenGridPageScrollbar - 单据编辑页竖向滚动条的门控包装。
//
// 2026-09-14 全站滚动条口径：页面主体是「表头表单 + UtenEditableGrid 明细表」的
// 编辑页，整页一条 ListView 滚动（网格表体不内滚、sticky 表头上滑吸顶）。表头
// 表单还没滚完、明细表未置顶时**不常显**上下滚动条；sticky 表头吸附视口顶后
// （继续滚动在观感上就是表内滚动）常显——与 UtenCollapsingHeaderScrollView +
// MasterDataTableView 经 UtenInnerScrollActiveScope 的门控口径一致。
//
// 2026-09-15 补充口径（用户反馈）：
//  1. 「表内上下拖动的时候应该显示上下滚动条」——未吸顶阶段也不是完全无反馈：
//     页面滚动进行中（触摸拖动/滚轮/惯性）临时亮条，停止约 600ms 后隐藏。
//     无可滚内容（页面滚不动）时自然不出现。
//  2. 「滚动条放在屏幕的最右边，不是表格的最右边，屏幕的左右不要动」——滚动条
//     不再随 ListView/内容容器右缘走，改为覆盖在**视口最右缘**的恒定窄条：
//     页面内容容器限宽居中（超宽屏）时滚动条仍贴屏幕右边，位置不随列宽/窗口漂移。
//
// 用法（pinned 与 UtenEditableGrid.stickyHeaderPinned 传同一个 notifier）：
//   final _gridPinned = ValueNotifier<bool>(false);
//   UtenGridPageScrollbar(
//     pinned: _gridPinned,
//     controller: _scrollCtl,
//     child: ListView(controller: _scrollCtl, ...),
//   )

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class UtenGridPageScrollbar extends StatefulWidget {
  const UtenGridPageScrollbar({
    super.key,
    required this.pinned,
    required this.controller,
    required this.child,
  });

  /// 明细表 sticky 表头是否已置顶（由 UtenEditableGrid 写入）。
  final ValueListenable<bool> pinned;

  /// 页面 ListView 的控制器（挂到内层 ListView 与滚动条上）。
  final ScrollController controller;

  final Widget child;

  @override
  State<UtenGridPageScrollbar> createState() => _UtenGridPageScrollbarState();
}

class _UtenGridPageScrollbarState extends State<UtenGridPageScrollbar> {
  /// 滚动进行中（offset 在变）→ 临时亮条；停止后延迟熄灭。
  bool _dragActive = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onOffsetChanged);
  }

  @override
  void didUpdateWidget(UtenGridPageScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onOffsetChanged);
      widget.controller.addListener(_onOffsetChanged);
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_onOffsetChanged);
    super.dispose();
  }

  void _onOffsetChanged() {
    _hideTimer?.cancel();
    if (!_dragActive) {
      setState(() => _dragActive = true);
    }
    _hideTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _dragActive = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.pinned,
      builder: (context, isPinned, page) => Stack(
        children: [
          page!,
          // 视口最右缘的恒定滚动条窄条：thumb 画在屏幕右边（含内容右 padding 的
          // 12px 内），不占布局空间、不随内容容器宽度移动。
          if (isPinned || _dragActive)
            Positioned(
              top: 0,
              right: 0,
              bottom: 0,
              width: 14,
              child: Scrollbar(
                controller: widget.controller,
                thumbVisibility: true,
                // 覆盖条自身不承载内容：thumb 的长短/位置由 controller 驱动。
                child: const SizedBox.expand(),
              ),
            ),
        ],
      ),
      child: widget.child,
    );
  }
}
