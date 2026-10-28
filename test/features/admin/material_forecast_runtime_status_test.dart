import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/admin/models/material_forecast_runtime_status.dart';
import 'package:uten_imp/features/admin/models/system_setting_entry.dart';
import 'package:uten_imp/features/admin/models/system_updater_status.dart';
import 'package:uten_imp/features/admin/pages/admin_system_settings_page.dart';
import 'package:uten_imp/features/admin/repositories/material_forecast_runtime_repository.dart';
import 'package:uten_imp/features/admin/repositories/system_setting_repository.dart';
import 'package:uten_imp/features/admin/widgets/material_forecast_runtime_status_card.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import '../../support/audit_screenshot_support.dart';

const _revision =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _saved = {
  'material_forecast.enabled': 'true',
  'material_forecast.interval_minutes': '15',
  'material_forecast.history_days': '1200',
  'material_forecast.backfill_budget': '30',
};
final _clock = StateProvider<DateTime>((_) => DateTime.utc(2026, 10, 21, 8));
final _scope = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'admin'),
);
final _grants = StateProvider<Set<String>>((_) => {Perm.authorizationManage});
final _savedSettings = StateProvider<Map<String, String>>((_) => _saved);

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async =>
      ref.watch(authenticatedScopeProvider) == null ? null : SessionSnapshot();
}

Map<String, dynamic> _wire({
  bool enabled = true,
  bool applied = true,
  int interval = 15,
  String? state,
  String? error,
  String expiry = '2026-10-21T08:00:40Z',
}) => {
  'dataAsOf': '2026-10-21T08:00:00Z',
  'expiresAt': expiry,
  'refreshAfterSeconds': 15,
  'configuration': {
    'enabled': enabled,
    'intervalMinutes': interval,
    'historyDays': 1200,
    'backfillBudget': 30,
    'revision': _revision,
  },
  'runtime': {
    'state': state ?? (enabled ? 'RUNNING' : 'DISABLED'),
    'available': true,
    'processRunning': enabled,
    'desiredRevision': _revision,
    'appliedRevision': applied ? _revision : null,
    'configurationApplied': applied,
    'startedAt': '2026-10-21T07:00:00Z',
    'lastExitAt': null,
    'lastExitCode': null,
    'lastErrorCode': error,
  },
  'feeds': [
    for (final item in [
      ('shfe_cu_main_daily', '沪铜'),
      ('shfe_al_main_daily', '沪铝'),
      ('shfe_ag_main_daily', '沪银'),
    ])
      {
        'seriesId': item.$1,
        'name': item.$2,
        'sync': {
          'status': 'MODEL',
          'autoUpdateEnabled': true,
          'lastSuccessAt': '2026-10-21T07:30:00Z',
          'errorCode': null,
        },
        'latestQuote': null,
        'snapshotStatus': 'RESEARCH_ONLY',
        'dataAsOf': '2026-10-20',
        'historyRecordCount': 600,
      },
  ],
};

class _Api extends ApiClient {
  _Api() : super(Dio());
  String? path;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    this.path = path;
    return _wire();
  }
}

class _RuntimeRepo implements MaterialForecastRuntimeRepository {
  Object? failure;
  Map<String, dynamic> wire = _wire();
  bool fail = false, delay = false;
  int reads = 0;
  final pending = <Completer<MaterialForecastRuntimeStatus>>[];
  @override
  Future<MaterialForecastRuntimeStatus> status() async {
    reads++;
    if (failure != null) throw failure!;
    if (fail) throw StateError('unavailable');
    if (delay) {
      final c = Completer<MaterialForecastRuntimeStatus>();
      pending.add(c);
      return c.future;
    }
    return MaterialForecastRuntimeStatus(wire);
  }
}

class _SettingsRepo implements SystemSettingRepository {
  Map<String, String> values = {..._saved};
  final writes = <List<({String key, String value, String expectedValue})>>[];
  List<SystemSettingEntry> get entries => [
    for (final row in values.entries)
      SystemSettingEntry(
        key: row.key,
        value: row.value,
        valueType: row.key.endsWith('enabled') ? 'bool' : 'int',
        category: 'material_market',
        label: switch (row.key) {
          'material_forecast.enabled' => '启用自动行情与预测',
          'material_forecast.interval_minutes' => '行情检查周期',
          'material_forecast.history_days' => '历史回填范围',
          _ => '每轮历史回填上限',
        },
        description: '修改后等待服务器确认应用',
        unit: row.key.endsWith('interval_minutes') ? '分钟' : null,
        sortOrder: 1,
        updatedAt: '2026-10-21T08:00:00Z',
        minValue: row.key.endsWith('interval_minutes')
            ? 15
            : row.key.endsWith('history_days')
            ? 3
            : 0,
        maxValue: row.key.endsWith('interval_minutes')
            ? 60
            : row.key.endsWith('history_days')
            ? 3650
            : 1000,
        applyMode: 'NEXT_SCHEDULED_RUN',
      ),
  ];
  @override
  Future<List<SystemSettingEntry>> list() async => entries;
  @override
  Future<List<SystemSettingEntry>> updateBatch(
    List<({String key, String value, String expectedValue})> changes,
  ) async {
    writes.add(changes);
    for (final change in changes) {
      values[change.key] = change.value;
    }
    return entries
        .where((entry) => changes.any((change) => change.key == entry.key))
        .toList();
  }

  @override
  Future<SystemUpdaterStatus> updaterStatus() async =>
      const SystemUpdaterStatus(
        requestedIntervalDays: 0,
        available: false,
        stale: true,
        lastResult: 'NEVER',
      );
}

void main() {
  Future<void> frames(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 350));
    await t.pump();
  }

  Future<ProviderContainer> pump(
    WidgetTester t,
    _RuntimeRepo repo, {
    bool page = false,
    _SettingsRepo? settings,
    bool dark = false,
    double width = 1000,
    double scale = 1,
    GlobalKey? visual,
  }) async {
    await loadAuditScreenshotFonts(t);
    t.view.physicalSize = Size(width, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          materialForecastRuntimeRepositoryProvider.overrideWithValue(repo),
          materialForecastRuntimeClockProvider.overrideWith(
            (ref) =>
                () => ref.read(_clock),
          ),
          authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
          currentPermissionsProvider.overrideWith((ref) => ref.watch(_grants)),
          isSuperAdminProvider.overrideWithValue(true),
          sessionSnapshotProvider.overrideWith(_Snapshots.new),
          apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
          if (settings != null)
            systemSettingRepositoryProvider.overrideWithValue(settings),
        ],
        child: RepaintBoundary(
          key: visual ?? const Key('runtime-host'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: auditScreenshotTheme(
              dark ? buildDarkTheme() : buildLightTheme(),
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: page
                ? const AdminSystemSettingsPage()
                : Scaffold(
                    body: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Consumer(
                        builder: (context, ref, _) =>
                            MaterialForecastRuntimeStatusCard(
                              savedSettings: ref.watch(_savedSettings),
                            ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
    await frames(t);
    await frames(t);
    return ProviderScope.containerOf(t.element(find.byType(Scaffold).first));
  }

  test('status repository only GETs the administrative status route', () async {
    final api = _Api();
    final status = await ApiMaterialForecastRuntimeRepository(api).status();
    expect(api.path, '/admin/system-settings/material-forecast-status');
    expect(status.acknowledgedAt(DateTime.utc(2026, 10, 21, 8), _saved), true);
  });
  test(
    'acknowledgement requires matching desired/applied revision and actual process state',
    () {
      final now = DateTime.utc(2026, 10, 21, 8);
      final wire = _wire();
      expect(
        MaterialForecastRuntimeStatus(wire).acknowledgedAt(now, _saved),
        true,
      );
      for (final field in [
        'desiredRevision',
        'appliedRevision',
        'processRunning',
        'configurationApplied',
      ]) {
        final broken = {
          ...wire,
          'runtime': {
            ...wire['runtime'] as Map<String, dynamic>,
            field: field.endsWith('Revision') ? 'other' : false,
          },
        };
        expect(
          MaterialForecastRuntimeStatus(broken).acknowledgedAt(now, _saved),
          false,
          reason: field,
        );
      }
      expect(
        MaterialForecastRuntimeStatus(_wire(enabled: false)).acknowledgedAt(
          now,
          {..._saved, 'material_forecast.enabled': 'false'},
        ),
        true,
      );
      expect(
        MaterialForecastRuntimeStatus(
          wire,
        ).acknowledgedAt(now.add(const Duration(minutes: 1)), _saved),
        false,
      );
    },
  );
  test('malformed status does not become a verified capability', () {
    expect(() => MaterialForecastRuntimeStatus({}), throwsFormatException);
  });

  testWidgets(
    'running status shows all benchmark phases and Beijing timestamps without paths',
    (t) async {
      await pump(t, _RuntimeRepo());
      expect(find.text('服务器已确认自动采集运行'), findsOneWidget);
      expect(find.text('当前保存设置已由服务器确认'), findsOneWidget);
      for (final name in ['沪铜', '沪铝', '沪银']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.text('最近日终交易日：2026-10-20'), findsNWidgets(3));
      expect(find.text('上次启动：2026-10-21 15:00(北京)'), findsOneWidget);
      expect(find.textContaining('python.exe'), findsNothing);
    },
  );
  testWidgets(
    'saved policy is not labelled applied when process acknowledgement mismatches',
    (t) async {
      await pump(t, _RuntimeRepo()..wire = _wire(applied: false));
      expect(find.text('设置已保存，等待采集服务确认'), findsOneWidget);
      expect(find.text('服务器已确认自动采集运行'), findsNothing);
      expect(find.text('上次阶段：更新研究预测'), findsNWidgets(3));
    },
  );
  testWidgets(
    'disabled policy is confirmed only after stopped acknowledgement',
    (t) async {
      final repo = _RuntimeRepo()..wire = _wire(enabled: false);
      final c = await pump(t, repo);
      c.read(_savedSettings.notifier).state = {
        ..._saved,
        'material_forecast.enabled': 'false',
      };
      await frames(t);
      expect(find.text('自动采集已关闭'), findsOneWidget);
      repo.wire = _wire(enabled: false, applied: false);
      await t.tap(find.byKey(const Key('material-forecast-runtime-refresh')));
      await frames(t);
      expect(find.text('自动采集已关闭'), findsNothing);
    },
  );
  testWidgets(
    'slow automatic GET cannot extend runtime acknowledgement beyond expiresAt',
    (t) async {
      final repo = _RuntimeRepo();
      final c = await pump(t, repo);
      repo.delay = true;
      c.read(_clock.notifier).state = DateTime.utc(2026, 10, 21, 8, 0, 15);
      await t.pump(const Duration(seconds: 15));
      await frames(t);
      expect(repo.pending, hasLength(1));
      c.read(_clock.notifier).state = DateTime.utc(2026, 10, 21, 8, 0, 41);
      await t.pump(const Duration(seconds: 26));
      await frames(t);
      expect(repo.pending.single.isCompleted, false);
      expect(find.text('服务器已确认自动采集运行'), findsNothing);
      expect(find.text('采集状态已过期，暂无法确认是否运行'), findsOneWidget);
      repo.pending.single.complete(MaterialForecastRuntimeStatus(_wire()));
      await frames(t);
    },
  );
  testWidgets(
    'failed polling retains historical evidence without claiming a running service',
    (t) async {
      final repo = _RuntimeRepo();
      final c = await pump(t, repo);
      repo.fail = true;
      c.read(_clock.notifier).state = DateTime.utc(2026, 10, 21, 8, 0, 15);
      await t.pump(const Duration(seconds: 15));
      await frames(t);
      expect(find.text('暂无法核对采集状态，保留上次状态记录'), findsOneWidget);
      expect(find.text('当前阶段：更新研究预测'), findsNothing);
      expect(find.text('沪铜'), findsOneWidget);
    },
  );
  testWidgets(
    'server access revocation clears retained status before permission refresh',
    (t) async {
      final repo = _RuntimeRepo();
      await pump(t, repo);
      repo.failure = ApiException('FORBIDDEN', 'denied');
      await t.pump(const Duration(seconds: 15));
      await frames(t);
      expect(find.text('当前身份无权读取采集状态'), findsOneWidget);
      expect(find.text('沪铜'), findsNothing);
      final reads = repo.reads;
      await t.pump(const Duration(seconds: 30));
      expect(repo.reads, reads);
    },
  );

  testWidgets('permission revocation clears status and prevents later reads', (
    t,
  ) async {
    final repo = _RuntimeRepo();
    final c = await pump(t, repo);
    c.read(_grants.notifier).state = {};
    await frames(t);
    expect(find.text('服务器已确认自动采集运行'), findsNothing);
    await t.pump(const Duration(minutes: 1));
    expect(repo.reads, 1);
  });
  testWidgets('changed saved settings discard an old pending status read', (
    t,
  ) async {
    final repo = _RuntimeRepo()..delay = true;
    final c = await pump(t, repo);
    c.read(_savedSettings.notifier).state = {
      ..._saved,
      'material_forecast.interval_minutes': '30',
    };
    await frames(t);
    expect(repo.pending, hasLength(2));
    repo.pending.first.complete(MaterialForecastRuntimeStatus(_wire()));
    await frames(t);
    expect(find.text('服务器已确认自动采集运行'), findsNothing);
    repo.pending.last.complete(
      MaterialForecastRuntimeStatus(_wire(interval: 30)),
    );
    await frames(t);
    expect(find.text('服务器已确认自动采集运行'), findsOneWidget);
  });
  testWidgets(
    'account changes cannot expose the previous pending runtime status',
    (t) async {
      final repo = _RuntimeRepo()..delay = true;
      final c = await pump(t, repo);
      c.read(_scope.notifier).state = const AuthenticatedScope(
        userId: 'another-admin',
      );
      await frames(t);
      expect(repo.pending, hasLength(2));
      repo.pending.first.complete(MaterialForecastRuntimeStatus(_wire()));
      await frames(t);
      expect(find.text('服务器已确认自动采集运行'), findsNothing);
      repo.pending.last.complete(
        MaterialForecastRuntimeStatus(_wire(applied: false)),
      );
      await frames(t);
      expect(find.text('设置已保存，等待采集服务确认'), findsOneWidget);
    },
  );

  testWidgets('background polling waits for foreground', (t) async {
    final repo = _RuntimeRepo();
    await pump(t, repo);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(
      () => t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
    );
    await t.pump(const Duration(seconds: 15));
    expect(repo.reads, 1);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await frames(t);
    expect(repo.reads, 2);
  });
  testWidgets(
    'safe errors do not expose implementation paths or raw exception text',
    (t) async {
      await pump(
        t,
        _RuntimeRepo()
          ..wire = _wire(
            state: 'ERROR',
            applied: false,
            error: 'C:/private/python.exe',
          ),
      );
      expect(find.text('采集状态需要服务器维护人员核对'), findsOneWidget);
      expect(find.textContaining('C:/private'), findsNothing);
    },
  );
  testWidgets(
    'runtime status failure does not block generic setting batch save',
    (t) async {
      final settings = _SettingsRepo();
      await pump(
        t,
        _RuntimeRepo()..fail = true,
        page: true,
        settings: settings,
      );
      final field = find.byKey(
        const ValueKey('system-setting-material_forecast.interval_minutes'),
      );
      await t.ensureVisible(field);
      await t.enterText(field, '30');
      await frames(t);
      await t.tap(find.byKey(const ValueKey('system-settings-save')));
      await frames(t);
      expect(settings.writes, hasLength(1));
      expect(settings.writes.single, [
        (
          key: 'material_forecast.interval_minutes',
          value: '30',
          expectedValue: '15',
        ),
      ]);
      expect(find.text('采集状态读取失败，暂未确认服务器应用'), findsOneWidget);
    },
  );
  testWidgets(
    'server registry range blocks invalid market setting before save',
    (t) async {
      final settings = _SettingsRepo();
      await pump(t, _RuntimeRepo(), page: true, settings: settings);
      final field = find.byKey(
        const ValueKey('system-setting-material_forecast.interval_minutes'),
      );
      await t.ensureVisible(field);
      await t.enterText(field, '14');
      await frames(t);
      await t.tap(find.byKey(const ValueKey('system-settings-save')));
      await frames(t);
      expect(settings.writes, isEmpty);
      expect(
        t.state<FormFieldState<String>>(field).errorText,
        contains('(15–60)'),
      );
    },
  );
  testWidgets(
    'wide material group exposes four portable settings and runtime evidence',
    (t) async {
      final visual = GlobalKey();
      await pump(
        t,
        _RuntimeRepo(),
        page: true,
        settings: _SettingsRepo(),
        width: 1440,
        visual: visual,
      );
      for (final key in _saved.keys) {
        expect(find.byKey(ValueKey('system-setting-$key')), findsOneWidget);
      }
      expect(find.text('原材料行情与预测'), findsOneWidget);
      const policy = '设置和货品关联随数据库保留，标准服务器部署会自动准备采集环境。';
      expect(find.text(policy), findsNothing);
      final hint = find.byKey(const Key('material-forecast-portable-policy'));
      await t.ensureVisible(hint);
      await t.tap(hint);
      await t.pumpAndSettle();
      expect(find.text(policy), findsOneWidget);
      const capture = bool.fromEnvironment('UTEN_MATERIAL_RUNTIME_VISUALS');
      if (capture) {
        await saveAuditScreenshot(t, visual, 'material-runtime-wide');
      }
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'narrow enlarged ${dark ? 'dark' : 'light'} status and controls remain usable',
      (t) async {
        final key = GlobalKey();
        await pump(
          t,
          _RuntimeRepo(),
          page: true,
          settings: _SettingsRepo(),
          width: 375,
          scale: 1.8,
          dark: dark,
          visual: key,
        );
        await t.ensureVisible(
          find.byKey(const Key('material-forecast-runtime-title')),
        );
        await frames(t);
        expect(t.takeException(), isNull);
        const capture = bool.fromEnvironment('UTEN_MATERIAL_RUNTIME_VISUALS');
        if (capture) {
          await saveAuditScreenshot(
            t,
            key,
            'material-runtime-${dark ? 'dark' : 'light'}-large',
          );
        }
      },
    );
  }
}
