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
  final inset = utenDialogInsetPadding(context);
  return math.max(0, math.min(designWidth, screen - inset.horizontal));
}

/// [utenDialogWidth] 配套的 Dialog insetPadding（三档），替代 Material 默认的
/// 固定 40：compact 12 / medium 24 / expanded 40。传给 Dialog/AlertDialog 的
/// insetPadding 后弹窗宽度不再被默认边距钳制，三档宽度得以显式生效。
EdgeInsets utenDialogInsetPadding(BuildContext context) =>
    context.screenWidth < 240
    ? const EdgeInsets.symmetric(horizontal: 4, vertical: 12)
    : switch (context.breakpoint) {
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

/// Bounds the whole dialog, including its title and actions, after keyboard and
/// safe-area layout. Call inside LayoutBuilder so nested panels use local space.
BoxConstraints utenDialogConstraints(
  BuildContext context, {
  required BoxConstraints available,
  required double maxWidth,
  EdgeInsets? insetPadding,
  BoxConstraints? requested,
  bool fillHeight = false,
}) {
  final media = MediaQuery.of(context);
  final inset = insetPadding ?? utenDialogInsetPadding(context);
  final width = math.max(
    0.0,
    math.min(available.maxWidth, media.size.width) -
        media.viewInsets.horizontal -
        inset.horizontal,
  );
  final height =
      math.max(
        0.0,
        math.min(available.maxHeight, media.size.height) -
            media.viewInsets.vertical -
            inset.vertical,
      ) *
      0.85;
  final cappedWidth = math.min(
    width,
    math.min(maxWidth, requested?.maxWidth ?? maxWidth),
  );
  final cappedHeight = math.min(height, requested?.maxHeight ?? height);
  return BoxConstraints(
    minWidth: math.min(
      cappedWidth,
      requested?.minWidth ?? math.min(280, cappedWidth),
    ),
    maxWidth: cappedWidth,
    minHeight: fillHeight
        ? cappedHeight
        : math.min(cappedHeight, requested?.minHeight ?? 0),
    maxHeight: cappedHeight,
  );
}
