import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_empty.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

Future<void> _pump(
  WidgetTester tester, {
  required ThemeData theme,
  VoidCallback? onAction,
  Size size = const Size(800, 600),
  double textScale = 1,
  bool longText = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: UtenEmpty.error(
          message: longText
              ? 'Unable to load the latest report'
              : 'Loading failed',
          description: longText
              ? 'Check your connection and try loading the report again.'
              : null,
          actionLabel: 'Retry',
          onAction: onAction,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

double _contrast(Color foreground, Color background) {
  final light = foreground.computeLuminance();
  final dark = background.computeLuminance();
  return (math.max(light, dark) + 0.05) / (math.min(light, dark) + 0.05);
}

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'retry keeps readable theme colors and keyboard focus, dark=$dark',
      (tester) async {
        var calls = 0;
        final theme = dark ? buildDarkTheme() : buildLightTheme();
        await _pump(tester, theme: theme, onAction: () => calls++);
        final button = find.byType(OutlinedButton);
        final label = tester.renderObject<RenderParagraph>(find.text('Retry'));
        final foreground = label.text.style!.color!;
        final material = tester.widget<Material>(
          find.descendant(of: button, matching: find.byType(Material)).first,
        );
        final background = material.color!;
        debugPrint(
          'UtenEmpty dark=$dark foreground=${foreground.toARGB32().toRadixString(16)} '
          'background=${background.toARGB32().toRadixString(16)} contrast=${_contrast(foreground, background).toStringAsFixed(2)}',
        );
        expect(_contrast(foreground, background), greaterThanOrEqualTo(4.5));
        expect(tester.getSize(button).height, greaterThanOrEqualTo(44));

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final focusedColor = tester
            .renderObject<RenderParagraph>(find.text('Retry'))
            .text
            .style!
            .color!;
        final focusOverlay = theme.outlinedButtonTheme.style!.overlayColor!
            .resolve({WidgetState.focused})!;
        expect(
          _contrast(focusedColor, Color.alphaBlend(focusOverlay, background)),
          greaterThanOrEqualTo(4.5),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'short viewport keeps large error text and retry reachable, dark=$dark',
      (tester) async {
        var calls = 0;
        await _pump(
          tester,
          theme: dark ? buildDarkTheme() : buildLightTheme(),
          size: const Size(375, 300),
          textScale: 1.5,
          longText: true,
          onAction: () => calls++,
        );
        expect(tester.takeException(), isNull);
        final button = find.byType(OutlinedButton);
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        expect(tester.getRect(button).bottom, lessThanOrEqualTo(300));
        await tester.tap(button);
        expect(calls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'an unavailable action is neither visible nor keyboard executable',
    (tester) async {
      await _pump(tester, theme: buildLightTheme());
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.text('Retry'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an empty state still fits an already scrollable host', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: ListView(
            children: [
              const SizedBox(height: 400),
              UtenEmpty(
                message: 'No results',
                actionLabel: 'Reload',
                onAction: () => calls++,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = find.widgetWithText(OutlinedButton, 'Reload');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });
}
