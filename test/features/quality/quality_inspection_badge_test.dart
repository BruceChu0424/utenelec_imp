import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/dashboard/widgets/module_badge_sum.dart';
import 'package:uten_imp/features/quality/pages/quality_task_center_page.dart';
import 'package:uten_imp/features/warehouse/pages/procurement_inspection_page.dart';
import 'package:uten_imp/features/warehouse/providers/procurement_inbound_count_providers.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inspection_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets('workbench quality badge shows a positive pending count', (
    tester,
  ) async {
    await _pumpWorkbenchBadge(tester, count: 4);

    expect(
      find.descendant(
        of: find.byType(WorkbenchCardBadge),
        matching: find.text('4'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('workbench quality badge is hidden when pending count is zero', (
    tester,
  ) async {
    await _pumpWorkbenchBadge(tester, count: 0);

    expect(
      find.descendant(
        of: find.byType(WorkbenchCardBadge),
        matching: find.byType(Container),
      ),
      findsNothing,
    );
    expect(find.text('0'), findsNothing);
  });

  testWidgets('quality count failure is not presented as a real zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          procurementInspectionPendingCountProvider.overrideWith(
            (ref) => Future<int>.error(StateError('offline')),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: WorkbenchCardBadge(
              kind: WorkbenchBadgeKind.qualityInspection,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('procurement-inspection-badge-error')),
      findsOneWidget,
    );
    expect(find.text('0'), findsNothing);
  });

  test(
    'quality pending provider does not request without view permission',
    () async {
      final repository = _FakeInspectionRepository(pendingCountValue: 5);
      final container = ProviderContainer(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const <String>{}),
          isSuperAdminProvider.overrideWithValue(false),
          procurementInspectionRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);

      expect(
        await container.read(procurementInspectionPendingCountProvider.future),
        0,
      );
      expect(repository.pendingCountCalls, 0);
    },
  );

  testWidgets('quality task entry carries its return path to inspection', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: RouteName.qualityTaskCenter,
      routes: [
        GoRoute(
          path: RouteName.qualityTaskCenter,
          builder: (_, _) => const QualityTaskCenterPage(),
        ),
        GoRoute(
          path: RouteName.warehouseInspections,
          builder: (_, _) => const Scaffold(body: Text('待检处置工作台已打开')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue({
            Perm.procurementInspectionView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          procurementInspectionPendingCountProvider.overrideWith(
            (ref) async => 0,
          ),
        ],
        child: _routerApp(router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('待检处置'));
    await tester.pumpAndSettle();

    final uri = router.routeInformationProvider.value.uri;
    expect(uri.path, RouteName.warehouseInspections);
    expect(uri.queryParameters['returnTo'], RouteName.qualityTaskCenter);
  });

  testWidgets('deep-linked inspection returns to quality task center', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = _FakeInspectionRepository();
    final router = GoRouter(
      initialLocation: RouteName.warehouseInspections,
      routes: [
        GoRoute(
          path: RouteName.warehouseInspections,
          builder: (_, _) => const ProcurementInspectionPage(),
        ),
        GoRoute(
          path: RouteName.qualityTaskCenter,
          builder: (_, _) => const Scaffold(body: Text('已返回品质任务中心')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          procurementInspectionRepositoryProvider.overrideWithValue(repository),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: _routerApp(router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(
      router.routeInformationProvider.value.uri.path,
      RouteName.qualityTaskCenter,
    );
    expect(find.text('已返回品质任务中心'), findsOneWidget);
  });

  testWidgets('returning to quality task center refreshes its pending badge', (
    tester,
  ) async {
    final repository = _FakeInspectionRepository(pendingCountValue: 1);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue({
            Perm.procurementInspectionView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          procurementInspectionRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: QualityTaskCenterPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(repository.pendingCountCalls, 1);
    expect(find.text('1'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(QualityTaskCenterPage)),
    );
    container.read(pageResumeProvider.notifier).state = (
      location: RouteName.warehouseInspections,
      tick: 1,
    );
    await tester.pump();

    repository.pendingCountValue = 2;
    container.read(pageResumeProvider.notifier).state = (
      location: RouteName.qualityTaskCenter,
      tick: 2,
    );
    await tester.pumpAndSettle();

    expect(repository.pendingCountCalls, 2);
    expect(find.text('2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'PASS confirmation shows reviewer responsibility and accepts an empty note',
    (tester) async {
      final repository = _dispositionRepository();
      await _pumpInspectionDispositionPage(tester, repository);

      await _openFirstInspectionItem(tester);
      expect(
        find.byKey(const Key('reviewer-responsibility-notice')),
        findsOneWidget,
      );
      expect(find.text('审核员：品质审核员(QA-001)'), findsOneWidget);
      expect(find.text('系统将记录审核员、结论、数量与时间，请依据本行实物检验结果确认。'), findsOneWidget);
      expect(find.text('放行说明(选填)'), findsOneWidget);

      await tester.tap(find.text('确认合格'));
      await tester.pumpAndSettle();

      expect(repository.disposeCalls, hasLength(1));
      expect(repository.disposeCalls.single.action, 'PASS');
      expect(repository.disposeCalls.single.reason, isNull);
      expect(repository.disposeCalls.single.baseQty, isNull);
    },
  );

  testWidgets(
    'FAIL confirmation shows reviewer responsibility and rejects an empty reason',
    (tester) async {
      final repository = _dispositionRepository();
      await _pumpInspectionDispositionPage(tester, repository);

      await _openFirstInspectionItem(tester);
      await tester.tap(find.byKey(const Key('iqc-action-fail')));
      await tester.pumpAndSettle();

      expect(find.text('审核员：品质审核员(QA-001)'), findsOneWidget);
      expect(find.text('不合格原因(必填)'), findsOneWidget);

      await tester.tap(find.text('确认不合格'));
      await tester.pump();

      expect(find.text('不合格原因必填'), findsOneWidget);
      expect(find.text('检验本行'), findsOneWidget);
      expect(repository.disposeCalls, isEmpty);
    },
  );

  testWidgets(
    'same receipt stays open after one decision and shows the next item',
    (tester) async {
      final repository = _twoItemDispositionRepository();
      await _pumpInspectionDispositionPage(tester, repository);

      final first = find.text('测试物料A(G0001)');
      await tester.tap(first);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认合格'));
      await tester.pumpAndSettle();

      expect(repository.disposeCalls, hasLength(1));
      expect(find.byKey(const Key('iqc-item-table-receipt-1')), findsOneWidget);
      expect(find.text('测试物料B(G0002)'), findsOneWidget);
      expect(find.text('CJ20260822000001'), findsNWidgets(2));
    },
  );

  testWidgets('selected lines use one atomic batch pass request', (
    tester,
  ) async {
    final repository = _twoItemDispositionRepository();
    await _pumpInspectionDispositionPage(tester, repository);

    await tester.tap(find.text('测试物料A(G0001)'));
    await tester.pump();
    await tester.tap(find.text('测试物料B(G0002)'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('iqc-batch-pass')));
    await tester.pumpAndSettle();

    expect(find.text('批量合格放行 2 条'), findsOneWidget);
    expect(
      find.byKey(const Key('reviewer-responsibility-notice')),
      findsOneWidget,
    );
    await tester.tap(find.text('确认整批合格'));
    await tester.pumpAndSettle();

    expect(repository.batchPassCalls, hasLength(1));
    final call = repository.batchPassCalls.single;
    expect(call.items.map((item) => item.inspectionItemId).toSet(), {
      'inspection-item-1',
      'inspection-item-2',
    });
    expect(call.items.map((item) => item.expectedRemainingBaseQty).toSet(), {
      5,
      3,
    });
    expect(call.reason, isNull);
    expect(repository.disposeCalls, isEmpty);
  });

  testWidgets(
    '375px keeps receipt queue and item table operable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pumpInspectionDispositionPage(
        tester,
        _twoItemDispositionRepository(),
      );

      expect(find.byKey(const Key('iqc-receipt-queue-table')), findsOneWidget);
      expect(find.byKey(const Key('iqc-item-table-receipt-1')), findsOneWidget);
      expect(find.byKey(const Key('iqc-batch-pass')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('global badge refresh includes the quality pending provider', () {
    final source = File(
      'lib/features/dashboard/providers/workbench_refresh.dart',
    ).readAsStringSync();

    expect(
      source,
      contains('ref.invalidate(procurementInspectionPendingCountProvider);'),
    );
  });
}

Future<void> _pumpWorkbenchBadge(
  WidgetTester tester, {
  required int count,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        procurementInspectionPendingCountProvider.overrideWith(
          (ref) async => count,
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: WorkbenchCardBadge(kind: WorkbenchBadgeKind.qualityInspection),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpInspectionDispositionPage(
  WidgetTester tester,
  _FakeInspectionRepository repository,
) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_QualityReviewerSessionNotifier.new),
        currentPermissionsProvider.overrideWithValue({
          Perm.procurementInspectionView,
          Perm.procurementInspectionHandle,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        procurementInspectionRepositoryProvider.overrideWithValue(repository),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: const MaterialApp(home: ProcurementInspectionPage()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openFirstInspectionItem(WidgetTester tester) async {
  expect(find.byKey(const Key('iqc-receipt-queue-table')), findsOneWidget);
  expect(find.byKey(const Key('iqc-item-table-receipt-1')), findsOneWidget);
  final row = find.text('测试物料(G0001)');
  expect(row, findsOneWidget);
  await tester.tap(row);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(row);
  await tester.pumpAndSettle();
  expect(find.text('检验本行'), findsOneWidget);
  expect(find.byKey(const Key('iqc-action-pass')), findsOneWidget);
  expect(find.byKey(const Key('iqc-action-fail')), findsOneWidget);
}

_FakeInspectionRepository _dispositionRepository() => _FakeInspectionRepository(
  receipts: const [
    PendingInspectionReceipt(
      receiptType: 'PURCHASE',
      receiptId: 'receipt-1',
      billNo: 'CJ20260822000001',
      itemCount: 1,
      pendingBaseQty: 5,
    ),
  ],
  inspectionItems: const [
    ProcurementInspectionItem(
      id: 'inspection-item-1',
      receiptItemId: 'receipt-item-1',
      goodsId: 'goods-1',
      goodsCode: 'G0001',
      goodsName: '测试物料',
      receivedBaseQty: 5,
      passedBaseQty: 0,
      failedBaseQty: 0,
      remainingBaseQty: 5,
      status: 'PENDING',
    ),
  ],
);

_FakeInspectionRepository _twoItemDispositionRepository() =>
    _FakeInspectionRepository(
      receipts: const [
        PendingInspectionReceipt(
          receiptType: 'PURCHASE',
          receiptId: 'receipt-1',
          billNo: 'CJ20260822000001',
          itemCount: 2,
          pendingBaseQty: 8,
        ),
      ],
      inspectionItems: const [
        ProcurementInspectionItem(
          id: 'inspection-item-1',
          receiptItemId: 'receipt-item-1',
          goodsId: 'goods-1',
          goodsCode: 'G0001',
          goodsName: '测试物料A',
          receivedBaseQty: 5,
          passedBaseQty: 0,
          failedBaseQty: 0,
          remainingBaseQty: 5,
          status: 'PENDING',
        ),
        ProcurementInspectionItem(
          id: 'inspection-item-2',
          receiptItemId: 'receipt-item-2',
          goodsId: 'goods-2',
          goodsCode: 'G0002',
          goodsName: '测试物料B',
          receivedBaseQty: 3,
          passedBaseQty: 0,
          failedBaseQty: 0,
          remainingBaseQty: 3,
          status: 'PENDING',
        ),
      ],
    );

Widget _routerApp(GoRouter router) {
  return MaterialApp.router(
    routerConfig: router,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
  );
}

class _FakeInspectionRepository implements ProcurementInspectionRepository {
  _FakeInspectionRepository({
    this.pendingCountValue = 0,
    List<PendingInspectionReceipt> receipts = const [],
    List<ProcurementInspectionItem> inspectionItems = const [],
  }) : receipts = List.of(receipts),
       inspectionItems = List.of(inspectionItems);

  int pendingCountValue;
  int pendingCountCalls = 0;
  final List<PendingInspectionReceipt> receipts;
  final List<ProcurementInspectionItem> inspectionItems;
  final List<_DispositionCall> disposeCalls = [];
  final List<_BatchPassCall> batchPassCalls = [];

  @override
  Future<int> pendingCount() async {
    pendingCountCalls += 1;
    return pendingCountValue;
  }

  @override
  Future<List<PendingInspectionReceipt>> pendingReceipts() async => receipts;

  @override
  Future<List<ProcurementInspectionItem>> items(
    String receiptType,
    String receiptId,
  ) async => inspectionItems;

  @override
  Future<void> dispose({
    required String receiptType,
    required String receiptId,
    required String inspectionItemId,
    required String action,
    double? baseQty,
    String? reason,
    required String idempotencyKey,
  }) async {
    disposeCalls.add(
      _DispositionCall(action: action, baseQty: baseQty, reason: reason),
    );
    inspectionItems.removeWhere((item) => item.id == inspectionItemId);
    if (inspectionItems.isEmpty) receipts.clear();
  }

  @override
  Future<void> passBatch({
    required String receiptType,
    required String receiptId,
    required List<ProcurementInspectionBatchPassItem> items,
    String? reason,
  }) async {
    batchPassCalls.add(_BatchPassCall(items: List.of(items), reason: reason));
    final ids = items.map((item) => item.inspectionItemId).toSet();
    inspectionItems.removeWhere((item) => ids.contains(item.id));
    if (inspectionItems.isEmpty) receipts.clear();
  }
}

class _QualityReviewerSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'user-qa-1',
      code: 'QA-001',
      name: '品质审核员',
      roles: [],
      employeeId: 'employee-qa-1',
    ),
  );
}

class _DispositionCall {
  const _DispositionCall({
    required this.action,
    required this.baseQty,
    required this.reason,
  });

  final String action;
  final double? baseQty;
  final String? reason;
}

class _BatchPassCall {
  const _BatchPassCall({required this.items, required this.reason});

  final List<ProcurementInspectionBatchPassItem> items;
  final String? reason;
}
