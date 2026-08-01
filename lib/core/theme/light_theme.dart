// 浅色主题（v2 - 大厂企业后台范）
// 文档：docs/00-项目准则/08-主题与配色.md
//
// 设计原则：
// - 背景中性（slate-50），不铺品牌色
// - 卡片白色 + 细边框（slate-200）+ 极轻阴影
// - 主按钮实心深绿，次要按钮中性
// - 输入框透明背景 + 焦点态品牌色边框
// - 文字用 slate 三档建立层级

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'uten_colors.dart';

ThemeData buildLightTheme() {
  // 浅色模式交互主色：统一使用深色模式下的 teal（青绿）系绿
  // —— 实心交互使用 teal700 + 白字，满足普通文字 WCAG AA 对比度
  const colorScheme = ColorScheme(
    brightness: Brightness.light,
    primary: UtenColors.teal700,
    onPrimary: Colors.white,
    primaryContainer: UtenColors.teal100,
    onPrimaryContainer: UtenColors.teal900,
    secondary: UtenColors.teal400,
    onSecondary: UtenColors.teal950,
    secondaryContainer: UtenColors.teal100,
    onSecondaryContainer: UtenColors.teal900,
    tertiary: UtenColors.teal500,
    onTertiary: UtenColors.teal950,
    tertiaryContainer: UtenColors.teal100,
    onTertiaryContainer: UtenColors.teal900,
    error: UtenColors.errorText,
    onError: Colors.white,
    errorContainer: UtenColors.errorBg,
    onErrorContainer: Color(0xFF7F1D1D),
    surface: UtenColors.surface,
    onSurface: UtenColors.textPrimary,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: UtenColors.surfaceLow,
    surfaceContainer: UtenColors.surfaceMid,
    surfaceContainerHigh: UtenColors.surfaceHigh,
    surfaceContainerHighest: UtenColors.slate300,
    onSurfaceVariant: UtenColors.textSecondary,
    outline: UtenColors.slate400,
    outlineVariant: UtenColors.border,
    shadow: UtenColors.slate900,
    scrim: UtenColors.slate950,
    inverseSurface: UtenColors.slate900,
    onInverseSurface: UtenColors.slate50,
    inversePrimary: UtenColors.teal300,
    surfaceTint: UtenColors.teal700,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: colorScheme,
    fontFamily: 'NotoSansSC',
    scaffoldBackgroundColor: UtenColors.background,
    canvasColor: UtenColors.background,
    visualDensity: VisualDensity.adaptivePlatformDensity,

    // ===== 文字系统（Material type roles）=====
    textTheme: const TextTheme(
      displayLarge: TextStyle(
        fontSize: 48,
        fontWeight: FontWeight.w700,
        color: UtenColors.textPrimary,
        height: 1.1,
        letterSpacing: -0.5,
      ),
      displayMedium: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w700,
        color: UtenColors.textPrimary,
        height: 1.15,
        letterSpacing: -0.3,
      ),
      displaySmall: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: UtenColors.textPrimary,
        height: 1.2,
        letterSpacing: -0.2,
      ),
      headlineLarge: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        color: UtenColors.textPrimary,
        height: 1.3,
        letterSpacing: -0.3,
      ),
      headlineMedium: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: UtenColors.textPrimary,
        height: 1.35,
        letterSpacing: -0.2,
      ),
      headlineSmall: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: UtenColors.textPrimary,
        height: 1.4,
        letterSpacing: -0.2,
      ),
      titleLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: UtenColors.textPrimary,
        height: 1.4,
        letterSpacing: -0.2,
      ),
      titleMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: UtenColors.textPrimary,
        height: 1.4,
      ),
      titleSmall: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: UtenColors.textPrimary,
        height: 1.4,
      ),
      bodyLarge: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: UtenColors.textPrimary,
        height: 1.5,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: UtenColors.textPrimary,
        height: 1.5,
      ),
      bodySmall: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: UtenColors.textSecondary,
        height: 1.45,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: UtenColors.textPrimary,
        height: 1.4,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: UtenColors.textSecondary,
        height: 1.4,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: UtenColors.textTertiary,
        height: 1.4,
      ),
    ),

    // ===== AppBar：透明背景 + 细分隔线 =====
    appBarTheme: const AppBarTheme(
      backgroundColor: UtenColors.background,
      foregroundColor: UtenColors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: UtenColors.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
      systemOverlayStyle: SystemUiOverlayStyle.dark,
    ),

    // ===== Card：白底 + 细边框 + 更柔和的 14 圆角 =====
    cardTheme: CardThemeData(
      color: UtenColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: UtenColors.border),
      ),
    ),

    dividerTheme: const DividerThemeData(
      color: UtenColors.divider,
      thickness: 1,
      space: 1,
    ),

    // ===== 按钮：克制、清晰 =====
    // 浅色模式实心按钮使用 teal700，确保白色文字达到 WCAG AA
    // 叠加态（overlayColor）：框架按 hover 8% / pressed 10% 自动派生透明度，
    // 实心按钮叠 teal900，线框/文字按钮叠 teal600
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: UtenColors.teal700,
        foregroundColor: Colors.white,
        disabledBackgroundColor: UtenColors.slate200,
        disabledForegroundColor: UtenColors.slate400,
        overlayColor: UtenColors.teal900,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: UtenColors.teal700,
        foregroundColor: Colors.white,
        disabledBackgroundColor: UtenColors.slate200,
        disabledForegroundColor: UtenColors.slate400,
        overlayColor: UtenColors.teal900,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: UtenColors.textPrimary,
        backgroundColor: UtenColors.surface,
        disabledForegroundColor: UtenColors.slate400,
        overlayColor: UtenColors.teal600,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: const BorderSide(color: UtenColors.borderStrong),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: UtenColors.teal600,
        overlayColor: UtenColors.teal600,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: const Size(0, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: UtenColors.textSecondary,
        minimumSize: const Size(40, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),

    // ===== 输入框：透明背景 + 焦点态品牌色 =====
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: UtenColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: UtenColors.borderStrong),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: UtenColors.borderStrong),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: UtenColors.teal700, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: UtenColors.errorText),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: UtenColors.errorText, width: 2),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: UtenColors.border),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      hintStyle: const TextStyle(color: UtenColors.textTertiary, fontSize: 14),
      labelStyle: const TextStyle(
        color: UtenColors.textSecondary,
        fontSize: 14,
      ),
    ),

    // ===== 导航 =====
    // 选中态：teal100 浅底指示器 + teal600 图标/文字（比 teal400 对比度更高，符合 WCAG AA）
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: UtenColors.surface,
      elevation: 0,
      height: 64,
      indicatorColor: UtenColors.teal100,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? UtenColors.teal600 : UtenColors.textTertiary,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 22,
          color: selected ? UtenColors.teal600 : UtenColors.textTertiary,
        );
      }),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: UtenColors.surface,
      elevation: 0,
      indicatorColor: UtenColors.teal100,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      selectedIconTheme: const IconThemeData(
        color: UtenColors.teal600,
        size: 22,
      ),
      unselectedIconTheme: const IconThemeData(
        color: UtenColors.textTertiary,
        size: 22,
      ),
      selectedLabelTextStyle: const TextStyle(
        color: UtenColors.teal600,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: const TextStyle(
        color: UtenColors.textTertiary,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: UtenColors.surfaceMid,
      selectedColor: UtenColors.surfaceMid,
      labelStyle: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: UtenColors.textSecondary,
      ),
      side: const BorderSide(color: UtenColors.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: UtenColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: UtenColors.border),
      ),
      titleTextStyle: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: UtenColors.textPrimary,
      ),
      contentTextStyle: const TextStyle(
        fontSize: 14,
        color: UtenColors.textSecondary,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: UtenColors.slate900,
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),

    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      titleTextStyle: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: UtenColors.textPrimary,
      ),
      subtitleTextStyle: TextStyle(
        fontSize: 12,
        color: UtenColors.textSecondary,
      ),
    ),

    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: UtenColors.teal700,
      linearTrackColor: UtenColors.surfaceHigh,
      circularTrackColor: UtenColors.surfaceHigh,
    ),

    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: UtenColors.teal700,
      foregroundColor: Colors.white,
      elevation: 2,
      highlightElevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      extendedTextStyle: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    ),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return Colors.white;
        return UtenColors.slate400;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return UtenColors.teal700;
        return UtenColors.slate300;
      }),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),

    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return UtenColors.teal700;
        return Colors.transparent;
      }),
      checkColor: WidgetStateProperty.all(Colors.white),
      side: const BorderSide(color: UtenColors.borderStrong, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
    ),

    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return UtenColors.teal700;
        return UtenColors.borderStrong;
      }),
    ),

    tabBarTheme: const TabBarThemeData(
      labelColor: UtenColors.textPrimary,
      unselectedLabelColor: UtenColors.textSecondary,
      labelStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      unselectedLabelStyle: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(color: UtenColors.teal700, width: 2),
      ),
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: UtenColors.border,
    ),
  );
}
