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

  for (final release in ['2.5.17', '2.5.18', '2.5.19', '2.5.20']) {
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
              scale: release == '2.5.20' ? 2 : 1.6,
              brightness: brightness,
            );
            final l10n = AppLocalizations.of(
              tester.element(find.byType(AppVersionTile)),
            );
            final historicalNotes = switch (release) {
              '2.5.17' => [
                l10n.release2517PickerLayout,
                l10n.release2517Lifecycle,
                l10n.release2517Paging,
                l10n.release2517Drafts,
              ],
              '2.5.18' || '2.5.19' => [
                l10n.release2518ServerUpdates,
                l10n.release2518Storage,
                l10n.release2518CompanyConnections,
                l10n.release2518LayoutAndTrace,
              ],
              _ => <String>[],
            };
            for (final note in historicalNotes) {
              expect(find.textContaining(note), findsOneWidget);
            }
            final currentNotes = switch (language) {
              'en' => [
                'Search shows one list across categories',
                'Input, dropdown and date fields share consistent heights',
                'Mould manufacture months can be selected and corrected',
                'Employee records load the complete roster',
                'Customer access can be scoped by department or person',
                'Daily-report outputs that can only go to the warehouse',
                'Attachment actions, including “Add file”',
              ],
              'ko' => [
                '검색 결과를 오른쪽에 분류에 관계없이 한 목록으로',
                '입력칸, 선택 목록과 날짜 필드의 높이',
                '금형 제조 연월을 선택하거나 수정',
                '직원 기록에서 전체 직원 명단을',
                '고객 조회 범위를 부서나 직원별로',
                '창고로만 보낼 수 있는 생산 실적은',
                '‘파일 추가’ 등 첨부 작업을 오른쪽에',
              ],
              _ => [
                '搜索结果在右侧跨分类统一显示',
                '统一表单输入框、下拉和日期控件',
                '模具制造年月可正常选择和修改',
                '员工档案显示完整人员名单',
                '客户查看范围可按部门或人员配置',
                '报工中只能送仓的产出在主表直接显示',
                '附件区的“添加文件”等操作统一靠右',
              ],
            };
            for (final note in currentNotes) {
              expect(
                find.textContaining(note),
                release == '2.5.20' ? findsOneWidget : findsNothing,
              );
            }
            if (release == '2.5.20') {
              for (final oldNote in [
                l10n.release2517Lifecycle,
                l10n.release2518ServerUpdates,
                l10n.release2518Storage,
              ]) {
                expect(find.textContaining(oldNote), findsNothing);
              }
              if (language != 'zh') {
                expect(find.textContaining('搜索结果在右侧跨分类统一显示'), findsNothing);
              }
            }
            final launcherFix = switch (language) {
              'en' => 'Fixed database migration startup',
              'ko' => '마이그레이션이 시작되지',
              _ => '迁移程序无法启动',
            };
            expect(
              find.textContaining(launcherFix),
              release == '2.5.19' ? findsOneWidget : findsNothing,
            );
            final accountFix = switch (language) {
              'en' => 'Fixed account provisioning blocked by a deleted account',
              'ko' => '삭제된 계정 때문에',
              _ => '已删除账号占位导致员工无法开通',
            };
            final notificationFix = switch (language) {
              'en' => 'Notification cards now wrap full dates',
              'ko' => '알림 카드의 날짜와 묶음 개수',
              _ => '通知卡片在窄屏和大字体下',
            };
            final hrLayout = switch (language) {
              'en' => 'HR identity review now uses separate employee columns',
              'ko' => '인사 증명서 검토는',
              _ => '员工核对信息分列',
            };
            for (final fix in [accountFix, notificationFix, hrLayout]) {
              expect(
                find.textContaining(fix),
                release == '2.5.19' ? findsOneWidget : findsNothing,
              );
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

  testWidgets('a similar version never borrows 2.5.20 notes', (tester) async {
    await pump(tester, version: 'v2.5.200');
    expect(find.text('此版本暂未附带更新说明。'), findsOneWidget);
    expect(find.textContaining('搜索结果在右侧跨分类统一显示'), findsNothing);
    expect(find.textContaining('模具制造年月可正常选择和修改'), findsNothing);
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
