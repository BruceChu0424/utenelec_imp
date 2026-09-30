// 系统设置页分组卡片自适应瀑布流网格(2026-09-28 UI 改版)的布局回归:
// 宽屏时 AI 服务入口卡与分组卡并排(一行多卡), 窄屏退回单列堆叠。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/admin/models/system_setting_entry.dart';
import 'package:uten_imp/features/admin/models/system_updater_status.dart';
import 'package:uten_imp/features/admin/pages/admin_system_settings_page.dart';
import 'package:uten_imp/features/admin/repositories/system_setting_repository.dart';

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [systemSettingRepositoryProvider.overrideWithValue(_Repo())],
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

void main() {
  testWidgets('wide layout puts the AI entry beside group cards', (
    tester,
  ) async {
    await _pump(tester, const Size(1600, 1200));
    final ai = tester.getTopLeft(
      find.byKey(const ValueKey('system-settings-ai-entry')),
    );
    final security = tester.getTopLeft(
      find.ancestor(of: find.text('安全策略'), matching: find.byType(Card)),
    );
    // 网格多列: AI 入口在首列, 第一张分组卡在右侧列, 顶部对齐。
    expect(security.dx, greaterThan(ai.dx));
    expect(security.dy, closeTo(ai.dy, 0.5));
  });

  testWidgets('narrow layout stacks everything in one column', (tester) async {
    await _pump(tester, const Size(400, 900));
    final ai = tester.getTopLeft(
      find.byKey(const ValueKey('system-settings-ai-entry')),
    );
    final security = tester.getTopLeft(
      find.ancestor(of: find.text('安全策略'), matching: find.byType(Card)),
    );
    // 单列: 两卡左缘对齐, 分组卡在 AI 入口之下。
    expect(security.dx, closeTo(ai.dx, 0.5));
    expect(security.dy, greaterThan(ai.dy));
  });
}

class _Repo implements SystemSettingRepository {
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

  final _settings = [
    _entry('lockout_minutes', '15', 'int', 'security'),
    _entry('password_history', '5', 'int', 'security'),
    _entry('access_token_ttl_minutes', '15', 'int', 'token'),
    _entry('sms_code_ttl_minutes', '5', 'int', 'sms'),
    _entry('audit_hot_retention_months', '6', 'int', 'audit'),
  ];

  @override
  Future<List<SystemSettingEntry>> list() async => _settings;

  @override
  Future<SystemUpdaterStatus> updaterStatus() => throw UnimplementedError();

  @override
  Future<List<SystemSettingEntry>> updateBatch(
    List<({String key, String value, String expectedValue})> changes,
  ) => throw UnimplementedError();
}
