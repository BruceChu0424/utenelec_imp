import '../../support/table_read_status.dart';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/nav_helpers.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/router/route_transition_tracker.dart';
import 'package:uten_imp/core/theme/uten_page_transitions.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/pages/operations_workbench_page.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_decomposition_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart'
    show CompleteReadBatchPlan;
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../helpers/workbench_read_fixture.dart';
import '../subcontract/fake_subcontract_draw_gateway.dart';

enum _ReturnKind { quickView, staleView, saved, refreshFails }

void main() {
  for (final subcontract in [false, true]) {
    for (final kind in _ReturnKind.values) {
      testWidgets(
        '${subcontract ? 'subcontract' : 'purchase'} ${kind.name} return retains the actual workbench and its table',
        (tester) async {
          final fixture = await _mount(tester, subcontract);
          final gateway = fixture.gateway;
          await tester.tap(find.text('进行中'));
          await tester.pumpAndSettle();
          expect(find.text('PLAN-A'), findsOneWidget);

          final workbenchFinder = find.byType(
            subcontract
                ? SubcontractDecompositionPage
                : OperationsWorkbenchPage,
            skipOffstage: false,
          );
          final workbenchState = tester.state(workbenchFinder);
          final tableFinder = find.byType(
            MasterDataTableView<OperationsWorkbenchTask>,
            skipOffstage: false,
          );
          final tableState = tester.state(tableFinder);
          final initialPaginationRevision = tester
              .widget<MasterDataTableView<OperationsWorkbenchTask>>(tableFinder)
              .paginationRevision;
          final initialLoads = gateway.loads;

          // Exercise the real table's double-click handler and goFrom helper.
          await tester.tap(find.text('PLAN-A'));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.tap(find.text('PLAN-A'));
          await tester.pumpAndSettle();
          expect(find.text('Order detail'), findsOneWidget);
          expect(
            fixture.container.read(pageResumeProvider).location,
            contains('/orders/order-a'),
          );
          expect(workbenchState.mounted, isTrue);
          expect(tester.state(workbenchFinder), same(workbenchState));
          expect(gateway.loads, initialLoads);

          if (kind == _ReturnKind.staleView) {
            await tester.pump(const Duration(seconds: 31));
          } else if (kind == _ReturnKind.saved ||
              kind == _ReturnKind.refreshFails) {
            fixture.container.read(dataWriteRevisionProvider.notifier).state++;
            await tester.pump();
          }
          final delayed = Completer<OperationsWorkbenchData>();
          gateway.next = delayed;

          await tester.tap(find.text('Return to tasks'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump();

          expect(find.text('PLAN-A'), findsOneWidget);
          expect(tester.state(workbenchFinder), same(workbenchState));
          expect(tester.state(tableFinder), same(tableState));
          {
            expect(gateway.loads, initialLoads + 1);
            final table = tester
                .widget<MasterDataTableView<OperationsWorkbenchTask>>(
                  tableFinder,
                );
            expect(
              table.isRefreshing,
              isTrue,
              reason: 'background validation must keep accepted rows mounted',
            );
            expect(table.isLoading, isFalse);
            if (kind == _ReturnKind.refreshFails) {
              delayed.completeError(
                ApiException(
                  'NETWORK_ERROR',
                  'NETWORK-FAILED',
                  httpStatus: 503,
                ),
              );
              await tester.pumpAndSettle();
              expect(find.text('PLAN-A'), findsOneWidget);
              expect(tester.state(tableFinder), same(tableState));
              expect(find.text('更新失败，显示上次数据'), findsOneWidget);
              expect(
                tester
                    .widget<MasterDataTableView<OperationsWorkbenchTask>>(
                      tableFinder,
                    )
                    .refreshError,
                'NETWORK-FAILED',
              );
              final retry = Completer<OperationsWorkbenchData>();
              gateway.next = retry;
              await tester.tap(
                find.descendant(
                  of: find.byKey(const ValueKey('master-table-refresh-error')),
                  matching: find.text('重试'),
                ),
              );
              await tester.pump();
              expect(gateway.loads, initialLoads + 2);
              expect(find.text('PLAN-A'), findsOneWidget);
              expect(tester.state(tableFinder), same(tableState));
              retry.complete(_data(subcontract, 'PLAN-B'));
            } else if (kind == _ReturnKind.quickView) {
              // Another user creates a task while this client only reads the
              // detail. No local write revision advances, even on a fast return.
              delayed.complete(
                _data(subcontract, 'PLAN-A', includeCreatedRow: true),
              );
            } else {
              delayed.complete(_data(subcontract, 'PLAN-B'));
            }
            await tester.pumpAndSettle();
            if (kind == _ReturnKind.quickView) {
              expect(find.text('NEW-RECORD'), findsOneWidget);
              expect(find.text('PLAN-A'), findsOneWidget);
            } else {
              expect(find.text('PLAN-B'), findsOneWidget);
              expect(find.text('PLAN-A'), findsNothing);
            }
            expect(tester.state(tableFinder), same(tableState));
            expect(
              tester
                  .widget<MasterDataTableView<OperationsWorkbenchTask>>(
                    tableFinder,
                  )
                  .paginationRevision,
              initialPaginationRevision,
              reason: 'a background response must not reset the loaded window',
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
      );
    }
  }

  for (final subcontract in [false, true]) {
    for (final forbidden in [false, true]) {
      testWidgets(
        '${subcontract ? 'subcontract' : 'purchase'} ${forbidden ? 'denied' : 'successful'} multi-page revalidation is atomic',
        (tester) async {
          final fixture = await _mount(tester, subcontract);
          await tester.tap(find.text('进行中'));
          await tester.pumpAndSettle();
          final tableFinder = find.byType(
            MasterDataTableView<OperationsWorkbenchTask>,
            skipOffstage: false,
          );
          final tableState = tester.state(tableFinder);
          expect(
            tester
                .widget<MasterDataTableView<OperationsWorkbenchTask>>(
                  tableFinder,
                )
                .onPageChange,
            isNull,
          );
          await tester.tap(find.text('PLAN-A'));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.tap(find.text('PLAN-A'));
          await tester.pumpAndSettle();
          // One complete read of 101 rows in the shared progressive ladder:
          // (1,50) rows 1-50, (2,50) rows 51-100, (2,100) row 101. The first
          // batch is held by [first]; every continuation batch is served from
          // the one held response [rest], all with the same server read proof.
          final batches = _progressiveBatches(101);
          final first = Completer<OperationsWorkbenchData>();
          final rest = Completer<OperationsWorkbenchData>();
          fixture.gateway.pageResponses.addAll({
            batches.first: first,
            for (final batch in batches.skip(1)) batch: rest,
          });
          final initialLoads = fixture.gateway.loads;
          final initialRequests = fixture.gateway.requests.length;
          await tester.tap(find.text('Return to tasks'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump();
          expect(fixture.gateway.loads, initialLoads + 1);
          final complete = _multiBatchData(subcontract);
          first.complete(complete);
          await tester.pump();
          await tester.pump();
          for (
            var frame = 0;
            frame < 100 &&
                fixture.gateway.loads < initialLoads + batches.length;
            frame++
          ) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          // After the validated first batch the remaining batches of the same
          // snapshot are requested at once (two concurrent continuations).
          expect(fixture.gateway.loads, initialLoads + batches.length);
          expect(fixture.gateway.requests.skip(initialRequests), batches);
          expect(find.text('FIRST-NEW'), findsNothing);
          expect(find.text('PLAN-A'), findsOneWidget);
          if (forbidden) {
            rest.completeError(
              ApiException('FORBIDDEN', 'ACCESS-REMOVED', httpStatus: 403),
            );
          } else {
            rest.complete(complete);
          }
          await tester.pumpAndSettle();
          if (forbidden) {
            expect(
              find.text('PLAN-A'),
              findsNothing,
              reason: 'denial of any page retires every cached private row',
            );
            expect(find.text('FIRST-NEW'), findsNothing);
            await expectTableReadFailureDetails(tester, 'ACCESS-REMOVED');
            expect(tableState.mounted, isTrue);
            final table = tester
                .widget<MasterDataTableView<OperationsWorkbenchTask>>(
                  tableFinder,
                );
            expect(table.items, isEmpty);
            expect(table.facets.values.expand((buckets) => buckets), isEmpty);
            expect(table.selectedIds, isEmpty);
          } else {
            expect(find.text('FIRST-NEW'), findsOneWidget);
            final table = tester
                .widget<MasterDataTableView<OperationsWorkbenchTask>>(
                  tableFinder,
                );
            // Row 101 lives below the virtualized viewport; the accepted
            // result must hold it, in server order, exactly once.
            expect(table.items, hasLength(101));
            expect(table.items.first.planNo, 'FIRST-NEW');
            expect(table.items.last.planNo, 'SECOND-NEW');
            expect(find.text('PLAN-A'), findsNothing);
            expect(tester.state(tableFinder), same(tableState));
            expect(table.refreshedPages.keys, [1]);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
      );
    }
  }
}

Future<({GoRouter router, ProviderContainer container, _Gateway gateway})>
_mount(WidgetTester tester, bool subcontract) async {
  RouteTransitionTracker.instance.reset();
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues(const {});
  final prefs = await SharedPreferences.getInstance();
  final gateway = _Gateway(subcontract);
  final drawGateway = FakeSubcontractDrawGateway();
  final listLocation = subcontract
      ? RouteName.operationsSubcontractWorkbench
      : RouteName.operationsPurchaseWorkbench;
  final detailLocation = subcontract
      ? '/subcontract/orders/order-a'
      : '/purchase/orders/order-a';
  final router = GoRouter(
    initialLocation: listLocation,
    routes: [
      GoRoute(
        path: listLocation,
        builder: (_, _) => subcontract
            ? SubcontractDecompositionPage(
                repository: gateway,
                drawRepository: drawGateway,
              )
            : OperationsWorkbenchPage(
                department: OperationsWorkbenchDepartment.purchase,
                repository: gateway,
              ),
      ),
      GoRoute(
        path: detailLocation,
        builder: (context, _) => Scaffold(
          body: Column(
            children: [
              const Text('Order detail'),
              TextButton(
                onPressed: () => backTo(context, defaultPath: listLocation),
                child: const Text('Return to tasks'),
              ),
            ],
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(_Api()),
      apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
      sharedPreferencesProvider.overrideWithValue(prefs),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'reader-a'),
      ),
      sessionSnapshotProvider.overrideWith(_Snapshots.new),
      currentPermissionsProvider.overrideWithValue(const {
        Perm.purchaseOrderView,
        Perm.subcontractApplicationView,
        Perm.subcontractOrderView,
      }),
      fixedBadgeSummaryOverride(),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(
    attachPageResume(router, container.read(pageResumeProvider.notifier)),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: ThemeData(pageTransitionsTheme: utenPageTransitionsTheme()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (router: router, container: container, gateway: gateway);
}

OperationsWorkbenchData _data(
  bool subcontract,
  String label, {
  bool includeCreatedRow = false,
  int page = 1,
  int totalPages = 1,
  String taskId = 'task-a',
}) {
  final department = subcontract
      ? OperationsWorkbenchDepartment.subcontract
      : OperationsWorkbenchDepartment.purchase;
  return OperationsWorkbenchData(
    department: department,
    summary: OperationsWorkbenchSummary(
      totalTasks: includeCreatedRow || totalPages > 1 ? 2 : 1,
      overdueTasks: 0,
      openTasks: includeCreatedRow || totalPages > 1 ? 2 : 1,
      openQty: includeCreatedRow || totalPages > 1 ? 8 : 4,
      statusCounts: {
        'IN_PROGRESS': includeCreatedRow || totalPages > 1 ? 2 : 1,
      },
    ),
    items: [
      OperationsWorkbenchTask.fromJson({
        'taskId': taskId,
        'planNo': label,
        'goodsName': 'Part',
        'requiredQty': 4,
        'openQty': 4,
        'taskStatus': 'FINANCE_APPROVED',
        'supplyRoute': subcontract ? 'SUBCONTRACT' : 'PURCHASE',
        'actionDocType': subcontract ? 'SUBCONTRACT_ORDER' : 'PURCHASE_ORDER',
        'actionDocId': 'order-a',
        'actionDocNo': 'ORDER-A',
        'actionDocCanView': true,
        'actionDocStatus': '1',
      }, department),
      if (includeCreatedRow)
        OperationsWorkbenchTask.fromJson({
          'taskId': 'task-created-by-another-user',
          'planNo': 'NEW-RECORD',
          'goodsName': 'New part',
          'requiredQty': 4,
          'openQty': 4,
          'taskStatus': 'FINANCE_APPROVED',
          'supplyRoute': subcontract ? 'SUBCONTRACT' : 'PURCHASE',
          'actionDocType': subcontract ? 'SUBCONTRACT_ORDER' : 'PURCHASE_ORDER',
          'actionDocId': 'order-created-by-another-user',
          'actionDocNo': 'ORDER-NEW',
          'actionDocCanView': true,
          'actionDocStatus': '1',
        }, department),
    ],
    page: page,
    size: totalPages > 1 ? 1 : 50,
    total: includeCreatedRow || totalPages > 1 ? 2 : 1,
    totalPages: totalPages,
    capabilities: const OperationsWorkbenchCapabilities(),
  );
}

class _Gateway implements OperationsWorkbenchGateway {
  _Gateway(this.subcontract);

  final bool subcontract;
  int loads = 0;
  Completer<OperationsWorkbenchData>? next;
  // Held responses keyed by the exact (page, size) batch: the progressive
  // ladder requests page 2 more than once with different sizes.
  final pageResponses = <(int, int), Completer<OperationsWorkbenchData>>{};
  final requests = <(int, int)>[];

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
    loads++;
    requests.add((page, size));
    final pending = next ?? pageResponses.remove((page, size));
    next = null;
    return pending == null
        ? workbenchPageSlice(_data(subcontract, 'PLAN-A'), page, size)
        : pending.future.then((value) => workbenchPageSlice(value, page, size));
  }
}

/// The (page, size) requests of one complete read under the shared
/// progressive plan: 50 → 50 → 100 → 200 …, each batch at its exact offset.
List<(int, int)> _progressiveBatches(int total) {
  const plan = CompleteReadBatchPlan.progressive;
  final batches = <(int, int)>[];
  var offset = 0;
  do {
    final size = plan.sizeAt(offset);
    batches.add((offset ~/ size + 1, size));
    offset += size;
  } while (offset < total);
  return batches;
}

/// One complete-read result of 101 rows. The gateway's slice serves it in the
/// progressive ladder: (1,50) rows 1-50, (2,50) rows 51-100, (2,100) row 101.
OperationsWorkbenchData _multiBatchData(bool subcontract) {
  final department = subcontract
      ? OperationsWorkbenchDepartment.subcontract
      : OperationsWorkbenchDepartment.purchase;
  return OperationsWorkbenchData(
    department: department,
    summary: const OperationsWorkbenchSummary(
      totalTasks: 101,
      overdueTasks: 0,
      openTasks: 101,
      openQty: 404,
      statusCounts: {'IN_PROGRESS': 101},
    ),
    items: [
      for (var i = 1; i <= 101; i++)
        OperationsWorkbenchTask.fromJson({
          'taskId': 'task-$i',
          'planNo': i == 1 ? 'FIRST-NEW' : (i == 101 ? 'SECOND-NEW' : 'B-$i'),
          'goodsName': 'Part $i',
          'requiredQty': 4,
          'openQty': 4,
          'taskStatus': 'FINANCE_APPROVED',
          'supplyRoute': subcontract ? 'SUBCONTRACT' : 'PURCHASE',
          'actionDocType': subcontract ? 'SUBCONTRACT_ORDER' : 'PURCHASE_ORDER',
          'actionDocId': 'order-$i',
          'actionDocNo': 'ORDER-$i',
          'actionDocCanView': true,
          'actionDocStatus': '1',
        }, department),
    ],
    page: 1,
    size: 100,
    total: 101,
    totalPages: 2,
    capabilities: const OperationsWorkbenchCapabilities(),
  );
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

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => null;
}
