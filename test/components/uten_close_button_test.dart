import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';

void main() {
  for (final platform in TargetPlatform.values) {
    for (final dark in [false, true]) {
      testWidgets('${platform.name} dark=$dark keeps the same close contract', (
        tester,
      ) async {
        var closes = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: (dark ? buildDarkTheme() : buildLightTheme()).copyWith(
              platform: platform,
            ),
            home: Scaffold(
              body: Center(child: UtenCloseButton(onPressed: () => closes++)),
            ),
          ),
        );
        final close = find.byType(UtenCloseButton);
        final icon = find.byIcon(Icons.close_rounded);
        final circle = tester.widget<Container>(
          find.descendant(of: close, matching: find.byType(Container)),
        );
        expect((circle.decoration! as BoxDecoration).shape, BoxShape.circle);
        expect((circle.decoration! as BoxDecoration).color, UtenColors.error);
        expect(tester.widget<Icon>(icon).color, Colors.white);
        expect(tester.getSize(find.byType(Container)), const Size.square(28));
        final touch = [
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.fuchsia,
        ].contains(platform);
        expect(tester.getSize(close), Size.square(touch ? 48 : 40));
        await tester.tap(close);
        expect(closes, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('keyboard focus is visible and activates the supplied callback', (
    tester,
  ) async {
    var closes = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(body: UtenCloseButton(onPressed: () => closes++)),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final button = tester.widget<IconButton>(find.byType(IconButton));
    expect(button.style!.side!.resolve({WidgetState.focused})!.width, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(closes, 1);
  });

  testWidgets('busy owners can disable closing without a navigation fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: UtenCloseButton(onPressed: null))),
    );
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    await tester.tap(find.byType(UtenCloseButton));
    expect(find.byType(UtenCloseButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('async close confirmation accepts one activation at a time', (
    tester,
  ) async {
    final confirmation = Completer<void>();
    var closes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenCloseButton(
            onPressed: () async {
              closes++;
              await confirmation.future;
            },
          ),
        ),
      ),
    );
    // Cover repeated invocation before the disabled state has rebuilt.
    final press = tester.widget<IconButton>(find.byType(IconButton)).onPressed!;
    press();
    press();
    await tester.pump();
    expect(closes, 1);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    confirmation.complete();
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNotNull,
    );
    await tester.tap(find.byType(UtenCloseButton));
    await tester.pumpAndSettle();
    expect(closes, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native strip preserves login geometry and control roles', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              UtenCloseButton(native: true, onPressed: () {}),
              UtenWindowControlButton.minimize(onPressed: () {}),
              UtenWindowControlButton.expand(expanded: true, onPressed: () {}),
            ],
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(UtenCloseButton)), const Size(30, 36));
    expect(
      tester.getSize(
        find.descendant(
          of: find.byType(UtenCloseButton),
          matching: find.byType(Container),
        ),
      ),
      const Size.square(22),
    );
    expect(find.byIcon(Icons.remove_rounded), findsOneWidget);
    expect(find.byIcon(Icons.filter_none_rounded), findsOneWidget);
    expect(find.byTooltip('Restore'), findsOneWidget);
  });

  testWidgets('narrow web layouts retain touch-sized controls', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(375, 700)),
          child: Scaffold(body: UtenCloseButton(onPressed: () {})),
        ),
      ),
    );
    expect(tester.getSize(find.byType(UtenCloseButton)), const Size.square(48));
  });
}
