import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/admin/models/system_setting_entry.dart';
import 'package:uten_imp/features/admin/models/system_updater_status.dart';
import 'package:uten_imp/features/admin/pages/admin_system_settings_page.dart';
import 'package:uten_imp/features/admin/repositories/system_setting_repository.dart';
import 'package:uten_imp/shared/audit/audit_retention_presentation.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/repositories/public_settings_repository.dart';

void main() {
  test(
    'server applied metadata preserves raw settings and unknown effects',
    () {
      final entry = SystemSettingEntry.fromJson({
        'key': 'audit_archive_retention_months',
        'value': '0',
        'effectiveValue': '5',
        'effectiveNote': '在线与归档有效总期限至少六个月',
        'applyMode': 'NEXT_SCHEDULED_RUN',
        'editable': false,
      });
      expect(entry.value, '0');
      expect(entry.effectiveValue, '5');
      expect(entry.editable, false);
      expect(
        SystemSettingEntry.fromJson({'value': '7'}).effectiveValue,
        isNull,
      );
      expect(
        PublicSettings.fromJson({
          'auditArchivePurgeMode': 'PERMANENT_RETAIN',
        }).auditArchivePurgeMode,
        AuditArchivePurgeMode.permanentRetain,
      );
      expect(
        AuditRetentionPresentation.modeConsequence(
          AuditArchivePurgeMode.permanentRetain,
        ),
        contains('修改月数不会启用删除'),
      );
    },
  );

  testWidgets(
    'legacy schedule is readonly history and cannot claim the new host schedule applied',
    (tester) async {
      final repository = _Repository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiBaseUrlProvider.overrideWithValue('http://localhost/api'),
            authenticatedScopeProvider.overrideWithValue(null),
            currentPermissionsProvider.overrideWithValue(const {}),
            isSuperAdminProvider.overrideWithValue(false),
            systemSettingRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AdminSystemSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = tester.widget<TextFormField>(
        find.byKey(
          const ValueKey('system-setting-updater_check_interval_days'),
        ),
      );
      expect(field.enabled, false);
      expect(repository.statusReads, 0);
      expect(repository.writes, 0);
      expect(find.text('服务器已确认更新计划'), findsNothing);
      const legacyGuidance = '旧自动检查周期仅保留为升级记录。实际更新方式与运行状态请在服务器更新中查看。';
      final guidance = find.byTooltip(legacyGuidance);
      expect(guidance, findsOneWidget);
      await tester.tap(
        find.descendant(of: guidance, matching: find.byType(IconButton)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(legacyGuidance), findsOneWidget);
      expect(find.text('实际仅手动，运行状态以本机运维状态为准'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _Repository implements SystemSettingRepository {
  int statusReads = 0, writes = 0;
  @override
  Future<List<SystemSettingEntry>> list() async => [
    SystemSettingEntry.fromJson({
      'key': 'updater_check_interval_days',
      'value': '7',
      'valueType': 'int',
      'category': 'updates',
      'label': '旧更新检查间隔',
      'editable': false,
      'applyMode': 'LEGACY_MANUAL_ONLY',
      'effectiveNote': '实际仅手动，运行状态以本机运维状态为准',
    }),
  ];
  @override
  Future<List<SystemSettingEntry>> updateBatch(
    List<({String key, String value, String expectedValue})> changes,
  ) async {
    writes++;
    return list();
  }

  @override
  Future<SystemUpdaterStatus> updaterStatus() async {
    statusReads++;
    throw StateError('must not use legacy scheduler status');
  }
}
