import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/admin/models/system_setting_entry.dart';
import 'package:uten_imp/features/admin/models/system_updater_status.dart';
import 'package:uten_imp/features/admin/pages/admin_system_settings_page.dart';
import 'package:uten_imp/features/admin/repositories/system_setting_repository.dart';
import 'package:uten_imp/shared/audit/audit_retention_presentation.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/repositories/public_settings_repository.dart';

import '../../support/audit_screenshot_support.dart';

void main() {
  for (final mode in ['PRESERVE_UNCLASSIFIED', 'LEGACY_PURGE', null]) {
    testWidgets('审计设置展示服务器实际模式 $mode 并区分本机回执', (tester) async {
      await _pump(tester, _PublicApi(mode));
      final expected = mode == 'PRESERVE_UNCLASSIFIED'
          ? '服务器历史日志保护已启用'
          : mode == 'LEGACY_PURGE'
          ? '服务器仍按旧规则清理历史日志'
          : '历史日志保护状态尚未确认';
      expect(find.text(expected), findsOneWidget);
      expect(find.textContaining('本机设备回执单独保存'), findsOneWidget);
      expect(find.textContaining('合计 36 个月'), findsOneWidget);
      if (mode == 'PRESERVE_UNCLASSIFIED') {
        expect(find.textContaining('到期后继续保留'), findsOneWidget);
        expect(find.textContaining('36 个月后永久删除'), findsNothing);
      } else if (mode == null) {
        expect(find.textContaining('暂时无法确认到期日志是否会自动删除'), findsOneWidget);
        expect(find.text('服务器历史日志保护已启用'), findsNothing);
      }
      await tester.enterText(
        find.byKey(const ValueKey('system-setting-audit_hot_retention_months')),
        '12',
      );
      await tester.pump();
      expect(find.textContaining('合计 42 个月'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('保全模式确认仅改月数，不承诺本机回执永久保存', (tester) async {
    final api = _PublicApi('PRESERVE_UNCLASSIFIED');
    final repo = _RetentionSettingRepository();
    await _pump(tester, api, repository: repo);
    await _editAndConfirm(tester);
    expect(api.calls, 2);
    final content = tester
        .widget<Text>(
          find.byKey(const ValueKey('audit-retention-confirm-mode')),
        )
        .data!;
    expect(content, contains('到期后继续保留'));
    expect(content, contains('本次仅调整在线与归档月数'));
    expect(content, contains('本机设备回执单独保存'));
    await tester.tap(find.text('继续保存'));
    await tester.pumpAndSettle();
    expect(repo.changes, [
      (key: 'audit_hot_retention_months', value: '12', expectedValue: '6'),
    ]);
    expect(tester.takeException(), isNull);
  });

  for (final failure in [false, true]) {
    testWidgets('保存前${failure ? '读取失败' : '能力变未知'}不能沿用已保护说明', (tester) async {
      final api = _PublicApi('PRESERVE_UNCLASSIFIED');
      await _pump(tester, api);
      api.fail = failure;
      api.mode = null;
      await _editAndConfirm(tester);
      final content = tester
          .widget<Text>(
            find.byKey(const ValueKey('audit-retention-confirm-mode')),
          )
          .data!;
      expect(content, contains('状态尚未确认'));
      expect(content, isNot(contains('服务器历史日志保护已启用')));
      expect(content, contains('本机设备回执'));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('保存 1 项改动'), findsOneWidget);
    });
  }

  testWidgets('确认框打开期间读取失败也撤下已核实保全状态', (tester) async {
    final api = _PublicApi('PRESERVE_UNCLASSIFIED');
    await _pump(tester, api);
    await _editAndConfirm(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AdminSystemSettingsPage)),
    );
    api.fail = true;
    await expectLater(
      container.read(publicSettingsRepositoryProvider).fetch(),
      throwsStateError,
    );
    await tester.pump();
    final content = tester
        .widget<Text>(
          find.byKey(const ValueKey('audit-retention-confirm-mode')),
        )
        .data!;
    expect(content, contains('状态尚未确认'));
    expect(content, isNot(contains('服务器历史日志保护已启用')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字确认可以滚动且不溢出', (tester) async {
    await _pump(
      tester,
      _PublicApi(null),
      size: const Size(390, 700),
      textScale: 1.4,
    );
    await _editAndConfirm(tester);
    expect(
      tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
      isTrue,
    );
    expect(find.text('继续保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('审计概览不把设备回执期限当中央证据最长保留期', () {
    final known = AuditRetentionPresentation.historyHint(
      AuditArchivePurgeMode.preserveUnclassified,
    );
    expect(known, contains('本页面显示在线日志'));
    expect(known, contains('到期后继续保留'));
    expect(known, contains('本机设备回执单独保存'));
    expect(known, isNot(contains('总保留期最长')));
    final unknown = AuditRetentionPresentation.historyHint(
      AuditArchivePurgeMode.unknown,
    );
    expect(unknown, contains('暂时无法确认到期日志是否会自动删除'));
    expect(unknown, isNot(contains('日志保护已启用')));
  });

  if (const bool.fromEnvironment('UTEN_CAPTURE_UI')) {
    for (final shot in [
      (
        'preserve-wide',
        'PRESERVE_UNCLASSIFIED',
        const Size(1100, 1000),
        1.0,
        false,
      ),
      ('unknown-wide', null, const Size(1100, 1000), 1.0, false),
      (
        'preserve-confirm',
        'PRESERVE_UNCLASSIFIED',
        const Size(900, 760),
        1.0,
        true,
      ),
      ('legacy-confirm', 'LEGACY_PURGE', const Size(900, 760), 1.0, true),
      ('unknown-large-confirm', null, const Size(390, 760), 1.4, true),
    ]) {
      testWidgets('审计保全视觉 ${shot.$1}', (tester) async {
        await loadAuditScreenshotFonts(tester);
        final boundary = GlobalKey();
        final base = auditScreenshotTheme(buildLightTheme());
        final theme = base.copyWith(
          dialogTheme: base.dialogTheme.copyWith(
            titleTextStyle: base.textTheme.headlineSmall,
            contentTextStyle: base.textTheme.bodyMedium,
          ),
        );
        await _pump(
          tester,
          _PublicApi(shot.$2),
          size: shot.$3,
          textScale: shot.$4,
          boundary: boundary,
          theme: theme,
        );
        if (shot.$5) await _editAndConfirm(tester);
        expect(tester.takeException(), isNull);
        await saveAuditScreenshot(
          tester,
          boundary,
          'audit-retention-${shot.$1}',
        );
      });
    }
  }
}

Future<void> _editAndConfirm(WidgetTester tester) async {
  final field = find.byKey(
    const ValueKey('system-setting-audit_hot_retention_months'),
  );
  await tester.ensureVisible(field);
  await tester.enterText(field, '12');
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('system-settings-save')));
  // The save button is deliberately busy until the user answers this dialog.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.byType(AlertDialog), findsOneWidget);
}

Future<void> _pump(
  WidgetTester tester,
  _PublicApi api, {
  _RetentionSettingRepository? repository,
  Size size = const Size(1000, 900),
  double textScale = 1,
  GlobalKey? boundary,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'audit-admin'),
        ),
        systemSettingRepositoryProvider.overrideWithValue(
          repository ?? _RetentionSettingRepository(),
        ),
      ],
      child: RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const AdminSystemSettingsPage(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _PublicApi extends ApiClient {
  _PublicApi(this.mode) : super(Dio());
  String? mode;
  bool fail = false;
  int calls = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expect(path, ApiEndpoints.publicSettings);
    calls++;
    if (fail) throw StateError('settings unavailable');
    return {
      if (mode != null) 'auditArchivePurgeMode': mode,
      'auditReceiptRetentionMonths': 36,
      'badgePollSeconds': 90,
    };
  }
}

class _RetentionSettingRepository implements SystemSettingRepository {
  List<({String key, String value, String expectedValue})>? changes;
  List<SystemSettingEntry> settings = [
    _entry('audit_hot_retention_months', '6', '在线审计保留期', 1, 120),
    _entry('audit_archive_retention_months', '30', '归档追加保留期', 0, 240),
  ];

  @override
  Future<SystemUpdaterStatus> updaterStatus() => throw UnimplementedError();

  @override
  Future<List<SystemSettingEntry>> updateBatch(
    List<({String key, String value, String expectedValue})> changes,
  ) async {
    this.changes = changes;
    settings = [
      for (final setting in settings)
        _entry(
          setting.key,
          changes
                  .where((change) => change.key == setting.key)
                  .firstOrNull
                  ?.value ??
              setting.value,
          setting.label,
          setting.minValue!,
          setting.maxValue!,
        ),
    ];
    return settings;
  }

  @override
  Future<List<SystemSettingEntry>> list() async => settings;

  static SystemSettingEntry _entry(
    String key,
    String value,
    String label,
    int min,
    int max,
  ) => SystemSettingEntry(
    key: key,
    value: value,
    valueType: 'int',
    category: 'audit',
    label: label,
    description: key == 'audit_archive_retention_months'
        ? '旧服务器文案：归档到期后永久删除'
        : '在线查询月份',
    unit: '个月',
    sortOrder: key == 'audit_hot_retention_months' ? 410 : 420,
    updatedAt: null,
    minValue: min,
    maxValue: max,
  );
}
