// UtenSideNavRail - 左侧导航栏（medium+ 断点替代底部悬浮胶囊）
// 文档：docs/03-页面/App外壳.md
//
// 设计：
// - 全高 surface 底 + 右侧 1px 发丝边框，与内容区自然分层
// - 宽度 ≥1280dp 时 extended（常驻文字标签），否则纯图标 + Tooltip
// - 顶部品牌位：extended 放横向字标 UtenWordmarkLogo.compact；
//   折叠态字标太宽放不下，改用品牌吉祥物小图标
// - 通知项未读角标（Badge，>0 显示）
// - 选中态指示器与配色全部来自主题 NavigationRailTheme
//   （浅色 teal100 底 + teal600 图标文字 / 深色 teal900 底 + teal400），不另做覆盖

import 'package:flutter/material.dart';

import '../../../components/brand/uten_brand_mascot.dart';
import '../../../components/brand/uten_wordmark_logo.dart';

/// 桌面 / 平板端左侧导航栏。
///
/// 与 [FloatingCapsuleNavBar] 同一份 4 项目的地（工作台 / 通知 / 我的 / 设置），
/// 由 MainShellPage 在 medium+ 断点挂载。
class UtenSideNavRail extends StatelessWidget {
  const UtenSideNavRail({
    super.key,
    required this.selectedIndex,
    required this.onTap,
    required this.labels,

    /// 各 tab 的未读角标数（>0 才显示）；长度不足视为 0。
    this.badgeCounts = const <int>[],

    /// 是否展开常驻标签（外壳在屏宽 ≥1280dp 时传 true）。
    this.extended = false,
  });

  final int selectedIndex;
  final ValueChanged<int> onTap;
  final List<String> labels;
  final List<int> badgeCounts;
  final bool extended;

  /// 展开态最小宽度
  static const double _extendedWidth = 216;

  static const _icons = <IconData>[
    Icons.space_dashboard_outlined,
    Icons.notifications_outlined,
    Icons.person_outline_rounded,
    Icons.settings_outlined,
  ];

  static const _selectedIcons = <IconData>[
    Icons.space_dashboard_rounded,
    Icons.notifications_rounded,
    Icons.person_rounded,
    Icons.settings_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.navigationRailTheme.backgroundColor ??
            theme.colorScheme.surface,
        border: Border(
          right: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(
              alpha: isDark ? 0.6 : 1,
            ),
          ),
        ),
      ),
      child: NavigationRail(
        extended: extended,
        minExtendedWidth: _extendedWidth,
        // 贴顶排布（品牌位之下即目的地）
        groupAlignment: -1,
        // extended 要求 labelType 必须为 none（标签随 extended 自动常驻）；
        // 折叠态同样 none = 纯图标，文案由 Tooltip 补充
        labelType: NavigationRailLabelType.none,
        selectedIndex: selectedIndex,
        onDestinationSelected: onTap,
        leading: extended
            ? const Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 16, 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: UtenWordmarkLogo.compact(),
                ),
              )
            : const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: UtenBrandMascot.size(40),
              ),
        destinations: [
          for (var i = 0; i < labels.length; i++)
            NavigationRailDestination(
              icon: _navIcon(_icons[i], i),
              selectedIcon: _navIcon(_selectedIcons[i], i),
              label: Text(labels[i]),
            ),
        ],
      ),
    );
  }

  /// 目的地图标：挂未读角标；折叠态补 Tooltip（extended 标签常驻则不需要）
  Widget _navIcon(IconData icon, int i) {
    final count = i < badgeCounts.length ? badgeCounts[i] : 0;
    Widget child = Badge(
      label: Text(count > 99 ? '99+' : '$count'),
      isLabelVisible: count > 0,
      child: Icon(icon),
    );
    if (!extended) {
      child = Tooltip(message: labels[i], child: child);
    }
    return child;
  }
}
