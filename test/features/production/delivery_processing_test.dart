import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_floating_window.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/production/delivery_processing/delivery_processing_repository.dart';
import 'package:uten_imp/features/production/delivery_processing/delivery_processing_tasks_button.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

Map<String, dynamic> _task({int version = 1, bool done = false}) => {
  'componentId': 'component-1',
  'shipmentId': 'shipment-1',
  'shipmentNo': 'SH-001',
  'goodsName': '后座',
  'goodsCode': 'BASE',
  'unitName': '个',
  'requiredQtyExact': '100',
  'completedQtyExact': done ? '100' : '0',
  'remainingQtyExact': done ? '0' : '100',
  'operations': ['LASER'],
  'processingTargets': [
    {
      'path': ['child'],
      'code': 'LASER-PLATE',
      'name': '激光刻字面板',
      'quantityExact': '200',
      'quantityNumerator': '200',
      'quantityDenominator': '1',
      'unitName': '片',
      'operations': ['LASER'],
    },
  ],
  'status': done ? 'COMPLETED' : 'IN_PROGRESS',
  'version': version,
  'workshopDepartmentId': 'workshop',
  'workshopName': '激光车间',
  'startedAt': '2026-11-04T00:00:00Z',
  'canAssign': false,
  'canStart': false,
  'canReport': !done,
};

class _Api extends Fake implements ApiClient {
  int posts = 0;
  bool networkFailure = true, recorded = false;
  final bodies = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts++;
    bodies.add(Map<String, dynamic>.from(body as Map));
    if (networkFailure) throw NetworkTimeoutException();
    return _task(version: 2, done: true);
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {'recorded': recorded};
}

class _Repository extends DeliveryProcessingRepository {
  _Repository(super.api);
  Completer<DeliveryProcessingTask>? pendingResponse;
  int submits = 0, reads = 0;
  @override
  Future<DeliveryProcessingPage> list(
    String? shipmentId, {
    int page = 1,
    String? keyword,
  }) async =>
      DeliveryProcessingPage([DeliveryProcessingTask(_task())], 1, 1, 1);
  @override
  Future<DeliveryProcessingTask> get(String id) async {
    reads++;
    return DeliveryProcessingTask(_task());
  }

  @override
  Future<DeliveryProcessingTask> submit(
    DeliveryProcessingTask task,
    String action,
    Map<String, dynamic> values,
  ) {
    submits++;
    return pendingResponse?.future ?? super.submit(task, action, values);
  }
}

Future<void> _pump(WidgetTester tester, _Repository repo) async {
  await tester.binding.setSurfaceSize(const Size(1280, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deliveryProcessingRepositoryProvider.overrideWithValue(repo),
        currentPermissionsProvider.overrideWithValue({
          'production_execution:view',
        }),
        isSuperAdminProvider.overrideWithValue(false),
        sensitiveReadBoundaryProvider.overrideWithValue(
          SensitiveReadBoundary(
            identity: null,
            api: repo.api,
            permissions: {'production_execution:view'},
            superAdmin: false,
          ),
        ),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        supportedLocales: [Locale('zh')],
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: DeliveryProcessingTasksButton(shipmentId: 'shipment-1'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('交付件加工任务'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(TextButton, '办理').first);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'unknown report retains the exact original UUID, quantity and expected version',
    () async {
      final api = _Api(), repo = DeliveryProcessingRepository(_Api());
      final active = DeliveryProcessingRepository(api);
      final task = DeliveryProcessingTask(_task());
      await expectLater(
        active.submit(task, 'reports', {
          'quantity': '0.000000000000000000000001',
          'operation': 'LASER',
          'evidence': '实测完成',
        }),
        throwsA(isA<NetworkTimeoutException>()),
      );
      final pending = active.pending[task.id]!;
      expect(pending.body['expectedVersion'], 1);
      expect(pending.body['quantity'], '0.000000000000000000000001');
      expect(await active.reconcile(pending), false);
      expect(active.pending[task.id], same(pending));
      api.networkFailure = false;
      await active.retry(pending);
      expect(api.posts, 2);
      expect(api.bodies[0], api.bodies[1]);
      expect(active.pending, isEmpty);
      expect(repo.pending, isEmpty);
    },
  );

  test(
    'confirmed request reconciliation clears pending without resubmitting',
    () async {
      final api = _Api(), repo = DeliveryProcessingRepository(_Api());
      final active = DeliveryProcessingRepository(api),
          task = DeliveryProcessingTask(_task());
      await expectLater(
        active.submit(task, 'reports', {
          'quantity': '100',
          'operation': 'LASER',
          'evidence': '已加工',
        }),
        throwsA(isA<NetworkTimeoutException>()),
      );
      api.recorded = true;
      expect(await active.reconcile(active.pending[task.id]!), true);
      expect(api.posts, 1);
      expect(active.pending, isEmpty);
      expect(repo.pending, isEmpty);
    },
  );

  testWidgets(
    'real processing form uses a movable window and one waiting layer during report',
    (tester) async {
      final repo = _Repository(ApiClient(Dio()))..pendingResponse = Completer();
      await _pump(tester, repo);
      expect(
        find.byType(UtenFloatingWindow, skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('交付件加工办理'), findsOneWidget);
      expect(find.text('激光刻字面板'), findsWidgets);
      expect(repo.reads, 1);
      expect(
        find.byKey(const ValueKey('delivery-processing-evidence')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('delivery-processing-evidence')),
        '激光图样和检验记录',
      );
      await tester.pump();
      await tester.tap(find.text('提交加工报工'));
      await tester.pump();
      expect(repo.submits, 1);
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      repo.pendingResponse!.complete(
        DeliveryProcessingTask(_task(version: 2, done: true)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(find.text('提交加工报工'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('delivery-processing-panel-close')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UtenFloatingWindow), findsOneWidget);
      expect(find.text('交付件加工办理'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('narrow enlarged processing panel keeps the report reachable', (
    tester,
  ) async {
    final repo = _Repository(ApiClient(Dio()))..pendingResponse = Completer();
    await _pump(tester, repo);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.binding.setSurfaceSize(const Size(390, 900));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final evidence = find.byKey(const ValueKey('delivery-processing-evidence'));
    await tester.ensureVisible(evidence);
    await tester.enterText(evidence, '全部面板完成激光并检验');
    await tester.pump();
    await tester.ensureVisible(find.text('提交加工报工'));
    await tester.tap(find.text('提交加工报工'));
    await tester.pump();
    expect(repo.submits, 1);
    repo.pendingResponse!.complete(
      DeliveryProcessingTask(_task(version: 2, done: true)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
