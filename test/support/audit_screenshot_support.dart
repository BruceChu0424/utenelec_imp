import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> loadAuditScreenshotFonts(WidgetTester tester) =>
    tester.runAsync(() async {
      final fontData = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
      for (final family in ['NotoSansSC', 'Roboto']) {
        await (FontLoader(family)..addFont(Future.value(fontData))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });

Future<void> saveAuditScreenshot(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/ui-audit')..createSync(recursive: true);
    File(
      '${directory.path}/$name.png',
    ).writeAsBytesSync(png!.buffer.asUint8List());
    image.dispose();
  });
}

// Widget tests inject the block-shaped Ahem font into default Material styles.
// For optional screenshots, preserve every runtime style property and resolve
// the test-only missing-family fallback to the application's bundled font.
ThemeData auditScreenshotTheme(ThemeData theme) {
  TextStyle withFont(TextStyle? style) =>
      (style ?? const TextStyle()).copyWith(fontFamily: 'NotoSansSC');
  ButtonStyle button(ButtonStyle? style) =>
      (style ?? const ButtonStyle()).copyWith(
        textStyle: WidgetStatePropertyAll(
          withFont(style?.textStyle?.resolve({})),
        ),
      );
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamily: 'NotoSansSC'),
    primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: 'NotoSansSC'),
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: withFont(theme.appBarTheme.titleTextStyle),
    ),
    chipTheme: theme.chipTheme.copyWith(
      labelStyle: withFont(
        theme.chipTheme.labelStyle ?? theme.textTheme.labelLarge,
      ),
      secondaryLabelStyle: withFont(
        theme.chipTheme.secondaryLabelStyle ?? theme.textTheme.labelLarge,
      ),
    ),
    listTileTheme: theme.listTileTheme.copyWith(
      titleTextStyle: withFont(
        theme.listTileTheme.titleTextStyle ?? theme.textTheme.titleMedium,
      ),
      subtitleTextStyle: withFont(
        theme.listTileTheme.subtitleTextStyle ?? theme.textTheme.bodyMedium,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: button(theme.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: button(theme.textButtonTheme.style),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: button(theme.filledButtonTheme.style),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: button(theme.elevatedButtonTheme.style),
    ),
  );
}
