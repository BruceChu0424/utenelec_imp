// Uten 设计 Token - 圆角 / 间距 / 阴影
// 文档：docs/00-项目准则/08-主题与配色.md
//
// 设计原则：
// 1. 所有圆角、间距、阴影统一从这里取，禁止业务代码散落硬编码数值
// 2. 阴影采用"双层柔和阴影"（近景接触影 + 远景弥散影），比单层更自然
// 3. 阴影对深色模式提供 isDark 变体（更强的黑色透明度）

import 'package:flutter/material.dart';

import '../responsive/display_zoom.dart';

/// Uten 圆角 token
///
/// 提供 double 常量（用于自定义圆角组合）与对应的 BorderRadius 快捷 getter。
///
/// 常用映射：
/// - 小控件（标签、勾选框）：xs / sm
/// - 普通按钮、输入框、Chip：control（10）；表格内编辑控件用 sm（6）
/// - 卡片、面板：card（16）
/// - 对话框、底部弹层：xxl
/// - 徽章、胶囊：pill
abstract final class UtenRadius {
  /// 4 —— 极小元素（勾选框、小标签）
  static const double xs = 4;

  /// 6 —— 小元素（Skeleton、小 Chip）
  static const double sm = 6;

  /// 8 —— 中等元素（图标容器）
  static const double md = 8;

  /// 10 —— 普通表单控件圆角：按钮、输入框、Chip、下拉等；表格内用 sm。
  /// 2026-09-01 全平台圆角统一：主题（含深色）与所有按钮组件一律调用本值，
  /// 业务代码不得再散落 8/10/12/14 等控件级硬编码。
  static const double control = 10;

  /// 12 —— 较大元素（Toast、SnackBar、小卡片）
  static const double lg = 12;

  /// 16 —— 大卡片、面板
  static const double xl = 16;

  /// 20 —— 对话框、底部弹层
  static const double xxl = 20;

  /// Semantic surface roles shared by themes and custom containers.
  static const double menu = md;
  static const double table = lg;
  static const double card = xl;
  static const double dialog = xxl;
  static const BorderRadius cardAll = BorderRadius.all(Radius.circular(card));
  static const BorderRadius tableAll = BorderRadius.all(Radius.circular(table));
  static const BorderRadius dialogAll = BorderRadius.all(
    Radius.circular(dialog),
  );

  /// 999 —— 胶囊（徽章、Pill 按钮）
  static const double pill = 999;

  /// [xs] 的 BorderRadius 快捷形式
  static const BorderRadius xsAll = BorderRadius.all(Radius.circular(xs));

  /// [sm] 的 BorderRadius 快捷形式
  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));

  /// [md] 的 BorderRadius 快捷形式
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));

  /// [control] 的 BorderRadius 快捷形式（按钮、输入框、Chip）
  static const BorderRadius controlAll = BorderRadius.all(
    Radius.circular(control),
  );

  /// [lg] 的 BorderRadius 快捷形式
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));

  /// [xl] 的 BorderRadius 快捷形式
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));

  /// [xxl] 的 BorderRadius 快捷形式
  static const BorderRadius xxlAll = BorderRadius.all(Radius.circular(xxl));

  /// [pill] 的 BorderRadius 快捷形式
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));
}

/// Uten 间距 token
///
/// 命名直接用数值（s4 / s8 / ...），与代码里的 EdgeInsets 数值一一对应，
/// 减少"猜语义"成本。常用节奏：卡片内边距 16/20，元素间距 8/12，区块间距 24/32。
abstract final class UtenSpacing {
  /// 2 —— 微间距（Wrap 行距、行内小标签与文字）
  static const double s2 = 2;

  /// 4 —— 紧凑元素间距（图标与文字、值与趋势行）
  static const double s4 = 4;

  /// 6 —— 小间距（行内小标签内边距、Wrap 元素间距）
  static const double s6 = 6;

  /// 8 —— 相关元素间距（标题与副标题、表单字段）
  static const double s8 = 8;

  /// 12 —— 中等元素间距（卡片内分组、头像与文字）
  static const double s12 = 12;

  /// 16 —— 标准内边距（卡片、列表项、页面窄屏 gutter）
  static const double s16 = 16;

  /// 20 —— 宽松内边距（重点卡片、对话框）
  static const double s20 = 20;

  /// 24 —— 区块间距、页面中屏 gutter
  static const double s24 = 24;

  /// 32 —— 大区块间距、页面宽屏 gutter
  static const double s32 = 32;

  /// 40 —— 页面级间距
  static const double s40 = 40;

  /// 48 —— 页面级大间距（空状态、页脚）
  static const double s48 = 48;
}

/// Standard desktop toolbar geometry. Touch targets use [UtenControlMetrics].
abstract final class UtenTableToolbar {
  static const double controlHeight = UtenControlMetrics.standardHeight;
}

/// Screen-size-independent control roles, in the application's layout canvas.
/// Application zoom scales this canvas once at the root. Shrinking the UI must
/// never shrink a touch target below 48 window logical pixels.
abstract final class UtenControlMetrics {
  static const double compactHeight = 36;
  static const double standardHeight = 40;
  static const double primaryHeight = 48;
  static const double inputHeight = 44;
  static const double cellHeight = 32;
  static const double touchExtent = 48;

  static bool usesTouchTargets(BuildContext context) {
    final platform = Theme.of(context).platform;
    return platform == TargetPlatform.android ||
        platform == TargetPlatform.iOS ||
        platform == TargetPlatform.fuchsia ||
        (MediaQuery.maybeSizeOf(context)?.width ?? 840) < 600;
  }

  static double minimumHitExtent(BuildContext context, {double desktop = 40}) {
    if (!usesTouchTargets(context)) return desktop;
    final zoom = UtenDisplayScale.fontZoomOf(context);
    final touch = touchExtent / (zoom < 1 ? zoom : 1);
    return desktop > touch ? desktop : touch;
  }

  static double controlHeight(BuildContext context, {double desktop = 40}) =>
      minimumHitExtent(context, desktop: desktop);
}

/// 模块分类栏与搜索框共用的圆角矩形、内容间距和高度角色。桌面36；
/// 触控目标至少48窗口像素，应用缩小时由 UtenControlMetrics 补偿。
/// 搜索描边的内容高度下限也使用此角色，不能只拉高外部 TextField 盒子。
/// 文字和徽章可自然撑高；逐格内容宽度、分类层级与计数逻辑由组件保留。
abstract final class UtenFilterRow {
  static const double minHeight = UtenControlMetrics.compactHeight;
  static const BorderRadius borderRadius = UtenRadius.controlAll;
  static const double cellHorizontalPadding = 8;
  static const double cellVerticalPadding = 4;
  static const double iconGap = 4;
  static const double rowGap = 6;
  static const EdgeInsets contentPadding = EdgeInsets.symmetric(
    horizontal: cellHorizontalPadding,
    vertical: cellVerticalPadding,
  );

  static double heightOf(BuildContext context) =>
      UtenControlMetrics.controlHeight(context, desktop: minHeight);

  static double minimumWidthOf(BuildContext context) =>
      UtenControlMetrics.minimumHitExtent(context, desktop: 24);
}

/// Normal form fields in pages, cards and dialogs. Search/filter controls and
/// table cell editors have their own compact roles.
abstract final class UtenPageField {
  static const double minHeight = UtenControlMetrics.inputHeight;
  static const BorderRadius borderRadius = UtenRadius.controlAll;
  static const EdgeInsets contentPadding = EdgeInsets.symmetric(
    horizontal: UtenSpacing.s12,
    vertical: 10,
  );
  static const BoxConstraints iconConstraints = BoxConstraints(
    minWidth: minHeight,
    minHeight: minHeight,
  );

  static double heightOf(BuildContext context) =>
      UtenControlMetrics.controlHeight(context, desktop: minHeight);
}

/// 自研表格共用的表头文字样式，渲染与列宽测量使用同一入口。
/// 可筛选、可排序和普通列保持相同字号/字重；仅生效状态使用主色。
abstract final class UtenTableHeader {
  static TextStyle textStyle(ThemeData theme, {bool highlighted = false}) =>
      (theme.textTheme.labelLarge ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w600,
        color: highlighted
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      );
}

/// Uten 阴影 token（双层柔和阴影）
///
/// 每层阴影 = 近景接触影（小 blur、贴边）+ 远景弥散影（大 blur、扩散），
/// 组合起来比单层阴影更贴近真实光照。
///
/// 层级约定：
/// - [low]：常规卡片（默认，让卡片轻微漂浮于背景）
/// - [mid]：悬浮卡片、下拉菜单、吸底操作栏
/// - [high]：对话框、弹层、Popover
///
/// 深色模式传 `isDark: true`，使用更强的黑色透明度保证层次可见。
abstract final class UtenElevation {
  /// 浅色模式阴影基色（slate-900）
  static const Color _lightShadowColor = Color(0xFF0F172A);

  /// 低层级阴影：常规卡片
  static List<BoxShadow> low({bool isDark = false}) => [
    BoxShadow(
      color: isDark
          ? Colors.black.withValues(alpha: 0.30)
          : _lightShadowColor.withValues(alpha: 0.05),
      blurRadius: 2,
      offset: const Offset(0, 1),
    ),
    BoxShadow(
      color: isDark
          ? Colors.black.withValues(alpha: 0.24)
          : _lightShadowColor.withValues(alpha: 0.04),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
  ];

  /// 中层级阴影：悬浮卡片、下拉菜单
  static List<BoxShadow> mid({bool isDark = false}) => [
    BoxShadow(
      color: isDark
          ? Colors.black.withValues(alpha: 0.34)
          : _lightShadowColor.withValues(alpha: 0.05),
      blurRadius: 4,
      offset: const Offset(0, 2),
    ),
    BoxShadow(
      color: isDark
          ? Colors.black.withValues(alpha: 0.28)
          : _lightShadowColor.withValues(alpha: 0.07),
      blurRadius: 24,
      offset: const Offset(0, 8),
    ),
  ];

  /// 高层级阴影：对话框、弹层、Popover
  static List<BoxShadow> high({bool isDark = false}) => [
    BoxShadow(
      color: isDark
          ? Colors.black.withValues(alpha: 0.40)
          : _lightShadowColor.withValues(alpha: 0.06),
      blurRadius: 8,
      offset: const Offset(0, 4),
    ),
    BoxShadow(
      color: isDark
          ? Colors.black.withValues(alpha: 0.32)
          : _lightShadowColor.withValues(alpha: 0.10),
      blurRadius: 40,
      offset: const Offset(0, 16),
    ),
  ];
}
