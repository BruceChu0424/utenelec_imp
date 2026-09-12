import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
      expect(find.text('1 项已修改'), findsOneWidget);
      await tester.enterText(hot, '6');
      await tester.pump();
      expect(find.text('所有设置保持当前值'), findsOneWidget);
      final publisher = tester.widget<TextFormField>(
        find.byKey(const ValueKey('system-setting-celebration.publisher_name')),
      );
      expect(publisher.initialValue, '公司');
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
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
      await tester.tap(find.text('保存改动'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextFormField),
        ),
        'confirmed-password',
      );
      await tester.tap(find.text('确认修改'));
      await tester.pumpAndSettle();
      expect(repo.batchCalls, 1);
      expect(repo.singleCalls, 0);
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

  testWidgets('invalid setting is blocked before password prompt or write', (
    tester,
  ) async {
    final repo = _Repository();
    await _pump(tester, repo);
    await tester.enterText(
      find.byKey(const ValueKey('system-setting-audit_hot_retention_months')),
      '0',
    );
    await tester.tap(find.text('保存改动'));
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
  int singleCalls = 0;
  List<({String key, String value, String expectedValue})>? changes;
  final settings = [
    _entry('audit_hot_retention_months', '6', 'int', 'audit'),
    _entry('audit_archive_retention_months', '30', 'int', 'audit'),
    _entry('celebration.auto_enabled', 'true', 'bool', 'business'),
    _entry('celebration.publisher_name', '公司', 'string', 'business'),
  ];
  @override
  Future<List<SystemSettingEntry>> list() async => settings;
  @override
  Future<SystemSettingEntry> update(
    String key,
    String value,
    String password,
  ) async {
    singleCalls++;
    return settings.first;
  }

  @override
  Future<List<SystemSettingEntry>> updateBatch(
    List<({String key, String value, String expectedValue})> changes,
    String password,
  ) async {
    batchCalls++;
    this.changes = changes;
    expect(password, 'confirmed-password');
    return settings;
  }

  static SystemSettingEntry _entry(
    String key,
    String value,
    String type,
    String category,
  ) => SystemSettingEntry(
    key: key,
    value: value,
    valueType: type,
    category: category,
    label: key,
    description: null,
    unit: null,
    sortOrder: 0,
    updatedAt: null,
  );
}
