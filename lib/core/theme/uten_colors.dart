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
  /// 交互主色：teal500（青绿），浅色 / 深色模式共用
  static const Color primary = teal500;

  /// 品牌深绿（兼容旧引用，现等同于 teal500）
  static const Color deepGreen = teal500;

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

  /// 语义色柔和底色（徽章、提示条、浅色高亮块）
  static const Color successBg = Color(0xFFECFDF5);
  static const Color warningBg = Color(0xFFFFFBEB);
  static const Color infoBg = Color(0xFFEFF6FF);

  /// 品牌青绿柔和底色（= teal50），用于选中态、高亮块
  static const Color tealSurface = teal50;

  /// 语义色深档文字色（配合 *Bg 底色使用，保证对比度）
  static const Color successText = Color(0xFF047857);
  static const Color warningText = Color(0xFFB45309);
  static const Color infoText = Color(0xFF1D4ED8);
  static const Color errorText = Color(0xFFB91C1C);

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
