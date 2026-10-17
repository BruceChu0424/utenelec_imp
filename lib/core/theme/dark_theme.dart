// 深色主题与 Material 组件全局样式。
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
import 'uten_tokens.dart';
import 'uten_typography.dart';
import 'uten_category_tab_theme.dart';
import 'uten_page_transitions.dart';
import '../../shared/platform_branding/platform_branding.dart';
import 'brand_theme.dart';

ThemeData buildDarkTheme({PlatformBranding? branding}) {
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

  final textTheme = buildUtenTextTheme(
    primary: UtenColors.darkTextPrimary,
    secondary: UtenColors.darkTextSecondary,
    tertiary: UtenColors.darkTextTertiary,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    fontFamily: 'NotoSansSC',
    scaffoldBackgroundColor: UtenColors.darkBackground,
    canvasColor: UtenColors.darkBackground,
    visualDensity: VisualDensity.adaptivePlatformDensity,
    // Web/桌面轻量淡入、移动端平台默认, 全部登记转场进行态(ADR-108)。
    pageTransitionsTheme: utenPageTransitionsTheme(),

    textTheme: textTheme,

    appBarTheme: const AppBarTheme(
      backgroundColor: UtenColors.darkBackground,
      foregroundColor: UtenColors.darkTextPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'NotoSansSC',
        color: UtenColors.darkTextPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
      systemOverlayStyle: SystemUiOverlayStyle.light,
    ),

    cardTheme: CardThemeData(
      clipBehavior: Clip.antiAlias,
      color: UtenColors.darkSurface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UtenRadius.card),
        side: const BorderSide(color: UtenColors.darkBorder),
      ),
    ),

    dividerTheme: const DividerThemeData(
      color: UtenColors.darkBorder,
      thickness: 1,
      space: 1,
    ),

    // 滚动条：深色下默认滚动条更淡，同浅色主题一并加深（问题 #10）。
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.dragged) ||
            states.contains(WidgetState.hovered)) {
          return UtenColors.slate300.withValues(alpha: 0.75);
        }
        return UtenColors.slate400.withValues(alpha: 0.55);
      }),
      trackColor: WidgetStateProperty.all(
        UtenColors.darkSurfaceHigh.withValues(alpha: 0.6),
      ),
      trackBorderColor: WidgetStateProperty.all(Colors.transparent),
      thickness: WidgetStateProperty.all(10),
      radius: const Radius.circular(UtenRadius.sm),
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        minimumSize: const Size(0, UtenControlMetrics.standardHeight),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UtenRadius.control),
        ),
        textStyle: const TextStyle(
          fontFamily: 'NotoSansSC',
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        minimumSize: const Size(0, UtenControlMetrics.standardHeight),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UtenRadius.control),
        ),
        textStyle: const TextStyle(
          fontFamily: 'NotoSansSC',
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: UtenColors.darkTextPrimary,
        backgroundColor: UtenColors.darkSurface,
        disabledForegroundColor: UtenColors.darkTextTertiary,
        overlayColor: UtenColors.teal400,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        minimumSize: const Size(0, UtenControlMetrics.standardHeight),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UtenRadius.control),
        ),
        side: const BorderSide(color: UtenColors.darkBorderStrong),
        textStyle: const TextStyle(
          fontFamily: 'NotoSansSC',
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: UtenColors.teal400,
        overlayColor: UtenColors.teal400,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: const Size(0, 40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UtenRadius.control),
        ),
        textStyle: const TextStyle(
          fontFamily: 'NotoSansSC',
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: UtenColors.darkTextSecondary,
        minimumSize: const Size(40, 40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UtenRadius.control),
        ),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      floatingLabelBehavior: FloatingLabelBehavior.auto,
      visualDensity: VisualDensity.standard,
      filled: true,
      fillColor: UtenColors.darkSurface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(UtenRadius.control),
        borderSide: const BorderSide(color: UtenColors.darkBorderStrong),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(UtenRadius.control),
        borderSide: const BorderSide(color: UtenColors.darkBorderStrong),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(UtenRadius.control),
        borderSide: const BorderSide(color: UtenColors.teal400, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(UtenRadius.control),
        borderSide: const BorderSide(color: UtenColors.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(UtenRadius.control),
        borderSide: const BorderSide(color: UtenColors.error, width: 2),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(UtenRadius.control),
        borderSide: const BorderSide(color: UtenColors.darkBorder),
      ),
      isDense: true,
      constraints: const BoxConstraints(minHeight: UtenPageField.minHeight),
      contentPadding: UtenPageField.contentPadding,
      prefixIconConstraints: UtenPageField.iconConstraints,
      suffixIconConstraints: UtenPageField.iconConstraints,
      hintStyle: const TextStyle(
        fontFamily: 'NotoSansSC',
        color: UtenColors.darkTextSecondary,
        fontSize: 16,
      ),
      labelStyle: const TextStyle(
        fontFamily: 'NotoSansSC',
        color: UtenColors.darkTextSecondary,
        fontSize: 14,
      ),
      // 2026-10-10 用户口径：单位后缀用正文色（深色=近白），与浅色主题成对。
      suffixStyle: const TextStyle(
        fontFamily: 'NotoSansSC',
        color: UtenColors.darkTextPrimary,
        fontSize: 14,
      ),
    ),

    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: UtenColors.darkSurface,
      elevation: 0,
      height: 64,
      indicatorColor: UtenColors.teal900.withValues(alpha: 0.5),
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UtenRadius.control),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontFamily: 'NotoSansSC',
          fontSize: 13,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? UtenColors.teal400 : UtenColors.darkTextTertiary,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 22,
          color: selected ? UtenColors.teal400 : UtenColors.darkTextTertiary,
        );
      }),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: UtenColors.darkSurface,
      elevation: 0,
      indicatorColor: UtenColors.teal900.withValues(alpha: 0.5),
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UtenRadius.control),
      ),
      selectedIconTheme: const IconThemeData(
        color: UtenColors.teal400,
        size: 22,
      ),
      unselectedIconTheme: const IconThemeData(
        color: UtenColors.darkTextTertiary,
        size: 22,
      ),
      selectedLabelTextStyle: const TextStyle(
        fontFamily: 'NotoSansSC',
        color: UtenColors.teal400,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: const TextStyle(
        fontFamily: 'NotoSansSC',
        color: UtenColors.darkTextTertiary,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: UtenColors.darkSurfaceLow,
      selectedColor: UtenColors.teal900,
      labelStyle: const TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: UtenColors.darkTextSecondary,
      ),
      side: const BorderSide(color: UtenColors.darkBorder),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UtenRadius.control),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: UtenColors.darkSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UtenRadius.dialog),
        side: const BorderSide(color: UtenColors.darkBorder),
      ),
      titleTextStyle: const TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: UtenColors.darkTextPrimary,
      ),
      contentTextStyle: const TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: 16,
        color: UtenColors.darkTextSecondary,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: UtenColors.slate100,
      contentTextStyle: const TextStyle(
        fontFamily: 'NotoSansSC',
        color: UtenColors.slate900,
        fontSize: 14,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UtenRadius.lg),
      ),
    ),

    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      titleTextStyle: TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: UtenColors.darkTextPrimary,
      ),
      subtitleTextStyle: TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: 13,
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UtenRadius.control),
      ),
      extendedTextStyle: const TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UtenRadius.xs),
      ),
    ),

    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return UtenColors.teal400;
        return UtenColors.darkBorderStrong;
      }),
    ),

    tabBarTheme: buildUtenCategoryTabTheme(colorScheme, textTheme),
  );
  return applyPlatformBrandTheme(base, branding ?? PlatformBranding.defaults);
}
