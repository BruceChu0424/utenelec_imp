import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/pages/operations_workbench_page.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_decomposition_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../subcontract/fake_subcontract_draw_gateway.dart';

final _reader = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'a'),
);
final _department = StateProvider<OperationsWorkbenchDepartment>(
  (_) => OperationsWorkbenchDepartment.purchase,
);

void main() {
  testWidgets(
    'query transitions hide old completed rows while same-query refresh keeps accepted rows',
    (tester) async {
      final gateway = _Gateway()..nextStage = 'COMPLETED';
      await _mount(tester, gateway, false);
      await tester.pumpAndSettle();
      expect(
        find.text('PRIVATE-A'),
        findsNothing,
        reason: 'the initial overview has no selected stage',
      );
      final progress = Completer<OperationsWorkbenchData>();
      gateway.responses.add(progress);
      await tester.tap(find.text('进行中'));
      await tester.pump();
      expect(
        find.text('PRIVATE-A'),
        findsNothing,
        reason:
            'the overview completed rows cannot appear beneath the newly selected in-progress stage',
      );
      progress.complete(
        _data(
          OperationsWorkbenchDepartment.purchase,
          'IN-PROGRESS',
          stageOverride: 'IN_PROGRESS',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('IN-PROGRESS'), findsOneWidget);
      final refresh = Completer<OperationsWorkbenchData>();
      gateway.responses.add(refresh);
      await tester.tap(find.byTooltip('刷新'));
      await tester.pump();
      expect(
        find.text('IN-PROGRESS'),
        findsOneWidget,
        reason: 'a refresh of the same query can retain its accepted rows',
      );
      final history = Completer<OperationsWorkbenchData>();
      gateway.responses.add(history);
      await tester.tap(find.text('历史记录'));
      await tester.pump();
      expect(
        find.text('IN-PROGRESS'),
        findsNothing,
        reason:
            'a history query must clear rows of the prior stage before its response',
      );
      refresh.completeError(ApiException('FORBIDDEN', 'OLD QUERY ERROR'));
      await tester.pump();
      expect(find.text('OLD QUERY ERROR'), findsNothing);
      history.complete(
        _data(
          OperationsWorkbenchDepartment.purchase,
          'HISTORY',
          stageOverride: 'COMPLETED',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('HISTORY'), findsOneWidget);
      expect(find.text('IN-PROGRESS'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  for (final subcontract in [false, true]) {
    testWidgets(
      '${subcontract ? 'subcontract' : 'purchase'} workbench clears rows and ignores old reader failure',
      (tester) async {
        final gateway = _Gateway();
        // ADR-184：初始概览 statusCounts 是 WAITING_ORDER 红 1，用同值事实
        // 恢复「待处理/申请待分解」段自动选中，PRIVATE-A 随首段加载出现。
        final container = await _mount(
          tester,
          gateway,
          subcontract,
          facts: subcontract
              ? const {
                  BadgeFact.subcontractTaskWaitingOrder: 1,
                  BadgeFact.subcontractTaskRework: 0,
                  BadgeFact.subcontractTaskShortDelivery: 0,
                  BadgeFact.subcontractTaskInProgress: 0,
                }
              : const {
                  BadgeFact.purchaseTaskWaitingOrder: 1,
                  BadgeFact.purchaseTaskRework: 0,
                  BadgeFact.purchaseTaskInProgress: 0,
                },
        );
        await tester.pumpAndSettle();
        expect(find.text('PRIVATE-A'), findsOneWidget);
        final old = Completer<OperationsWorkbenchData>();
        gateway.responses.add(old);
        await tester.tap(find.byTooltip(subcontract ? '刷新委外任务' : '刷新'));
        await tester.pump();
        final fresh = Completer<OperationsWorkbenchData>();
        gateway.responses.add(fresh);
        container.read(_reader.notifier).state = const AuthenticatedScope(
          userId: 'b',
        );
        await tester.pump();
        expect(find.text('PRIVATE-A'), findsNothing);
        old.completeError(ApiException('FORBIDDEN', 'OLD PRIVATE ERROR'));
        await tester.pump();
        expect(find.text('OLD PRIVATE ERROR'), findsNothing);
        fresh.complete(
          _data(
            subcontract
                ? OperationsWorkbenchDepartment.subcontract
                : OperationsWorkbenchDepartment.purchase,
            'FRESH-B',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('FRESH-B'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'changing shared workbench department invalidates the old in-flight summary',
    (tester) async {
      final gateway = _Gateway();
      // ADR-184：采购段红 1 维持原自动选中；切到仓库部门后「待备料 / 待领取」
      // 段红 1 才能自动选中并展示 WAREHOUSE-B 行。
      final container = await _mount(
        tester,
        gateway,
        false,
        facts: const {
          BadgeFact.purchaseTaskWaitingOrder: 1,
          BadgeFact.purchaseTaskRework: 0,
          BadgeFact.purchaseTaskInProgress: 0,
          BadgeFact.productionDrawReady: 1,
          BadgeFact.productionDrawPartial: 0,
          BadgeFact.productionDrawMaterialsToDefine: 0,
        },
      );
      await tester.pumpAndSettle();
      final old = Completer<OperationsWorkbenchData>();
      gateway.responses.add(old);
      await tester.tap(find.byTooltip('刷新'));
      await tester.pump();
      gateway.nextLabel = 'WAREHOUSE-B';
      container.read(_department.notifier).state =
          OperationsWorkbenchDepartment.warehouse;
      await tester.pumpAndSettle();
      old.complete(
        _data(OperationsWorkbenchDepartment.purchase, 'LATE-PURCHASE-A'),
      );
      await tester.pumpAndSettle();
      expect(find.text('仓库任务工作台'), findsOneWidget);
      expect(find.text('WAREHOUSE-B'), findsOneWidget);
      expect(find.text('PRIVATE-A'), findsNothing);
      expect(find.text('LATE-PURCHASE-A'), findsNothing);
      expect(gateway.departments.last, OperationsWorkbenchDepartment.warehouse);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Gateway gateway,
  bool subcontract, {
  Map<String, int> facts = const {},
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues(const {});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(_Api()),
        apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
        sharedPreferencesProvider.overrideWithValue(prefs),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_reader)),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.subcontractApplicationView,
          Perm.subcontractOrderView,
        }),
        // ADR-184：阶段红黄数改由徽章事实提供。facts 为空 = 无红黄数，
        // 分段回落中性浏览数且不自动选中（首个用例依赖「未选阶段」形态）。
        fixedBadgeSummaryOverride(badgeSummaryFixture(facts: facts)),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (_, ref, _) => subcontract
              ? SubcontractDecompositionPage(
                  repository: gateway,
                  drawRepository: FakeSubcontractDrawGateway(),
                )
              : OperationsWorkbenchPage(
                  department: ref.watch(_department),
                  repository: gateway,
                ),
        ),
      ),
    ),
  );
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

OperationsWorkbenchData _data(
  OperationsWorkbenchDepartment department,
  String label, {
  String? stageOverride,
}) {
  final stage =
      stageOverride ??
      (department == OperationsWorkbenchDepartment.warehouse
          ? 'READY_TO_PICK'
          : 'WAITING_ORDER');
  return OperationsWorkbenchData(
    department: department,
    summary: OperationsWorkbenchSummary(
      totalTasks: 1,
      overdueTasks: 0,
      openTasks: 1,
      openQty: 4,
      statusCounts: {stage: 1},
    ),
    items: [
      OperationsWorkbenchTask.fromJson({
        'taskId': label,
        'planNo': label,
        'goodsName': 'Part',
        'requiredQty': 4,
        'openQty': 4,
        'taskStatus': stage,
        'supplyRoute': department == OperationsWorkbenchDepartment.subcontract
            ? 'SUBCONTRACT'
            : 'PURCHASE',
        'actionDocType': department == OperationsWorkbenchDepartment.purchase
            ? 'PURCHASE_REQUEST'
            : department == OperationsWorkbenchDepartment.subcontract
            ? 'SUBCONTRACT_APPLICATION'
            : 'DRAW',
        'actionDocId': label,
        'actionDocNo': label,
        'actionDocItemId': 'item-$label',
      }, department),
    ],
    page: 1,
    size: 50,
    total: 1,
    totalPages: 1,
    capabilities: const OperationsWorkbenchCapabilities(),
  );
}

class _Gateway implements OperationsWorkbenchGateway {
  final responses = Queue<Completer<OperationsWorkbenchData>>();
  final departments = <OperationsWorkbenchDepartment>[];
  String nextLabel = 'PRIVATE-A';
  String? nextStage;
  @override
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    Map<String, String?> columnFilters = const {},
    String? issuedFrom,
    String? issuedTo,
    String? needFrom,
    String? needTo,
  }) async {
    departments.add(department);
    return responses.isEmpty
        ? _data(department, nextLabel, stageOverride: status ?? nextStage)
        : responses.removeFirst().future;
  }
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {};
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}
