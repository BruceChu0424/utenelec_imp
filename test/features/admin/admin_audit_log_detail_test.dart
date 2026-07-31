import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/core/audit/device_audit_store.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/admin/models/audit_log_entry.dart';
import 'package:uten_imp/features/admin/pages/admin_audit_log_page.dart';
import 'package:uten_imp/features/admin/repositories/audit_log_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('system management can inspect redacted before and after JSON', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _AuditRepository();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          auditLogRepositoryProvider.overrideWithValue(repository),
          currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(home: AdminAuditLogPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('production_execution_segments'),
      findsOneWidget,
    );
    await tester.tap(find.textContaining('production_execution_segments'));
    await tester.pumpAndSettle();

    expect(find.text('审计详情 #42'), findsOneWidget);
    await tester.tap(find.widgetWithText(Tab, '数据变更'));
    await tester.pumpAndSettle();

    expect(find.text('status'), findsOneWidget);
    expect(find.text('READY'), findsOneWidget);
    expect(find.text('DISPATCHED'), findsOneWidget);
    await tester.ensureVisible(find.text('查看变更前原始 JSON'));
    await tester.tap(find.text('查看变更前原始 JSON'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"status": "READY"'), findsOneWidget);
    expect(repository.detailCalls, 1);
  });

  testWidgets('risk metric card drills down to risky operations', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _AuditRepository();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          auditLogRepositoryProvider.overrideWithValue(repository),
          currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(home: AdminAuditLogPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.lastRiskLevel, isNull);
    await tester.tap(find.text('风险行为'));
    await tester.pumpAndSettle();

    expect(repository.lastRiskLevel, 'risky');
    final exportButton = tester.widget<UtenExportButton>(
      find.byType(UtenExportButton),
    );
    expect(find.text('导出当前结果'), findsOneWidget);
    expect(exportButton.queryParams['riskLevel'], 'risky');
  });

  testWidgets(
    'device evidence compares the server row with the local receipt',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = _AuditRepository(earlyAttempt: true);
      final deviceStore = _DeviceStore();
      final api = _Api();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            auditLogRepositoryProvider.overrideWithValue(repository),
            currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
            sharedPreferencesProvider.overrideWithValue(preferences),
            deviceAuditStoreProvider.overrideWithValue(deviceStore),
            apiClientProvider.overrideWithValue(api),
          ],
          child: const MaterialApp(home: AdminAuditLogPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('production_execution_segments'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, '设备证据'));
      await tester.pumpAndSettle();

      expect(find.text('尚未核查本机回执'), findsOneWidget);
      expect(deviceStore.profileCalls, 0);
      expect(deviceStore.findCalls, 0);

      await tester.ensureVisible(find.text('授权并核对本机回执'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('授权并核对本机回执'));
      await tester.pumpAndSettle();

      expect(api.posts, [
        ApiEndpoints.adminAuditLocalReceiptVerification(_DeviceStore.eventId),
      ]);
      expect(deviceStore.profileCalls, 1);
      expect(deviceStore.findCalls, 1);
      expect(find.text('本机回执与服务器记录一致'), findsOneWidget);
      expect(find.text('测试电脑'), findsWidgets);
      expect(find.text('QA-1'), findsWidgets);
      expect(find.text(_DeviceStore.installationId), findsWidgets);
      expect(find.text('一致'), findsWidgets);
      expect(find.text('请求尝试链（2 次）'), findsOneWidget);
    },
  );

  testWidgets('device evidence authorization failure never reads local data', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _AuditRepository(earlyAttempt: true);
    final deviceStore = _DeviceStore();
    final api = _Api(postError: StateError('offline'));
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          auditLogRepositoryProvider.overrideWithValue(repository),
          currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
          sharedPreferencesProvider.overrideWithValue(preferences),
          deviceAuditStoreProvider.overrideWithValue(deviceStore),
          apiClientProvider.overrideWithValue(api),
        ],
        child: const MaterialApp(home: AdminAuditLogPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('production_execution_segments'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, '设备证据'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('授权并核对本机回执'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('授权并核对本机回执'));
    await tester.pumpAndSettle();

    expect(find.text('重新授权并核对'), findsOneWidget);
    expect(find.textContaining('未读取本机回执'), findsOneWidget);
    expect(api.posts, hasLength(1));
    expect(deviceStore.profileCalls, 0);
    expect(deviceStore.findCalls, 0);
  });
}

class _Api extends ApiClient {
  _Api({this.postError}) : super(Dio());

  final Object? postError;
  final posts = <String>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts.add(path);
    final error = postError;
    if (error != null) throw error;
    return const <String, dynamic>{};
  }
}

class _AuditRepository implements AuditLogRepository {
  _AuditRepository({this.earlyAttempt = false});

  final bool earlyAttempt;
  int detailCalls = 0;
  String? lastRiskLevel;

  @override
  Future<PagedResult<AuditLogEntry>> list({
    int page = 1,
    int size = 20,
    String? action,
    String? actorAccount,
    String? riskLevel,
    String? eventCategory,
    String? outcome,
    String? dateFrom,
    String? dateTo,
  }) async {
    lastRiskLevel = riskLevel;
    return const PagedResult(
      items: [
        AuditLogEntry(
          id: 42,
          actorAccount: 'planner',
          action: 'update',
          targetType: 'production_execution_segments',
          targetId: 'segment-1',
          result: 'success',
          createdAt: '2026-07-31T06:00:00+08:00',
        ),
      ],
      page: 1,
      size: 20,
      total: 1,
      totalPages: 1,
    );
  }

  @override
  Future<AuditSummary> summary({
    String? action,
    String? actorAccount,
    String? eventCategory,
    String? dateFrom,
    String? dateTo,
  }) async => const AuditSummary(
    total: 1,
    riskCount: 1,
    criticalCount: 0,
    failedCount: 0,
    dataChangeCount: 1,
    dailyTrend: [],
  );

  @override
  Future<AuditLogDetail> detail(int id) async {
    detailCalls++;
    return AuditLogDetail(
      id: 42,
      actorAccount: 'planner',
      action: 'update',
      targetType: 'production_execution_segments',
      targetId: 'segment-1',
      actionLabel: '修改',
      objectLabel: '生产执行分段',
      summary: '修改 · 生产执行分段',
      beforeJson: '{"status":"READY"}',
      afterJson: '{"status":"DISPATCHED"}',
      requestId: earlyAttempt
          ? _DeviceStore.earlyRequestId
          : _DeviceStore.requestId,
      clientEventId: _DeviceStore.eventId,
      device: const AuditDeviceEvidence(
        clientEventId: _DeviceStore.eventId,
        installationId: _DeviceStore.installationId,
        deviceName: '测试电脑',
        manufacturer: 'Uten',
        model: 'QA-1',
        platform: 'windows',
        osVersion: 'Windows Test',
        appVersion: '1.0.0',
        appBuild: 'test',
        formFactor: 'desktop',
        locale: 'zh_CN',
        timeZone: 'China Standard Time',
        timeZoneOffsetMinutes: 480,
        physicalDevice: true,
        clientEventAt: '2026-07-31T05:59:59+08:00',
        captureStatus: 'present',
        profileHash: 'device-profile-hash',
        clientDeclared: true,
      ),
      httpMethod: 'PATCH',
      httpPath: '/api/production/execution-segments/segment-1',
      statusCode: earlyAttempt ? 401 : 200,
      result: earlyAttempt ? 'failure' : 'success',
      createdAt: '2026-07-31T06:00:00+08:00',
    );
  }
}

class _DeviceStore implements DeviceAuditStore {
  static const eventId = '123e4567-e89b-42d3-a456-426614174010';
  static const installationId = '123e4567-e89b-42d3-a456-426614174011';
  static const requestId = '123e4567-e89b-42d3-a456-426614174012';
  static const earlyRequestId = '123e4567-e89b-42d3-a456-426614174013';

  static const _profile = DeviceAuditProfile(
    installationId: installationId,
    deviceName: '测试电脑',
    manufacturer: 'Uten',
    model: 'QA-1',
    platform: 'windows',
    osVersion: 'Windows Test',
    appVersion: '1.0.0',
    appBuild: 'test',
    formFactor: 'desktop',
    locale: 'zh_CN',
    timeZone: 'China Standard Time',
    timeZoneOffsetMinutes: 480,
    isPhysicalDevice: true,
  );

  int profileCalls = 0;
  int findCalls = 0;

  @override
  Future<DeviceAuditProfile> profile() async {
    profileCalls++;
    return _profile;
  }

  @override
  Future<LocalAuditReceipt?> findReceipt(String clientEventId) async {
    findCalls++;
    if (clientEventId != eventId) return null;
    return const LocalAuditReceipt(
      clientEventId: eventId,
      installationId: installationId,
      method: 'PATCH',
      path: '/api/production/execution-segments/segment-1',
      startedAt: '2026-07-31T05:59:59+08:00',
      completedAt: '2026-07-31T06:00:00+08:00',
      statusCode: 200,
      serverRequestId: requestId,
      outcome: 'success',
      device: _profile,
      integrityVerified: true,
      previousAttempts: [
        LocalAuditAttempt(
          method: 'PATCH',
          path: '/api/production/execution-segments/segment-1',
          startedAt: '2026-07-31T05:59:59+08:00',
          completedAt: '2026-07-31T05:59:59.500+08:00',
          statusCode: 401,
          serverRequestId: earlyRequestId,
          outcome: 'failure',
        ),
      ],
    );
  }

  @override
  Future<void> beginReceipt({
    required String clientEventId,
    required String method,
    required String path,
    required DateTime startedAt,
    required DeviceAuditProfile device,
  }) async {}

  @override
  Future<void> completeReceipt({
    required String clientEventId,
    required String outcome,
    required DateTime completedAt,
    int? statusCode,
    String? serverRequestId,
  }) async {}

  @override
  Future<void> updateRetentionMonths(int months) async {}
}
