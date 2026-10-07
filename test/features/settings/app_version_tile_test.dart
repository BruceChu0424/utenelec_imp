import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/settings/widgets/app_version_tile.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    String version = 'v2.5.3',
    Locale locale = const Locale('zh'),
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(body: AppVersionTile(version: version)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(version));
    await tester.pumpAndSettle();
  }

  testWidgets('installed version opens its notes and can be dismissed', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('版本更新 · v2.5.3'), findsOneWidget);
    expect(find.textContaining('人事证件核对支持勾选多人'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('unknown release never shows the current release notes', (
    tester,
  ) async {
    await pump(tester, version: 'v2.5.4');
    expect(find.text('此版本暂未附带更新说明。'), findsOneWidget);
    expect(find.textContaining('人事证件核对支持勾选多人'), findsNothing);
  });

  testWidgets('large text on a narrow screen scrolls in both themes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final brightness in Brightness.values) {
      await pump(tester, version: '2.5.3', scale: 2, brightness: brightness);
      expect(tester.takeException(), isNull);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -1800),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('知道了').hitTestable(), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
    }
  });

  for (final language in ['en', 'ko']) {
    testWidgets('$language notes are localized', (tester) async {
      await pump(tester, locale: Locale(language));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('人事证件核对支持勾选多人'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
