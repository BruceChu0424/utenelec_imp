// 状态配色解析的公共落点(ADR-169 状态色改版, 2026-10-08)。
// UtenStatusBadge 胶囊与表格状态列 cellColor(utenStatusBadgeCellColor)共用同一份
// 「深色实底 + 成套前景」解析, 保证徽章与整格底色永远同色。
//
// 状态→档位的映射由各页自己的映射函数显式决定(逐页独立口径, 见
// docs/00-项目准则/08-主题与配色.md §2.5); 本文件只按档取色,
// 不再提供按状态文案关键字猜色的兜底——猜色正是「委外锁行显示黄色」
// 这类语义错误的根源, 未显式映射的状态列就保持无色纯文本。
import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import 'uten_status_badge.dart';

/// 徽章同款底色，给表格 cellColor 铺整格用：
/// 深色实底(明暗两主题同色)，文字颜色由表格 cellColor 双向对比度约定统一接管
/// (黑/白自适应 + 正文字号)。
Color utenStatusBadgeCellColor(UtenStatusBadgeType type) =>
    resolveStatusBadgeColors(type).$1;

/// Custom cell colors may be translucent and render on the current theme
/// surface. The raw RGB channels alone cannot choose a readable foreground in
/// dark mode.
Color utenSemanticCellForeground(BuildContext context, Color background) {
  final rendered = Color.alphaBlend(
    background,
    Theme.of(context).colorScheme.surface,
  );
  return ThemeData.estimateBrightnessForColor(rendered) == Brightness.dark
      ? Colors.white
      : Colors.black87;
}

bool utenIsStatusColumn(String key, String label) {
  final normalized = key.toLowerCase();
  return normalized == 'status' ||
      normalized == 'state' ||
      normalized.endsWith('status') ||
      normalized.endsWith('state') ||
      normalized == 'stage' ||
      normalized.endsWith('stage') ||
      label.contains('状态');
}

/// 状态/进度列判定（ADR-169 后用户口径「状态或进度列默认最前、字体统一加粗」）：
/// 状态列口径之外再认 key 含 progress / 标签含「进度」的列。
bool utenIsStatusOrProgressColumn(String key, String label) =>
    utenIsStatusColumn(key, label) ||
    key.toLowerCase().contains('progress') ||
    label.contains('进度');

class UtenStatusCellScope extends InheritedWidget {
  const UtenStatusCellScope({
    super.key,
    required this.enabled,
    required super.child,
  });
  final bool enabled;
  static bool isCell(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<UtenStatusCellScope>()
          ?.enabled ==
      true;
  @override
  bool updateShouldNotify(UtenStatusCellScope oldWidget) =>
      enabled != oldWidget.enabled;
}

/// 解析两色：实底色 / 成套前景字。
///
/// 深色实底自带对比度, 明暗两主题取同一对色(与计数徽章 dangerStrong/
/// warningStrong 同一路数); 琥珀档是唯一亮底, 配深棕字——「黄更黄」与
/// 「白字」不能同时成立, 这一对是配套的, 换底色必须同时换字色
/// (定色过程见 [UtenColors.warningStrong] 注释)。
(Color, Color) resolveStatusBadgeColors(UtenStatusBadgeType t) => switch (t) {
  UtenStatusBadgeType.neutral => (UtenColors.statusNeutral, Colors.white),
  UtenStatusBadgeType.info => (UtenColors.statusInfo, Colors.white),
  UtenStatusBadgeType.success => (UtenColors.statusSuccess, Colors.white),
  UtenStatusBadgeType.warning => (
    UtenColors.warningStrong,
    UtenColors.onWarningStrong,
  ),
  UtenStatusBadgeType.danger => (UtenColors.statusDanger, Colors.white),
  UtenStatusBadgeType.orange => (UtenColors.statusOrange, Colors.white),
  UtenStatusBadgeType.sky => (UtenColors.statusSky, Colors.white),
  UtenStatusBadgeType.violet => (UtenColors.statusViolet, Colors.white),
  UtenStatusBadgeType.fuchsia => (UtenColors.statusFuchsia, Colors.white),
  UtenStatusBadgeType.accent => (UtenColors.statusTeal, Colors.white),
};
