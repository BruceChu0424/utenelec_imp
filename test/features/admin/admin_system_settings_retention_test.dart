import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/system_setting_entry.dart';
import 'package:uten_imp/features/admin/pages/admin_system_settings_page.dart';
import 'package:uten_imp/features/admin/repositories/system_setting_repository.dart';

void main() {
  testWidgets(
    'retention settings explain archive and permanent deletion time',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            systemSettingRepositoryProvider.overrideWithValue(
              _RetentionSettingRepository(),
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh'),
            home: AdminSystemSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('审计与留存'), findsOneWidget);
      expect(find.textContaining('共 36 个月后永久删除'), findsOneWidget);
      expect(find.textContaining('03:17'), findsWidgets);

      await tester.enterText(find.byType(TextField).first, '12');
      await tester.pump();

      expect(find.textContaining('共 42 个月后永久删除'), findsOneWidget);
    },
  );
}

class _RetentionSettingRepository implements SystemSettingRepository {
  @override
  Future<List<SystemSettingEntry>> updateBatch(
    List<({String key, String value, String expectedValue})> changes,
    String password,
  ) async => _settings;
  static const _settings = <SystemSettingEntry>[
    SystemSettingEntry(
      key: 'audit_hot_retention_months',
      value: '6',
      valueType: 'int',
      category: 'audit',
      label: '在线审计保留期',
      description: '日志在审计中心可查询、可导出的月数',
      unit: '个月',
      sortOrder: 410,
      updatedAt: null,
    ),
    SystemSettingEntry(
      key: 'audit_archive_retention_months',
      value: '30',
      valueType: 'int',
      category: 'audit',
      label: '归档追加保留期',
      description: '归档到期后永久删除',
      unit: '个月',
      sortOrder: 420,
      updatedAt: null,
    ),
  ];

  @override
  Future<List<SystemSettingEntry>> list() async => _settings;

  @override
  Future<SystemSettingEntry> update(
    String key,
    String value,
    String password,
  ) async => _settings.firstWhere((entry) => entry.key == key);
}
