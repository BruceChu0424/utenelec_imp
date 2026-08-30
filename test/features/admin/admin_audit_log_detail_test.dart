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
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('disabled export button does not open the password dialog', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: UtenExportButton(
              endpoint: '/admin/audit-logs/export',
              report: 'filtered',
              queryParams: <String, dynamic>{},
              enabled: false,
              label: '导出当前结果',
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('导出当前结果'));
    await tester.pumpAndSettle();

    expect(find.text('导出 Excel'), findsNothing);
  });

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

    await _scrollAuditPageUntilVisible(
      tester,
      find.textContaining('production_execution_segments'),
    );
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

  testWidgets('overview card explains the operation in plain Chinese', (
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

    await _scrollAuditPageUntilVisible(
      tester,
      find.textContaining('production_execution_segments'),
    );
    await tester.tap(find.textContaining('production_execution_segments'));
    await tester.pumpAndSettle();

    // 叙事卡：标题 + 谁 + 何时/在哪 chips + 大字动作句 + 具体变更（字段名 + 新旧值胶囊）。
    expect(find.text('这次操作做了什么'), findsOneWidget);
    expect(
      find.text('修改生产执行分段：状态：READY → DISPATCHED'),
      findsWidgets,
    );
    expect(find.text('具体变更'), findsOneWidget);
    expect(find.text('状态'), findsWidgets);
    expect(find.text('READY'), findsWidgets);
    expect(find.text('DISPATCHED'), findsWidgets);
    expect(find.text('成功'), findsWidgets);
    expect(find.text('planner'), findsWidgets);
    expect(find.text('排查线索'), findsOneWidget);
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
    expect(exportButton.enabled, isTrue);
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

      await _scrollAuditPageUntilVisible(
        tester,
        find.textContaining('production_execution_segments'),
      );
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
      await tester.scrollUntilVisible(
        find.text('请求尝试链(2 次)'),
        240,
        scrollable: find
            .descendant(
              of: find.byType(TabBarView),
              matching: find.byType(Scrollable),
            )
            .last,
        maxScrolls: 20,
      );
      await tester.pumpAndSettle();
      expect(find.text('请求尝试链(2 次)'), findsOneWidget);
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

    await _scrollAuditPageUntilVisible(
      tester,
      find.textContaining('production_execution_segments'),
    );
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

  testWidgets(
    'initial list captures a high-water shared by summary and export',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
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

      expect(repository.listCalls, hasLength(1));
      expect(repository.listCalls.single['snapshotId'], isNull);
      expect(repository.listCalls.single['operationKind'], 'write');
      expect(repository.listCalls.single['actorScope'], 'user');
      expect(repository.summaryCalls.single['snapshotId'], 9001);
      expect(repository.summaryCalls.single['operationKind'], 'write');
      expect(repository.summaryCalls.single['actorScope'], 'user');

      final exportButton = tester.widget<UtenExportButton>(
        find.byType(UtenExportButton),
      );
      expect(exportButton.enabled, isTrue);
      expect(exportButton.queryParams['snapshotId'], 9001);
      expect(exportButton.queryParams['operationKind'], 'write');
      expect(exportButton.queryParams['actorScope'], 'user');
    },
  );

  testWidgets(
    'business object and operation changes start a fresh high-water',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
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

      final createChip = find.byKey(const ValueKey('audit-operation-create'));
      await _scrollAuditPageUntilVisible(tester, createChip);
      await tester.tap(createChip);
      await tester.pumpAndSettle();

      expect(repository.listCalls.last['operationKind'], 'create');
      expect(repository.listCalls.last['snapshotId'], isNull);
      expect(repository.summaryCalls.last['snapshotId'], 9001);

      final goodsChip = find.byKey(const ValueKey('audit-target-goods'));
      await _scrollAuditPageUntilVisible(tester, goodsChip);
      await tester.tap(goodsChip);
      await tester.pumpAndSettle();

      expect(repository.listCalls.last['targetType'], 'goods');
      expect(repository.listCalls.last['operationKind'], 'create');
      expect(repository.listCalls.last['snapshotId'], isNull);
    },
  );

  testWidgets(
    'security filter reveals anonymous events instead of AND hiding',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
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

      final securityChip = find.byKey(
        const ValueKey('audit-category-security'),
      );
      await tester.ensureVisible(securityChip);
      await tester.tap(securityChip);
      await tester.pumpAndSettle();

      expect(repository.listCalls.last['eventCategory'], 'security');
      expect(repository.listCalls.last['operationKind'], isNull);
      expect(repository.listCalls.last['actorScope'], isNull);
      expect(repository.listCalls.last['snapshotId'], isNull);
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('audit-operation-all')),
            )
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('audit-scope-all')))
            .selected,
        isTrue,
      );
    },
  );

  testWidgets('page jump reuses the captured high-water', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _AuditRepository(totalPages: 120);
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

    final jumpField = find.byKey(const ValueKey('audit-page-jump-field'));
    await _scrollAuditPageUntilVisible(tester, jumpField);
    await tester.enterText(jumpField, '79');
    await tester.tap(find.byKey(const ValueKey('audit-page-jump-button')));
    await tester.pumpAndSettle();

    expect(repository.listCalls.last['page'], 79);
    expect(repository.listCalls.last['snapshotId'], 9001);
    expect(repository.summaryCalls.last['snapshotId'], 9001);
  });

  testWidgets('Request ID waits for a complete UUID before querying', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
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

    final requestField = find.descendant(
      of: find.byKey(const ValueKey('audit-request-id-field')),
      matching: find.byType(TextField),
    );
    await tester.ensureVisible(requestField);
    await tester.enterText(requestField, '123e4567');
    await tester.pump(const Duration(milliseconds: 350));
    expect(repository.listCalls, hasLength(1));

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(repository.listCalls, hasLength(1));

    await tester.enterText(requestField, _DeviceStore.requestId);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(repository.listCalls.last['requestId'], _DeviceStore.requestId);
    expect(repository.listCalls.last['snapshotId'], isNull);
  });

  testWidgets('same operation action locates the exact Request ID', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
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

    await _scrollAuditPageUntilVisible(
      tester,
      find.textContaining('production_execution_segments'),
    );
    await tester.tap(find.textContaining('production_execution_segments'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('audit-locate-same-request')));
    await tester.pumpAndSettle();

    expect(repository.listCalls.last['requestId'], _DeviceStore.requestId);
    expect(repository.listCalls.last['operationKind'], isNull);
    expect(repository.listCalls.last['actorScope'], isNull);
    expect(repository.listCalls.last['snapshotId'], isNull);
  });

  testWidgets(
    'audit filters remain usable without overflow on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(360, 780);
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
      expect(tester.takeException(), isNull);

      await _scrollAuditPageUntilVisible(
        tester,
        find.byKey(const ValueKey('audit-target-suppliers')),
      );
      expect(find.text('系统/迁移'), findsOneWidget);
      expect(find.text('供应商'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _scrollAuditPageUntilVisible(
  WidgetTester tester,
  Finder finder,
) async {
  final pageScrollable = find
      .descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(
    finder,
    320,
    scrollable: pageScrollable,
    maxScrolls: 30,
  );
  await tester.pumpAndSettle();
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
  _AuditRepository({this.earlyAttempt = false, this.totalPages = 1});

  final bool earlyAttempt;
  final int totalPages;
  int detailCalls = 0;
  String? lastRiskLevel;
  final listCalls = <Map<String, Object?>>[];
  final summaryCalls = <Map<String, Object?>>[];

  @override
  Future<AuditLogPage> list({
    int page = 1,
    int size = 20,
    String? action,
    String? actorAccount,
    String? keyword,
    String? targetType,
    String? targetId,
    String? eventSource,
    String? requestId,
    String? operationKind,
    String? actorScope,
    int? snapshotId,
    String? riskLevel,
    String? eventCategory,
    String? outcome,
    String? dateFrom,
    String? dateTo,
  }) async {
    lastRiskLevel = riskLevel;
    listCalls.add({
      'page': page,
      'size': size,
      'action': action,
      'actorAccount': actorAccount,
      'keyword': keyword,
      'targetType': targetType,
      'targetId': targetId,
      'eventSource': eventSource,
      'requestId': requestId,
      'operationKind': operationKind,
      'actorScope': actorScope,
      'snapshotId': snapshotId,
      'riskLevel': riskLevel,
      'eventCategory': eventCategory,
      'outcome': outcome,
      'dateFrom': dateFrom,
      'dateTo': dateTo,
    });
    return AuditLogPage(
      items: const [
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
      page: page,
      size: 20,
      total: totalPages,
      totalPages: totalPages,
      snapshotId: snapshotId ?? 9001,
    );
  }

  @override
  Future<AuditSummary> summary({
    String? action,
    String? actorAccount,
    String? keyword,
    String? targetType,
    String? targetId,
    String? eventSource,
    String? requestId,
    String? operationKind,
    String? actorScope,
    int? snapshotId,
    String? eventCategory,
    String? dateFrom,
    String? dateTo,
  }) async {
    summaryCalls.add({
      'action': action,
      'actorAccount': actorAccount,
      'keyword': keyword,
      'targetType': targetType,
      'targetId': targetId,
      'eventSource': eventSource,
      'requestId': requestId,
      'operationKind': operationKind,
      'actorScope': actorScope,
      'snapshotId': snapshotId,
      'eventCategory': eventCategory,
      'dateFrom': dateFrom,
      'dateTo': dateTo,
    });
    return const AuditSummary(
      total: 1,
      riskCount: 1,
      criticalCount: 0,
      failedCount: 0,
      dataChangeCount: 1,
      dailyTrend: [],
    );
  }

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
      summary: '修改生产执行分段：状态：READY → DISPATCHED',
      resultLabel: '成功',
      changeSummary: '状态：READY → DISPATCHED',
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
