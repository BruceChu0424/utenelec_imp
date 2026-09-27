import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/admin/models/system_setting_entry.dart';
import 'package:uten_imp/features/admin/models/system_updater_status.dart';
import 'package:uten_imp/features/admin/pages/admin_system_settings_page.dart';
import 'package:uten_imp/features/admin/repositories/system_setting_repository.dart';

void main() {
  testWidgets('weekly schedule shows server confirmation and does not poll', (
    tester,
  ) async {
    final repo = _Repository();
    await _pump(tester, repo);
    expect(find.text('系统更新'), findsOneWidget);
    expect(find.text('服务器已确认更新计划'), findsOneWidget);
    expect(find.text('已保存设置：每周日 05:00（服务器当地时间）'), findsOneWidget);
    expect(find.text('下次自动拉取：2026-10-04 05:00(北京)'), findsOneWidget);
    expect(find.text('上次检查结果：检查完成'), findsOneWidget);
    expect(repo.statusCalls, 1);
    await tester.pump(const Duration(minutes: 10));
    expect(repo.statusCalls, 1);
  });

  testWidgets(
    'saving manual mode waits for applied state and refresh confirms',
    (tester) async {
      final repo = _Repository();
      await _pump(tester, repo);
      await _save(tester, '0');
      expect(repo.savedChanges, [
        (key: 'updater_check_interval_days', value: '0', expectedValue: '7'),
      ]);
      expect(repo.statusCalls, 2);
      expect(find.text('设置已保存，等待服务器应用'), findsOneWidget);
      expect(find.text('服务器已确认更新计划'), findsNothing);
      expect(find.text('已保存设置：仅手动更新'), findsOneWidget);
      expect(find.textContaining('（上次上报，当前未确认）'), findsOneWidget);
      repo.applied = 0;
      await tester.tap(
        find.byKey(const ValueKey('system-updater-status-refresh')),
      );
      await tester.pumpAndSettle();
      expect(find.text('服务器已确认更新计划'), findsOneWidget);
      expect(find.text('下次自动拉取：已关闭，仅手动更新'), findsOneWidget);
      expect(repo.statusCalls, 3);
    },
  );

  testWidgets('missing, stale, and failed evidence never claims confirmation', (
    tester,
  ) async {
    final repo = _Repository();
    repo.statusOverride = const SystemUpdaterStatus(
      requestedIntervalDays: 7,
      available: false,
      stale: true,
      lastResult: 'NEVER',
      error: '服务器尚未提供更新调度状态',
    );
    await _pump(tester, repo);
    expect(find.text('更新调度尚未安装或未上报'), findsOneWidget);
    expect(find.text('服务器尚未提供更新调度状态'), findsOneWidget);
    expect(find.text('服务器已应用：尚未确认'), findsOneWidget);
    repo.statusOverride = const SystemUpdaterStatus(
      requestedIntervalDays: 7,
      appliedIntervalDays: 7,
      available: true,
      stale: true,
      lastResult: 'SUCCESS',
    );
    await _refreshStatus(tester);
    expect(find.text('状态已过期或设置尚未确认'), findsOneWidget);
    expect(find.text('服务器已确认更新计划'), findsNothing);
    repo.statusOverride = const SystemUpdaterStatus(
      requestedIntervalDays: 7,
      appliedIntervalDays: 7,
      available: false,
      stale: true,
      lastResult: 'FAILED',
      checkedAt: '2026-09-27T01:01:00+08:00',
      error: '服务器调度读取失败',
    );
    await _refreshStatus(tester);
    expect(find.text('服务器更新调度异常'), findsOneWidget);
    expect(find.text('服务器调度读取失败'), findsOneWidget);
    expect(find.text('上次检查结果：检查失败'), findsOneWidget);
  });

  testWidgets('status read failure still allows saving an interval', (
    tester,
  ) async {
    final repo = _Repository()..statusFails = true;
    await _pump(tester, repo);
    expect(find.text('更新状态读取失败'), findsOneWidget);
    await _save(tester, '14');
    expect(repo.savedChanges!.single.value, '14');
    expect(find.text('更新状态读取失败'), findsOneWidget);
    expect(find.text('服务器已确认更新计划'), findsNothing);
  });

  testWidgets('server registry bounds reject out-of-range interval', (
    tester,
  ) async {
    final repo = _Repository();
    await _pump(tester, repo);
    await _save(tester, '366');
    expect(repo.savedChanges, isNull);
    final field = find.byKey(
      const ValueKey('system-setting-updater_check_interval_days'),
    );
    expect(
      tester.state<FormFieldState<String>>(field).errorText,
      contains('(0–365)'),
    );
  });

  testWidgets(
    'late pre-save response cannot overwrite the new requested state',
    (tester) async {
      final pending = Completer<SystemUpdaterStatus>();
      final repo = _Repository()..firstStatus = pending.future;
      await _pump(tester, repo);
      await _save(tester, '14');
      expect(find.text('已保存设置：每 14 天 05:00（服务器当地时间）'), findsOneWidget);
      pending.complete(_Repository.weeklyStatus);
      await tester.pumpAndSettle();
      expect(find.text('已保存设置：每 14 天 05:00（服务器当地时间）'), findsOneWidget);
      expect(find.text('服务器已确认更新计划'), findsNothing);
    },
  );

  testWidgets('update status fits narrow screens with enlarged text', (
    tester,
  ) async {
    final repo = _Repository();
    await _pump(tester, repo, width: 390, textScale: 1.6);
    await tester.ensureVisible(
      find.byKey(const ValueKey('system-updater-status')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

Future<void> _save(WidgetTester tester, String value) async {
  await tester.enterText(
    find.byKey(const ValueKey('system-setting-updater_check_interval_days')),
    value,
  );
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('system-settings-save')));
  await tester.pumpAndSettle();
}

Future<void> _refreshStatus(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('system-updater-status-refresh')));
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  _Repository repo, {
  double width = 1000,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [systemSettingRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
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
  );
  await tester.pumpAndSettle();
}

class _Repository implements SystemSettingRepository {
  String requested = '7';
  int applied = 7;
  int statusCalls = 0;
  bool statusFails = false;
  Future<SystemUpdaterStatus>? firstStatus;
  SystemUpdaterStatus? statusOverride;
  List<({String key, String value, String expectedValue})>? savedChanges;

  static const weeklyStatus = SystemUpdaterStatus(
    requestedIntervalDays: 7,
    appliedIntervalDays: 7,
    checkedAt: '2026-09-27T01:01:00+08:00',
    lastAttemptAt: '2026-09-20T05:00:00+08:00',
    nextCheckAt: '2026-10-04T05:00:00+08:00',
    lastResult: 'SUCCESS',
    available: true,
    stale: false,
  );

  @override
  Future<SystemUpdaterStatus> updaterStatus() async {
    statusCalls++;
    if (statusCalls == 1 && firstStatus != null) return firstStatus!;
    if (statusFails) throw const FormatException('status unavailable');
    return statusOverride ??
        SystemUpdaterStatus(
          requestedIntervalDays: int.parse(requested),
          appliedIntervalDays: applied,
          checkedAt: weeklyStatus.checkedAt,
          lastAttemptAt: weeklyStatus.lastAttemptAt,
          nextCheckAt: applied == 0 ? null : weeklyStatus.nextCheckAt,
          lastResult: weeklyStatus.lastResult,
          available: true,
          stale: int.parse(requested) != applied,
        );
  }

  @override
  Future<List<SystemSettingEntry>> list() async => [
    SystemSettingEntry(
      key: 'updater_check_interval_days',
      value: requested,
      valueType: 'int',
      category: 'updates',
      label: '自动更新检查间隔',
      description: '0 为手动；7 为每周日；其他为相应天数',
      unit: '天',
      sortOrder: 510,
      updatedAt: null,
      minValue: 0,
      maxValue: 365,
    ),
  ];

  @override
  Future<List<SystemSettingEntry>> updateBatch(
    List<({String key, String value, String expectedValue})> changes,
  ) async {
    savedChanges = changes;
    requested = changes.single.value;
    return list();
  }
}
