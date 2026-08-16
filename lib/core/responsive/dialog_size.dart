// 居中弹窗宽度的三档断点显式适配。
// 文档：docs/00-项目准则/02-响应式与多端适配.md
//
// 规范前各弹窗固定 720–840 设计宽、小屏靠 Dialog 父级约束静默钳制；
// 现显式三档：expanded 设计宽全量 / medium 收窄 / compact 近全屏。
// 右滑侧板不走本文件——统一用 showUtenAdaptivePanel（compact 底部弹层降级）。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'breakpoint.dart';

/// 居中弹窗宽度的三档取值（dp）：
/// - expanded（>840）：[designWidth] 全量；
/// - medium（600–840）：min(设计宽, 屏宽 − 48)，与 [utenDialogInsetPadding] 的 24 边距配套；
/// - compact（<600）：屏宽 − 24，配合 12 边距近全屏（小屏不再挤成窄条）。
double utenDialogWidth(BuildContext context, double designWidth) {
  final screen = context.screenWidth;
  return context.breakpoint.select(
    compact: screen - 24,
    medium: math.min(designWidth, screen - 48),
    expanded: designWidth,
  );
}

/// [utenDialogWidth] 配套的 Dialog insetPadding（三档），替代 Material 默认的
/// 固定 40：compact 12 / medium 24 / expanded 40。传给 Dialog/AlertDialog 的
/// insetPadding 后弹窗宽度不再被默认边距钳制，三档宽度得以显式生效。
EdgeInsets utenDialogInsetPadding(BuildContext context) =>
    switch (context.breakpoint) {
      UtenBreakpoint.compact => const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 24,
      ),
      UtenBreakpoint.medium => const EdgeInsets.symmetric(
        horizontal: 24,
        vertical: 24,
      ),
      UtenBreakpoint.expanded => const EdgeInsets.symmetric(
        horizontal: 40,
        vertical: 24,
      ),
    };
