import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';

void main() {
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    for (final width in [375.0, 1200.0]) {
      testWidgets(
        '${platform.name} $width back padding is clickable and left aligned',
        (tester) async {
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          var taps = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: buildLightTheme().copyWith(platform: platform),
              home: UtenControlTheme(
                child: Scaffold(
                  appBar: UtenAppBar(
                    title: 'Page title',
                    showPagePermissionAction: false,
                    leading: UtenBackButton(onPressed: () => taps++),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final back = tester.getRect(find.byType(UtenBackButton));
          final icon = tester.getRect(
            find.byIcon(Icons.arrow_back_ios_new_rounded),
          );
          final title = tester.getRect(find.text('Page title'));
          final touch = platform == TargetPlatform.android || width < 600;
          expect(back.width, touch ? 48 : 40);
          expect(back.height, greaterThanOrEqualTo(touch ? 48 : 40));
          expect(icon.left, 0);
          expect(icon.width, 24);
          expect(title.left, back.right);
          // Click all four edges, including the old dead space beside the arrow.
          for (final point in [
            Offset(back.right - 1, back.center.dy),
            Offset(back.left + 1, back.center.dy),
            Offset(back.center.dx, back.top + 2),
            Offset(back.center.dx, back.bottom - 2),
          ]) {
            await tester.tapAt(point);
            await tester.pumpAndSettle();
          }
          expect(taps, 4);
          await tester.tapAt(Offset(title.left + 2, title.center.dy));
          expect(taps, 4, reason: 'The title is outside the back action.');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('touch back width survives a smaller display preference', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme().copyWith(platform: TargetPlatform.android),
        home: UtenDisplayZoomBox(
          fontFactor: 0.8,
          child: UtenControlTheme(
            child: Scaffold(
              appBar: UtenAppBar(
                title: 'Page title',
                showPagePermissionAction: false,
                leading: UtenBackButton(onPressed: () => taps++),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final back = tester.getRect(find.byType(UtenBackButton));
    expect(back.width, greaterThanOrEqualTo(48));
    await tester.tapAt(Offset(back.right - 1, back.center.dy));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'automatic back pops from its trailing edge and disabled back stays inert',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/source',
        routes: [
          GoRoute(
            path: '/source',
            builder: (_, _) => const Scaffold(body: Text('source')),
          ),
          GoRoute(
            path: '/detail',
            builder: (_, _) => const Scaffold(
              appBar: UtenAppBar(
                title: 'Detail',
                showBackButton: true,
                showPagePermissionAction: false,
              ),
            ),
          ),
          GoRoute(
            path: '/blocked',
            builder: (_, _) => const Scaffold(
              appBar: UtenAppBar(
                title: 'Saving',
                leading: UtenBackButton(enabled: false),
                showPagePermissionAction: false,
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      router.push<void>('/detail');
      await tester.pumpAndSettle();
      final back = tester.getRect(find.byType(UtenBackButton));
      await tester.tapAt(Offset(back.right - 1, back.center.dy));
      await tester.pumpAndSettle();
      expect(find.text('source'), findsOneWidget);
      router.push<void>('/blocked');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(UtenBackButton));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Saving'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
