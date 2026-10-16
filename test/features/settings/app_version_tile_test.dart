import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/settings/widgets/app_version_tile.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    String version = 'v2.5.6',
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
    expect(find.text('版本更新 · v2.5.6'), findsOneWidget);
    expect(find.textContaining('人事证件核对支持勾选多人'), findsOneWidget);
    expect(find.textContaining('物料下单保留完整精度'), findsOneWidget);
    expect(find.textContaining('AI 使用权限改为单独授权'), findsOneWidget);
    expect(find.textContaining('修改敏感权限时需要再次验证身份'), findsOneWidget);
    expect(find.textContaining('统一应用和安装包的版本信息'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('unknown release never shows the current release notes', (
    tester,
  ) async {
    await pump(tester, version: 'v9.9.9');
    expect(find.text('此版本暂未附带更新说明。'), findsOneWidget);
    expect(find.textContaining('人事证件核对支持勾选多人'), findsNothing);
    expect(find.textContaining('物料下单保留完整精度'), findsNothing);
  });

  testWidgets('2.5.17 shows only its own business release notes', (
    tester,
  ) async {
    await pump(tester, version: 'v2.5.17');
    final l10n = AppLocalizations.of(
      tester.element(find.byType(AppVersionTile)),
    );
    expect(find.text('版本更新 · v2.5.17'), findsOneWidget);
    for (final note in [
      l10n.release2517PickerLayout,
      l10n.release2517Lifecycle,
      l10n.release2517Paging,
      l10n.release2517Drafts,
    ]) {
      expect(find.textContaining(note), findsOneWidget);
    }
    expect(find.textContaining(l10n.release2511Platform), findsNothing);
    expect(find.textContaining(l10n.release254QuantityPrecision), findsNothing);
    await tester.tap(find.text(l10n.releaseNotesClose));
    await tester.pumpAndSettle();
    await pump(tester, version: 'v2.5.16');
    expect(find.text(l10n.releaseNotesUnavailable), findsOneWidget);
    expect(find.textContaining(l10n.release2517Lifecycle), findsNothing);
  });

  testWidgets(
    '2.5.18 shows only its own company operations and material notes',
    (tester) async {
      await pump(tester, version: 'v2.5.18');
      final l10n = AppLocalizations.of(
        tester.element(find.byType(AppVersionTile)),
      );
      expect(find.text('版本更新 · v2.5.18'), findsOneWidget);
      for (final note in [
        l10n.release2518ServerUpdates,
        l10n.release2518Storage,
        l10n.release2518CompanyConnections,
        l10n.release2518LayoutAndTrace,
      ]) {
        expect(find.textContaining(note), findsOneWidget);
      }
      expect(find.textContaining(l10n.release2517Lifecycle), findsNothing);
      expect(find.textContaining(l10n.release2511Platform), findsNothing);
      await tester.tap(find.text(l10n.releaseNotesClose));
      await tester.pumpAndSettle();
      await pump(tester, version: 'v2.5.17');
      expect(find.textContaining(l10n.release2517Lifecycle), findsOneWidget);
      expect(find.textContaining(l10n.release2518ServerUpdates), findsNothing);
    },
  );

  for (final release in ['2.5.17', '2.5.18']) {
    for (final language in ['zh', 'en', 'ko']) {
      testWidgets(
        '$release $language notes remain localized and usable on a narrow screen',
        (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          for (final brightness in Brightness.values) {
            await pump(
              tester,
              version: release,
              locale: Locale(language),
              scale: 1.6,
              brightness: brightness,
            );
            final l10n = AppLocalizations.of(
              tester.element(find.byType(AppVersionTile)),
            );
            for (final note
                in release == '2.5.17'
                    ? [
                        l10n.release2517PickerLayout,
                        l10n.release2517Lifecycle,
                        l10n.release2517Paging,
                        l10n.release2517Drafts,
                      ]
                    : [
                        l10n.release2518ServerUpdates,
                        l10n.release2518Storage,
                        l10n.release2518CompanyConnections,
                        l10n.release2518LayoutAndTrace,
                      ]) {
              expect(find.textContaining(note), findsOneWidget);
            }
            if (language != 'zh') {
              expect(find.textContaining('选择滑窗的清空'), findsNothing);
            }
            await tester.drag(
              find.byType(SingleChildScrollView),
              const Offset(0, -10000),
            );
            await tester.pumpAndSettle();
            expect(
              find.text(l10n.releaseNotesClose).hitTestable(),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
            await tester.tap(find.text(l10n.releaseNotesClose));
            await tester.pumpAndSettle();
          }
        },
      );
    }
  }

  test('the default client version matches the package release version', () {
    final packageVersion = RegExp(
      r'^version:\s+([0-9]+\.[0-9]+\.[0-9]+)(?:\+[0-9]+)?\s*$',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync());
    expect(
      packageVersion,
      isNotNull,
      reason: 'The package needs a release version',
    );
    final expected = const bool.hasEnvironment('APP_VERSION')
        ? const String.fromEnvironment('APP_VERSION')
        : packageVersion!.group(1);
    expect(const AppVersionTile().version, expected);
  });

  testWidgets('2.5.3 retains its own notes without later release fixes', (
    tester,
  ) async {
    await pump(tester, version: 'v2.5.3');
    expect(find.text('版本更新 · v2.5.3'), findsOneWidget);
    expect(find.textContaining('人事证件核对支持勾选多人'), findsOneWidget);
    expect(find.textContaining('物料下单保留完整精度'), findsNothing);
    expect(find.textContaining('AI 使用权限改为单独授权'), findsNothing);
  });

  testWidgets('a similar version never borrows 2.5.6 notes', (tester) async {
    await pump(tester, version: 'v2.5.60');
    expect(find.text('此版本暂未附带更新说明。'), findsOneWidget);
    expect(find.textContaining('物料下单保留完整精度'), findsNothing);
  });

  testWidgets('large text on a narrow screen scrolls in both themes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final brightness in Brightness.values) {
      await pump(tester, version: '2.5.6', scale: 2, brightness: brightness);
      expect(tester.takeException(), isNull);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -10000),
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
      final l10n = AppLocalizations.of(
        tester.element(find.byType(AppVersionTile)),
      );
      for (final note in [
        l10n.release253Hr,
        l10n.release253Materials,
        l10n.release254QuantityPrecision,
        l10n.release254AiAuthorization,
        l10n.release254SensitiveAuthorization,
        l10n.release254Publishing,
      ]) {
        expect(find.textContaining(note), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
