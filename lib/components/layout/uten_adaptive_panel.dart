import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/responsive/breakpoint.dart';
import '../../core/theme/uten_tokens.dart';

/// 右侧滑窗屏宽占比档位（2026-10-17：保留表格可读性，滑窗适当收窄）。
///
/// 面板宽度 = `min(屏宽, max(drawerWidth, 屏宽 × 档位))`：比例优先、调用点的
/// [showUtenAdaptivePanel.drawerWidth] 只作小屏下限。旧口径是各调用点写死像素
/// （720 / 840 / max(720, 50%)），在 expanded 大屏上占比缩水到 35% 左右，表格
/// 挤成一团——这是「滑窗太小」的根因，故全站改为比例驱动并集中在此调参；
/// 与居中弹窗的 [utenDialogWidth] 三档口径分工：右滑面板不走那边。
class UtenPanelWidth {
  UtenPanelWidth._();

  /// 表单 / 简单选择面板：max(下限, 35% 屏宽)。
  static const double form = 0.35;

  /// 内容面板：max(下限, 60% 屏宽)。
  static const double content = 0.60;

  /// 表格 / 列表浏览面板（默认档）：max(下限, 75% 屏宽)。
  static const double browse = 0.75;

  /// 不放大：保持 drawerWidth 原值（菜单类面板）。
  static const double none = 0;
}

/// 右滑面板宽度计算：`min(屏宽, max(preferred, 屏宽 × fraction))`。
/// [showUtenAdaptivePanel] 与各自绘右滑面板（page_permission_drawer 等 5 处）
/// 共用这一个函数，保证全站滑窗一个口径。
double utenPanelWidth(Size screenSize, double preferred, double fraction) =>
    math.min(
      screenSize.width,
      math.max(preferred, screenSize.width * fraction),
    );

/// Opens a Uten panel as a bottom sheet on compact screens and an end drawer
/// on wider screens.
///
/// The function owns only the responsive presentation shell. Loading,
/// selection drafts, validation, cancel and confirm behavior remain inside
/// [builder].
Future<T?> showUtenAdaptivePanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double compactHeightFactor = 0.85,
  double drawerWidth = 420,
  double widthFraction = UtenPanelWidth.browse,
  bool barrierDismissible = true,
  bool enableDrag = true,
  bool useSafeArea = true,
  bool showDragHandle = false,
  String? barrierLabel,
  Color barrierColor = Colors.black54,
  Duration transitionDuration = const Duration(milliseconds: 250),

  /// 宽屏右侧面板 Material 的投影高度（默认 0 与历史行为一致）。
  double panelElevation = 0,
}) {
  assert(compactHeightFactor > 0 && compactHeightFactor <= 1);
  assert(drawerWidth > 0);

  final resolvedBarrierLabel =
      barrierLabel ??
      MaterialLocalizations.of(context).modalBarrierDismissLabel;

  if (context.breakpoint.isCompact) {
    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(UtenRadius.lg)),
    );
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      isDismissible: barrierDismissible,
      enableDrag: enableDrag,
      useSafeArea: useSafeArea,
      showDragHandle: showDragHandle,
      barrierLabel: resolvedBarrierLabel,
      barrierColor: barrierColor,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      builder: (sheetContext) {
        final mediaQuery = MediaQuery.of(sheetContext);
        final visibleHeight = math.max(
          0.0,
          mediaQuery.size.height -
              mediaQuery.viewInsets.bottom -
              mediaQuery.padding.top,
        );
        return Padding(
          padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
          child: SizedBox(
            height: visibleHeight * compactHeightFactor,
            child: builder(sheetContext),
          ),
        );
      },
    );
  }

  final isRtl = Directionality.of(context) == TextDirection.rtl;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: resolvedBarrierLabel,
    barrierColor: barrierColor,
    transitionDuration: transitionDuration,
    pageBuilder: (dialogContext, _, _) {
      final mediaQuery = MediaQuery.of(dialogContext);
      Widget content = builder(dialogContext);
      if (useSafeArea) {
        content = SafeArea(left: false, child: content);
      }
      return Padding(
        padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Material(
            color: Theme.of(dialogContext).colorScheme.surface,
            elevation: panelElevation,
            child: SizedBox(
              width: utenPanelWidth(
                mediaQuery.size,
                drawerWidth,
                widthFraction,
              ),
              height: double.infinity,
              child: content,
            ),
          ),
        ),
      );
    },
    transitionBuilder: (_, animation, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: Offset(isRtl ? -1 : 1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}
