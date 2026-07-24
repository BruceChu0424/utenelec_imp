// 深色主题（v2 - 大厂企业后台范）
// 文档：docs/00-项目准则/08-主题与配色.md
//
// 设计原则：
// - 深色背景（接近黑、带冷调），不铺品牌色
// - 卡片用 slate-800/900 区分，靠边框和阴影分层
// - 主色青绿（在深色下深绿会糊，改用青绿作为 primary 提亮）
// - 文字用三档 slate 反相色

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'uten_colors.dart';

ThemeData buildDarkTheme() {
  const colorScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: UtenColors.teal400,
    onPrimary: UtenColors.teal950,
    primaryContainer: UtenColors.teal900,
    onPrimaryContainer: UtenColors.teal100,
    secondary: UtenColors.teal400,
    onSecondary: UtenColors.teal950,
    secondaryContainer: UtenColors.teal900,
    onSecondaryContainer: UtenColors.teal100,
    tertiary: UtenColors.teal500,
    onTertiary: UtenColors.teal950,
    tertiaryContainer: UtenColors.teal900,
    onTertiaryContainer: UtenColors.teal100,
    error: Color(0xFFFCA5A5),
    onError: Color(0xFF450A0A),
    errorContainer: Color(0xFF7F1D1D),
    onErrorContainer: Color(0xFFFECACA),
    surface: UtenColors.darkSurface,
    onSurface: UtenColors.darkTextPrimary,
    surfaceContainerLowest: UtenColors.darkBackground,
    surfaceContainerLow: UtenColors.darkSurface,
    surfaceContainer: UtenColors.darkSurfaceLow,
    surfaceContainerHigh: UtenColors.darkSurfaceHigh,
    surfaceContainerHighest: Color(0xFF475569),
    onSurfaceVariant: UtenColors.darkTextSecondary,
    outline: UtenColors.darkBorderStrong,
    outlineVariant: UtenColors.darkBorder,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: UtenColors.slate100,
    onInverseSurface: UtenColors.slate900,
    inversePrimary: UtenColors.teal800,
    surfaceTint: UtenColors.teal400,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: UtenColors.darkBackground,
    canvasColor: UtenColors.darkBackground,
    visualDensity: VisualDensity.adaptivePlatformDensity,

    textTheme: const TextTheme(
      displayLarge: TextStyle(
        fontSize: 48, fontWeight: FontWeight.w700,
        color: UtenColors.darkTextPrimary, height: 1.1, letterSpacing: -0.5,
      ),
      displayMedium: TextStyle(
        fontSize: 36, fontWeight: FontWeight.w700,
        color: UtenColors.darkTextPrimary, height: 1.15, letterSpacing: -0.3,
      ),
      displaySmall: TextStyle(
        fontSize: 28, fontWeight: FontWeight.w700,
        color: UtenColors.darkTextPrimary, height: 1.2, letterSpacing: -0.2,
      ),
      headlineLarge: TextStyle(
        fontSize: 24, fontWeight: FontWeight.w700,
        color: UtenColors.darkTextPrimary, height: 1.3, letterSpacing: -0.3,
      ),
      headlineMedium: TextStyle(
        fontSize: 20, fontWeight: FontWeight.w600,
        color: UtenColors.darkTextPrimary, height: 1.35, letterSpacing: -0.2,
      ),
      headlineSmall: TextStyle(
        fontSize: 18, fontWeight: FontWeight.w600,
        color: UtenColors.darkTextPrimary, height: 1.4, letterSpacing: -0.2,
      ),
      titleLarge: TextStyle(
        fontSize: 16, fontWeight: FontWeight.w600,
        color: UtenColors.darkTextPrimary, height: 1.4, letterSpacing: -0.2,
      ),
      titleMedium: TextStyle(
        fontSize: 14, fontWeight: FontWeight.w600,
        color: UtenColors.darkTextPrimary, height: 1.4,
      ),
      titleSmall: TextStyle(
        fontSize: 13, fontWeight: FontWeight.w600,
        color: UtenColors.darkTextPrimary, height: 1.4,
      ),
      bodyLarge: TextStyle(
        fontSize: 15, fontWeight: FontWeight.w400,
        color: UtenColors.darkTextPrimary, height: 1.5,
      ),
      bodyMedium: TextStyle(
        fontSize: 14, fontWeight: FontWeight.w400,
        color: UtenColors.darkTextPrimary, height: 1.5,
      ),
      bodySmall: TextStyle(
        fontSize: 13, fontWeight: FontWeight.w400,
        color: UtenColors.darkTextSecondary, height: 1.45,
      ),
      labelLarge: TextStyle(
        fontSize: 14, fontWeight: FontWeight.w600,
        color: UtenColors.darkTextPrimary, height: 1.4,
      ),
      labelMedium: TextStyle(
        fontSize: 12, fontWeight: FontWeight.w600,
        color: UtenColors.darkTextSecondary, height: 1.4,
      ),
      labelSmall: TextStyle(
        fontSize: 11, fontWeight: FontWeight.w500,
        color: UtenColors.darkTextTertiary, height: 1.4,
      ),
    ),

    appBarTheme: const AppBarTheme(
      backgroundColor: UtenColors.darkBackground,
      foregroundColor: UtenColors.darkTextPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: UtenColors.darkTextPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
      systemOverlayStyle: SystemUiOverlayStyle.light,
    ),

    cardTheme: CardThemeData(
      color: UtenColors.darkSurface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: UtenColors.darkBorder),
      ),
    ),

    dividerTheme: const DividerThemeData(
      color: UtenColors.darkBorder,
      thickness: 1,
      space: 1,
    ),

    // 叠加态与浅色主题一致：实心叠 teal700，线框/文字叠 teal400（深色下更亮）
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: UtenColors.teal500,
        foregroundColor: UtenColors.teal950,
        disabledBackgroundColor: UtenColors.darkSurfaceHigh,
        disabledForegroundColor: UtenColors.darkTextTertiary,
        overlayColor: UtenColors.teal700,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: UtenColors.teal500,
        foregroundColor: UtenColors.teal950,
        disabledBackgroundColor: UtenColors.darkSurfaceHigh,
        disabledForegroundColor: UtenColors.darkTextTertiary,
        overlayColor: UtenColors.teal700,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: UtenColors.darkTextPrimary,
        backgroundColor: UtenColors.darkSurface,
        disabledForegroundColor: UtenColors.darkTextTertiary,
        overlayColor: UtenColors.teal400,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: const BorderSide(color: UtenColors.darkBorderStrong),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: UtenColors.teal400,
        overlayColor: UtenColors.teal400,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: const Size(0, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: UtenColors.darkTextSecondary,
        minimumSize: const Size(40, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: UtenColors.darkSurface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide:
            const BorderSide(color: UtenColors.darkBorderStrong),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide:
            const BorderSide(color: UtenColors.darkBorderStrong),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: UtenColors.teal400, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: UtenColors.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: UtenColors.error, width: 2),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: UtenColors.darkBorder),
      ),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      hintStyle: TextStyle(
        color: UtenColors.darkTextTertiary.withValues(alpha: 0.7),
        fontSize: 14,
      ),
      labelStyle: const TextStyle(
        color: UtenColors.darkTextSecondary,
        fontSize: 14,
      ),
    ),

    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: UtenColors.darkSurface,
      elevation: 0,
      height: 64,
      indicatorColor: UtenColors.teal900.withValues(alpha: 0.5),
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color:
              selected ? UtenColors.teal400 : UtenColors.darkTextTertiary,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 22,
          color:
              selected ? UtenColors.teal400 : UtenColors.darkTextTertiary,
        );
      }),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: UtenColors.darkSurface,
      elevation: 0,
      indicatorColor: UtenColors.teal900.withValues(alpha: 0.5),
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      selectedIconTheme:
          const IconThemeData(color: UtenColors.teal400, size: 22),
      unselectedIconTheme:
          const IconThemeData(color: UtenColors.darkTextTertiary, size: 22),
      selectedLabelTextStyle: const TextStyle(
        color: UtenColors.teal400,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: const TextStyle(
        color: UtenColors.darkTextTertiary,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: UtenColors.darkSurfaceLow,
      selectedColor: UtenColors.teal900,
      labelStyle: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: UtenColors.darkTextSecondary,
      ),
      side: const BorderSide(color: UtenColors.darkBorder),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: UtenColors.darkSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: UtenColors.darkBorder),
      ),
      titleTextStyle: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: UtenColors.darkTextPrimary,
      ),
      contentTextStyle: const TextStyle(
        fontSize: 14,
        color: UtenColors.darkTextSecondary,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: UtenColors.slate100,
      contentTextStyle:
          const TextStyle(color: UtenColors.slate900, fontSize: 14),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),

    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      titleTextStyle: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: UtenColors.darkTextPrimary,
      ),
      subtitleTextStyle: TextStyle(
        fontSize: 12,
        color: UtenColors.darkTextSecondary,
      ),
    ),

    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: UtenColors.teal400,
      linearTrackColor: UtenColors.darkSurfaceHigh,
      circularTrackColor: UtenColors.darkSurfaceHigh,
    ),

    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: UtenColors.teal500,
      foregroundColor: UtenColors.teal950,
      elevation: 2,
      highlightElevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      extendedTextStyle:
          const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return Colors.white;
        return UtenColors.darkTextTertiary;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return UtenColors.teal600;
        return UtenColors.darkSurfaceHigh;
      }),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),

    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return UtenColors.teal400;
        return Colors.transparent;
      }),
      checkColor: WidgetStateProperty.all(UtenColors.darkBackground),
      side: const BorderSide(color: UtenColors.darkBorderStrong, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
    ),

    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return UtenColors.teal400;
        return UtenColors.darkBorderStrong;
      }),
    ),

    tabBarTheme: const TabBarThemeData(
      labelColor: UtenColors.darkTextPrimary,
      unselectedLabelColor: UtenColors.darkTextSecondary,
      labelStyle:
          TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      unselectedLabelStyle:
          TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(color: UtenColors.teal400, width: 2),
      ),
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: UtenColors.darkBorder,
    ),
  );
}
