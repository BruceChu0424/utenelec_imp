// Uten 品牌色板
// 文档：docs/00-项目准则/08-主题与配色.md
// 决策：ADR-004-品牌色深绿青绿.md
//
// 设计原则：
// 1. 背景走中性灰阶（slate），不铺品牌色
// 2. 浅色模式交互主色统一用深森林绿，青绿仅用于深色模式和语义强调
// 3. 卡片/容器用白色或浅中性色，靠细边框 + 极轻阴影分层
// 4. 文字用 slate-900 / slate-600 / slate-400 三档建立层级

import 'package:flutter/material.dart';

/// Uten 品牌色板常量
abstract final class UtenColors {
  // ===== 品牌主色 =====
  /// 浅色模式交互主色：深森林绿
  static const Color primary = Color(0xFF0F3D2E);

  /// 品牌深森林绿
  static const Color deepGreen = Color(0xFF0F3D2E);

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

  // ===== 中性灰阶（slate）=====
  static const Color background = Color(0xFFF8FAFC);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceLow = Color(0xFFF8FAFC);
  static const Color surfaceMid = Color(0xFFF1F5F9);
  static const Color surfaceHigh = Color(0xFFE2E8F0);

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

  // ===== 深色主题专用 =====
  static const Color darkBackground = Color(0xFF0B1120);
  static const Color darkSurface = Color(0xFF111827);
  static const Color darkSurfaceLow = Color(0xFF1E293B);
  static const Color darkSurfaceHigh = Color(0xFF334155);
  static const Color darkBorder = Color(0xFF1E293B);
  static const Color darkBorderStrong = Color(0xFF334155);

  /// 深色文字
  static const Color darkTextPrimary = Color(0xFFF1F5F9);
  static const Color darkTextSecondary = Color(0xFF94A3B8);
  static const Color darkTextTertiary = Color(0xFF64748B);

  // ===== 阴影 token =====
  static List<BoxShadow> cardShadow({bool isDark = false}) => [
    BoxShadow(
      color: isDark
          ? const Color(0xFF000000).withValues(alpha: 0.3)
          : const Color(0xFF0F172A).withValues(alpha: 0.04),
      blurRadius: 1,
      offset: const Offset(0, 1),
    ),
  ];

  static List<BoxShadow> cardShadowLg({bool isDark = false}) => [
    BoxShadow(
      color: isDark
          ? const Color(0xFF000000).withValues(alpha: 0.4)
          : const Color(0xFF0F172A).withValues(alpha: 0.08),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
  ];

  static List<BoxShadow> popoverShadow({bool isDark = false}) => [
    BoxShadow(
      color: isDark
          ? const Color(0xFF000000).withValues(alpha: 0.5)
          : const Color(0xFF0F172A).withValues(alpha: 0.12),
      blurRadius: 16,
      offset: const Offset(0, 8),
    ),
  ];
}
