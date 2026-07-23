// 响应式断点系统
// 文档：docs/00-项目准则/02-响应式与多端适配.md
// 对齐 Material 3 WindowSizeClass

import 'package:flutter/widgets.dart';

/// Uten 响应式断点
///
/// 对齐 Material 3 WindowSizeClass：
/// - compact: < 600 dp（手机竖屏）
/// - medium: 600-840 dp（手机横屏、小平板）
/// - expanded: > 840 dp（平板、桌面）
enum UtenBreakpoint {
  /// 紧凑：手机竖屏
  compact,

  /// 中等：手机横屏、小平板
  medium,

  /// 扩展：平板、桌面
  expanded,
}

/// 断点阈值常量（dp）
abstract final class UtenBreakpoints {
  /// compact → medium 的分界
  static const double mediumStart = 600;

  /// medium → expanded 的分界
  static const double expandedStart = 840;

  /// 大屏内容区最大宽度（避免超宽屏内容拉得太长）
  static const double maxContentWidth = 1600;
}

extension UtenBreakpointValue on UtenBreakpoint {
  /// 当前断点是否为 compact
  bool get isCompact => this == UtenBreakpoint.compact;

  /// 当前断点是否为 medium
  bool get isMedium => this == UtenBreakpoint.medium;

  /// 当前断点是否为 expanded
  bool get isExpanded => this == UtenBreakpoint.expanded;

  /// 是否至少为 medium（即 medium 或 expanded）
  bool get atLeastMedium =>
      this == UtenBreakpoint.medium || this == UtenBreakpoint.expanded;

  /// 是否至少为 expanded
  bool get atLeastExpanded => this == UtenBreakpoint.expanded;

  /// 根据断点选择值
  T select<T>({required T compact, T? medium, T? expanded}) {
    return switch (this) {
      UtenBreakpoint.compact => compact,
      UtenBreakpoint.medium => medium ?? compact,
      UtenBreakpoint.expanded => expanded ?? medium ?? compact,
    };
  }

  /// 网格列数（按断点推荐）
  int get gridColumns => switch (this) {
        UtenBreakpoint.compact => 1,
        UtenBreakpoint.medium => 2,
        UtenBreakpoint.expanded => 4,
      };
}

/// 根据宽度解析断点
UtenBreakpoint breakpointForWidth(double width) {
  if (width < UtenBreakpoints.mediumStart) return UtenBreakpoint.compact;
  if (width < UtenBreakpoints.expandedStart) return UtenBreakpoint.medium;
  return UtenBreakpoint.expanded;
}

/// BuildContext 扩展：方便取当前断点
extension UtenContextBreakpoint on BuildContext {
  /// 当前断点（基于屏幕宽度）
  UtenBreakpoint get breakpoint =>
      breakpointForWidth(MediaQuery.sizeOf(this).width);

  /// 当前屏幕宽度
  double get screenWidth => MediaQuery.sizeOf(this).width;

  /// 当前屏幕高度
  double get screenHeight => MediaQuery.sizeOf(this).height;
}
