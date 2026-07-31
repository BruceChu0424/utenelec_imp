import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/audit/device_audit_store.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/settings/pages/device_audit_receipts_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('original device can look up a receipt by operation id', (
    tester,
  ) async {
    final store = _Store();
    final api = _Api();
    await _pumpPage(tester, store: store, api: api);

    await tester.enterText(find.byType(TextField), _Store.eventId);
    await tester.tap(find.text('查询本机回执'));
    await tester.pumpAndSettle();

    expect(find.text('完整性通过'), findsOneWidget);
    expect(find.text('请求尝试'), findsOneWidget);
    expect(find.text('2 次'), findsOneWidget);
    expect(find.textContaining(_Store.firstRequestId), findsOneWidget);
    expect(find.textContaining(_Store.secondRequestId), findsOneWidget);
    expect(api.posts, [
      ApiEndpoints.adminAuditLocalReceiptVerification(_Store.eventId),
    ]);
    expect(store.findCalls, 1);
  });

  testWidgets('authorization failure never reads the local receipt', (
    tester,
  ) async {
    final store = _Store();
    final api = _Api(postError: StateError('offline'));
    await _pumpPage(tester, store: store, api: api);

    await tester.enterText(find.byType(TextField), _Store.eventId);
    await tester.tap(find.text('查询本机回执'));
    await tester.pumpAndSettle();

    expect(find.text('需联网完成授权核查'), findsOneWidget);
    expect(store.findCalls, 0);
    expect(api.posts, hasLength(1));
  });

  testWidgets('receipt surface is explicitly read-only with no delete action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pumpPage(tester, store: _Store(), api: _Api());

      expect(
        tester.getSemantics(
          find.byKey(const ValueKey('device-audit-read-only')),
        ),
        matchesSemantics(label: '本机操作回执只读核查', isReadOnly: true),
      );
      expect(find.text('只读核查'), findsOneWidget);
      expect(find.text('清除本机回执'), findsNothing);
      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
    } finally {
      semantics.dispose();
    }
  });
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required _Store store,
  required _Api api,
}) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deviceAuditStoreProvider.overrideWithValue(store),
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: const MaterialApp(
        home: DeviceAuditReceiptsPage(backRoute: '/settings'),
      ),
    ),
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

class _Store implements DeviceAuditStore {
  static const eventId = '123e4567-e89b-42d3-a456-426614174050';
  static const firstRequestId = '123e4567-e89b-42d3-a456-426614174051';
  static const secondRequestId = '123e4567-e89b-42d3-a456-426614174052';

  static const profileValue = DeviceAuditProfile(
    installationId: '123e4567-e89b-42d3-a456-426614174053',
    deviceName: '原操作电脑',
    manufacturer: 'Uten',
    model: 'QA-2',
    platform: 'windows',
    osVersion: 'Windows Test',
    appVersion: '2.0.0',
    appBuild: 'build-test',
    formFactor: 'desktop',
  );

  int findCalls = 0;

  @override
  Future<DeviceAuditProfile> profile() async => profileValue;

  @override
  Future<LocalAuditReceipt?> findReceipt(String clientEventId) async {
    findCalls++;
    if (clientEventId != eventId) return null;
    return const LocalAuditReceipt(
      clientEventId: eventId,
      installationId: '123e4567-e89b-42d3-a456-426614174053',
      method: 'GET',
      path: '/api/orders',
      startedAt: '2026-07-31T02:00:00Z',
      completedAt: '2026-07-31T02:00:01Z',
      statusCode: 200,
      serverRequestId: secondRequestId,
      outcome: 'success',
      device: profileValue,
      integrityVerified: true,
      previousAttempts: [
        LocalAuditAttempt(
          method: 'GET',
          path: '/api/orders',
          startedAt: '2026-07-31T02:00:00Z',
          completedAt: '2026-07-31T02:00:00.200Z',
          statusCode: 503,
          serverRequestId: firstRequestId,
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
