import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/admin/models/system_setting_entry.dart';
import 'package:uten_imp/features/admin/pages/admin_system_settings_page.dart';
import 'package:uten_imp/features/admin/repositories/system_setting_repository.dart';

void main() {
  testWidgets(
    'reverted input is clean and string settings use text keyboards',
    (tester) async {
      final repo = _Repository();
      await _pump(tester, repo);
      final hot = find.byKey(
        const ValueKey('system-setting-audit_hot_retention_months'),
      );
      await tester.enterText(hot, '12');
      await tester.pump();
      expect(find.text('保存 1 项改动'), findsOneWidget);
      await tester.enterText(hot, '6');
      await tester.pump();
      expect(find.text('保存改动'), findsOneWidget);
      final publisher = tester.widget<TextFormField>(
        find.byKey(const ValueKey('system-setting-celebration.publisher_name')),
      );
      expect(publisher.initialValue, '公司');
      // 2026-09-16 下拉统一：布尔设置项改用 UtenDropdownField。
      expect(find.byType(UtenDropdownField), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(repo.batchCalls, 0);
    },
  );

  testWidgets(
    'two edited values use one batch with original values and one confirmation',
    (tester) async {
      final repo = _Repository();
      await _pump(tester, repo);
      await tester.enterText(
        find.byKey(const ValueKey('system-setting-audit_hot_retention_months')),
        '12',
      );
      await tester.enterText(
        find.byKey(
          const ValueKey('system-setting-audit_archive_retention_months'),
        ),
        '60',
      );
      await tester.tap(find.byKey(const ValueKey('system-settings-save')));
      await tester.pump(const Duration(milliseconds: 300));
      // 留存调整只弹风险确认，不在页面里问密码 (再认证由网络层统一弹框，ADR-110)。
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextFormField),
        ),
        findsNothing,
      );
      await tester.tap(find.text('继续保存'));
      await tester.pumpAndSettle();
      expect(repo.batchCalls, 1);
      expect(repo.changes, [
        (key: 'audit_hot_retention_months', value: '12', expectedValue: '6'),
        (
          key: 'audit_archive_retention_months',
          value: '60',
          expectedValue: '30',
        ),
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('non-retention change saves directly without any page dialog', (
    tester,
  ) async {
    final repo = _Repository();
    await _pump(tester, repo);
    await tester.enterText(
      find.byKey(const ValueKey('system-setting-lockout_minutes')),
      '20',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('system-settings-save')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(repo.batchCalls, 1);
    expect(repo.changes, [
      (key: 'lockout_minutes', value: '20', expectedValue: '15'),
    ]);
  });

  testWidgets('range comes from the server registry, not a client copy', (
    tester,
  ) async {
    final repo = _Repository();
    await _pump(tester, repo);
    // 服务端登记 lockout_minutes 为 1..60：61 在前端就被拦下，并显示服务端给的范围。
    final field = find.byKey(const ValueKey('system-setting-lockout_minutes'));
    await tester.enterText(field, '61');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('system-settings-save')));
    await tester.pumpAndSettle();
    expect(
      tester.state<FormFieldState<String>>(field).errorText,
      contains('(1–60)'),
    );
    expect(repo.batchCalls, 0);
  });

  testWidgets('invalid setting is blocked before any confirmation or write', (
    tester,
  ) async {
    final repo = _Repository();
    await _pump(tester, repo);
    await tester.enterText(
      find.byKey(const ValueKey('system-setting-audit_hot_retention_months')),
      '0',
    );
    await tester.tap(find.byKey(const ValueKey('system-settings-save')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(repo.batchCalls, 0);
  });
}

Future<void> _pump(WidgetTester tester, _Repository repo) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [systemSettingRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: AdminSystemSettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _Repository implements SystemSettingRepository {
  int batchCalls = 0;
  List<({String key, String value, String expectedValue})>? changes;
  final settings = [
    _entry('audit_hot_retention_months', '6', 'int', 'audit', min: 1, max: 120),
    _entry(
      'audit_archive_retention_months',
      '30',
      'int',
      'audit',
      min: 0,
      max: 240,
    ),
    _entry('lockout_minutes', '15', 'int', 'security', min: 1, max: 60),
    _entry('celebration.auto_enabled', 'true', 'bool', 'business'),
    _entry('celebration.publisher_name', '公司', 'string', 'business'),
  ];
  @override
  Future<List<SystemSettingEntry>> list() async => settings;
  @override
  Future<List<SystemSettingEntry>> updateBatch(
    List<({String key, String value, String expectedValue})> changes,
  ) async {
    batchCalls++;
    this.changes = changes;
    return settings;
  }

  static SystemSettingEntry _entry(
    String key,
    String value,
    String type,
    String category, {
    int? min,
    int? max,
  }) => SystemSettingEntry(
    key: key,
    value: value,
    valueType: type,
    category: category,
    label: key,
    description: null,
    unit: null,
    sortOrder: 0,
    updatedAt: null,
    minValue: min,
    maxValue: max,
  );
}
