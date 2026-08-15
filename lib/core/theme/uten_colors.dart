// Uten 品牌色板
// 文档：docs/00-项目准则/08-主题与配色.md
// 决策：ADR-004-品牌色深绿青绿.md
//
// 设计原则：
// 1. 背景走中性灰阶（slate），不铺品牌色
// 2. 浅色 / 深色模式交互主色统一用 teal（青绿），按钮 / TabBar / 导航选中色
//    在两模式下一致
// 3. 卡片/容器用白色或浅中性色，靠细边框 + 极轻阴影分层
// 4. 文字用 slate-900 / slate-600 / slate-400 三档建立层级

import 'package:flutter/material.dart';

import 'uten_tokens.dart';

/// Uten 品牌色板常量
abstract final class UtenColors {
  // ===== 品牌主色 =====
  /// 跨明暗主题使用的兼容交互色；浅色实心按钮由 ColorScheme 单独定义
  static const Color primary = teal500;

  /// 品牌深绿（兼容旧引用）
  static const Color deepGreen = teal800;

  // ===== 青绿色阶（交互态统一用 teal 系）=====
  static const Color teal50 = Color(0xFFF0FDFA);
  static const Color teal100 = Color(0xFFCCFBF1);
  static const Color teal200 = Color(0xFF99F6E4);
  static const Color teal300 = Color(0xFF5EEAD4);
  static const Color teal400 = Color(0xFF2DD4BF);
  static const Color teal500 = Color(0xFF14B8A6);
  static const Color teal600 = Color(0xFF0D9488);
  static const Color teal700 = Color(0xFF0F766E);
  static const Color teal800 = Color(0xFF115E59);
  static const Color teal900 = Color(0xFF134E4A);
  static const Color teal950 = Color(0xFF042F2E);

  /// 强调色（= teal500）
  static const Color accent = teal500;

  // ===== 中性灰阶（slate，微调加深以增强卡片分层）=====
  static const Color background = Color(0xFFF5F7FA);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceLow = Color(0xFFF8FAFC);
  static const Color surfaceMid = Color(0xFFEEF1F5);
  static const Color surfaceHigh = Color(0xFFE3E8EF);

  /// 文字（三档建立清晰层级）
  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textSecondary = Color(0xFF475569);
  static const Color textTertiary = Color(0xFF94A3B8);

  /// 边框/分隔线
  static const Color border = Color(0xFFE2E8F0);
  static const Color borderStrong = Color(0xFFCBD5E1);
  static const Color divider = Color(0xFFF1F5F9);

  // slate 色阶（备用）
  static const Color slate50 = Color(0xFFF8FAFC);
  static const Color slate100 = Color(0xFFF1F5F9);
  static const Color slate200 = Color(0xFFE2E8F0);
  static const Color slate300 = Color(0xFFCBD5E1);
  static const Color slate400 = Color(0xFF94A3B8);
  static const Color slate500 = Color(0xFF64748B);
  static const Color slate700 = Color(0xFF334155);
  static const Color slate900 = Color(0xFF0F172A);
  static const Color slate950 = Color(0xFF020617);

  // ===== 语义色 =====
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);
  static const Color errorBg = Color(0xFFFEE2E2);
  static const Color info = Color(0xFF3B82F6);

  /// 深色表面上的高对比语义前景色。
  static const Color successOnDark = Color(0xFF34D399);
  static const Color warningOnDark = Color(0xFFFBBF24);
  static const Color errorOnDark = Color(0xFFF87171);
  static const Color infoOnDark = Color(0xFF60A5FA);

  /// 语义色柔和底色（徽章、提示条、浅色高亮块）
  static const Color successBg = Color(0xFFECFDF5);
  static const Color warningBg = Color(0xFFFFFBEB);
  static const Color infoBg = Color(0xFFEFF6FF);

  /// info 通知容器配对（与 success/error 的 *Container 同构：浅底深字 / 深底浅字）。
  /// 顶部通知 banner 的 info 类用这一对，避免再用中性灰 surfaceContainerHighest
  /// 把信息条刷成一片灰（hover 时尤其明显）。
  /// 浅色模式：浅蓝底 + blue-700 深蓝字（WCAG AA）。
  static const Color infoContainer = Color(0xFFEFF6FF); // = infoBg
  static const Color onInfoContainer = Color(0xFF1D4ED8);

  /// 深色模式：深蓝底 + blue-200 浅蓝字。
  static const Color infoContainerDark = Color(0xFF1E3A8A);
  static const Color onInfoContainerDark = Color(0xFFBFDBFE);

  /// 品牌青绿柔和底色（= teal50），用于选中态、高亮块
  static const Color tealSurface = teal50;

  /// 语义色深档文字色（配合 *Bg 底色使用，保证对比度）
  static const Color successText = Color(0xFF047857);
  static const Color warningText = Color(0xFFB45309);
  static const Color infoText = Color(0xFF1D4ED8);
  static const Color errorText = Color(0xFFB91C1C);

  // ===== 生产单据纸面色板（A4 工卡 / 计划单等"纸质复刻"视图专用）=====
  // 这组颜色模拟纸张与墨色，不随 app 明暗主题切换（纸永远是白底墨字）。
  // 只允许生产单据复刻视图使用；普通业务 UI 仍走 colorScheme / 上述语义色。
  /// 纸面主墨色（深墨绿黑，标题/正文强调）
  static const Color docInk = Color(0xFF17231F);

  /// 纸面次级墨色（说明文字）
  static const Color docInkSoft = Color(0xFF52605A);

  /// 纸面表格线 / 分隔线
  static const Color docLine = Color(0xFFD5E1DB);

  /// 纸面浅底色（表头 / 汇总行底纹）
  static const Color docPaperTint = Color(0xFFF3F7F5);

  /// 纸面警示墨色（单据上的"作废/警告"字样）
  static const Color docDanger = Color(0xFFB3261E);

  // ===== 分类强调色（HR 节庆 / 快捷入口等非语义装饰色）=====
  // 用于按类别区分的图标、数字等待办强调；不是 success/warning 语义，
  // 语义状态请用上面的 success/warning/error 系列。
  /// 生日（粉）
  static const Color catPink = Color(0xFFDB2777);

  /// 周年纪念（琥珀）
  static const Color catAmber = Color(0xFFD97706);

  /// 新员工（祖母绿）
  static const Color catEmerald = Color(0xFF059669);

  /// 婚礼祝福（品红）
  static const Color catFuchsia = Color(0xFFD946EF);

  /// 新生儿（天蓝）
  static const Color catSky = Color(0xFF38BDF8);

  /// 庆典彩屑配色（CelebrationParticleField 默认值；装饰色，非语义）
  static const List<Color> festiveConfetti = [
    Color(0xFFF43F5E),
    Color(0xFFF59E0B),
    Color(0xFF14B8A6),
    Color(0xFF8B5CF6),
    Color(0xFF38BDF8),
    Color(0xFFEC4899),
  ];

  // ===== 特殊几何阴影色（不并轨 UtenElevation 双层体系的单点阴影）=====
  /// 表头筛选悬浮单元格阴影（33% 黑）
  static const Color floatingCellShadow = Color(0x55000000);

  /// 列显隐拖拽隐藏徽章阴影（40% 黑）
  static const Color dragBadgeShadow = Color(0x66000000);

  // ===== 深色主题专用 =====
  static const Color darkBackground = Color(0xFF0B1120);
  static const Color darkSurface = Color(0xFF101A2C);
  static const Color darkSurfaceLow = Color(0xFF1E293B);
  static const Color darkSurfaceHigh = Color(0xFF334155);
  static const Color darkBorder = Color(0xFF1F2A3D);
  static const Color darkBorderStrong = Color(0xFF334155);

  /// 深色文字
  static const Color darkTextPrimary = Color(0xFFF1F5F9);
  static const Color darkTextSecondary = Color(0xFF94A3B8);
  static const Color darkTextTertiary = Color(0xFF64748B);

  // ===== 阴影 token（已收敛到 UtenElevation 双层柔和阴影，此处保留兼容签名）=====
  /// 常规卡片阴影（= UtenElevation.low）
  static List<BoxShadow> cardShadow({bool isDark = false}) =>
      UtenElevation.low(isDark: isDark);

  /// 悬浮卡片阴影（= UtenElevation.mid）
  static List<BoxShadow> cardShadowLg({bool isDark = false}) =>
      UtenElevation.mid(isDark: isDark);

  /// 弹层/对话框阴影（= UtenElevation.high）
  static List<BoxShadow> popoverShadow({bool isDark = false}) =>
      UtenElevation.high(isDark: isDark);
}
