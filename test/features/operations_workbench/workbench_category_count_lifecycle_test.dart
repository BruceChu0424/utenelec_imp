import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/pages/operations_workbench_page.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_decomposition_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../subcontract/fake_subcontract_draw_gateway.dart';

final _reader = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'a'),
);
final _permissions = StateProvider<Set<String>>(
  (_) => const {
    Perm.purchaseOrderView,
    Perm.subcontractOrderView,
    Perm.subcontractApplicationView,
  },
);
final _apiSource = StateProvider<_Api>((_) => _Api());

void main() {
  for (final subcontract in [false, true]) {
    final name = subcontract ? 'subcontract' : 'purchase';
    testWidgets(
      '$name keeps returned category counts across empty drafts and pending rows',
      (tester) async {
        final gateway = _Gateway();
        await _mount(tester, gateway, subcontract);
        await tester.pumpAndSettle();
        expect(_progressCounts(tester), (1, null));
        await _select(tester, '草稿');
        await tester.pumpAndSettle();
        expect(
          _progressCounts(tester),
          (1, null),
          reason:
              'an empty draft table does not clear the other business categories',
        );
        expect(find.text('RETURNED-1'), findsNothing);
        await _select(tester, subcontract ? '待处理' : '申请待分解');
        await tester.pumpAndSettle();
        expect(_progressCounts(tester), (1, null));
        expect(
          find.text('RETURNED-1'),
          findsNothing,
          reason:
              'retaining the overview must not retain rows of the previous category',
        );
        await _select(tester, '进行中');
        await tester.pumpAndSettle();
        expect(find.text('RETURNED-1'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$name cold draft entry fetches its overview with no draft status sentinel',
      (tester) async {
        final gateway = _Gateway();
        final old = Completer<OperationsWorkbenchData>();
        gateway.gates.add(old);
        await _mount(tester, gateway, subcontract);
        await tester.pump();
        await _select(tester, '草稿');
        await tester.pumpAndSettle();
        expect(
          gateway.queries.length,
          greaterThanOrEqualTo(2),
          reason:
              'the held initial request cannot be the draft category sole overview source',
        );
        expect(gateway.queries.last['status'], isNull);
        expect(gateway.queries.last['size'], 1);
        expect(_progressCounts(tester), (1, null));
        old.complete(_page(subcontract, 9, null));
        await tester.pumpAndSettle();
        expect(
          _progressCounts(tester),
          (1, null),
          reason: 'the old request cannot replace the fresh draft overview',
        );
        expect(find.text('RETURNED-9'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    for (final boundary in ['identity', 'permissions', 'snapshot']) {
      testWidgets(
        '$name $boundary invalidates counts while drafts stay open and rejects old overview',
        (tester) async {
          final gateway = _Gateway();
          final (container, _) = await _mount(tester, gateway, subcontract);
          await tester.pumpAndSettle();
          await _select(tester, '草稿');
          await tester.pumpAndSettle();
          expect(_progressCounts(tester), (1, null));
          final old = Completer<OperationsWorkbenchData>();
          gateway.gates.add(old);
          await tester.tap(find.byTooltip(subcontract ? '刷新委外任务' : '刷新'));
          await tester.pump();
          final fresh = Completer<OperationsWorkbenchData>();
          gateway.gates.add(fresh);
          if (boundary == 'identity') {
            container.read(_reader.notifier).state = const AuthenticatedScope(
              userId: 'b',
            );
          } else if (boundary == 'permissions') {
            container.read(_permissions.notifier).state = {
              ...container.read(_permissions),
              Perm.purchaseReceiptView,
            };
          } else {
            (container.read(sessionSnapshotProvider.notifier) as _Snapshots)
                .emit(2);
          }
          await tester.pump();
          expect(
            _progressCounts(tester),
            (null, null),
            reason:
                'previous authority counts are invalid even when the draft rows are empty',
          );
          fresh.complete(_page(subcontract, 2, null));
          await _pumpWithOlderRefreshPending(tester);
          expect(_progressCounts(tester), (2, null));
          expect(gateway.queries.last['status'], isNull);
          old.complete(_page(subcontract, 9, null));
          await tester.pumpAndSettle();
          expect(_progressCounts(tester), (2, null));
          expect(find.text('RETURNED-9'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      '$name draft keyword changes the server count scope while table filters do not',
      (tester) async {
        final gateway = _Gateway();
        await _mount(tester, gateway, subcontract);
        await tester.pumpAndSettle();
        await _select(tester, '草稿');
        await tester.pumpAndSettle();
        final search = Completer<OperationsWorkbenchData>();
        gateway.gates.add(search);
        _toolbar(tester).onSearchChanged!('needle');
        await tester.pump();
        expect(_progressCounts(tester), (null, null));
        expect(gateway.queries.last['keyword'], 'needle');
        expect(gateway.queries.last['status'], isNull);
        expect(gateway.queries.last['size'], 1);
        gateway.count = 2;
        search.complete(_page(subcontract, 2, null));
        await tester.pumpAndSettle();
        expect(_progressCounts(tester), (2, null));
        await _select(tester, '进行中');
        await tester.pumpAndSettle();
        final filtered = Completer<OperationsWorkbenchData>();
        gateway.gates.add(filtered);
        tester
            .widget<MasterDataTableView<OperationsWorkbenchTask>>(
              find.byType(MasterDataTableView<OperationsWorkbenchTask>),
            )
            .onFilterChanged('status', 'FINANCE_REJECTED');
        await tester.pump();
        expect(
          _progressCounts(tester),
          (2, null),
          reason:
              'status table facets filter rows rather than all-category counts',
        );
        expect(gateway.queries.last['filters'], {'status': 'FINANCE_REJECTED'});
        filtered.complete(_page(subcontract, 2, 'IN_PROGRESS'));
        await tester.pumpAndSettle();
        expect(_progressCounts(tester), (2, null));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$name default repository reader change clears counts and fences the old server response',
      (tester) async {
        final (container, _) = await _mount(
          tester,
          _Gateway(),
          subcontract,
          defaultRepository: true,
        );
        await tester.pumpAndSettle();
        expect(_progressCounts(tester), (1, null));
        await _select(tester, '草稿');
        await tester.pumpAndSettle();
        final oldApi = container.read(_apiSource);
        oldApi.gate = Completer<Map<String, dynamic>>();
        await tester.tap(find.byTooltip(subcontract ? '刷新委外任务' : '刷新'));
        await tester.pump();
        final nextApi = _Api(server: 'http://localhost:8087/api')
          ..gate = Completer<Map<String, dynamic>>();
        container.read(_apiSource.notifier).state = nextApi;
        await tester.pump();
        expect(_progressCounts(tester), (null, null));
        nextApi.gate!.complete(_jsonPage(2));
        await _pumpWithOlderRefreshPending(tester);
        expect(_progressCounts(tester), (2, null));
        oldApi.gate!.complete(_jsonPage(9));
        await tester.pumpAndSettle();
        expect(_progressCounts(tester), (2, null));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$name badge facts drive the actionable counts and fence the overview',
      (tester) async {
        Map<String, int> factsOf(int n) => {
          subcontract
                  ? BadgeFact.subcontractTaskRework
                  : BadgeFact.purchaseTaskRework:
              n,
          subcontract
                  ? BadgeFact.subcontractTaskShortDelivery
                  : BadgeFact.purchaseTaskWaitingOrder:
              0,
          subcontract
                  ? BadgeFact.subcontractTaskInProgress
                  : BadgeFact.purchaseTaskInProgress:
              n,
        };
        final gateway = _Gateway();
        final (_, badges) = await _mount(
          tester,
          gateway,
          subcontract,
          facts: factsOf(1),
        );
        await tester.pumpAndSettle();
        expect(_progressCounts(tester), (1, 1));
        // 概览翻到 9 也不能把浏览数伪装成任务红黄数(事实管道与概览独立)。
        final churn = Completer<OperationsWorkbenchData>();
        gateway.gates.add(churn);
        await tester.tap(find.byTooltip(subcontract ? '刷新委外任务' : '刷新'));
        await tester.pump();
        churn.complete(_page(subcontract, 9, null));
        await tester.pumpAndSettle();
        expect(_progressCounts(tester), (1, 1));
        // 下一轮徽章汇总把事实更新为 2, 分段随之走新事实。
        badges.emit(badgeSummaryFixture(facts: factsOf(2)));
        await tester.pumpAndSettle();
        expect(_progressCounts(tester), (2, 2));
        expect(tester.takeException(), isNull);
      },
    );
  }
}

// The superseded user-triggered refresh deliberately remains unresolved. Its
// shared action feedback keeps animating until the old future is completed.
Future<void> _pumpWithOlderRefreshPending(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

UtenFilterToolbar<dynamic> _toolbar(WidgetTester tester) => tester.widget(
  find.byWidgetPredicate(
    (w) =>
        w is UtenFilterToolbar &&
        w.segments.any((segment) => segment.label == '进行中'),
  ),
);
(int?, int?) _progressCounts(WidgetTester tester) {
  final segment = _toolbar(
    tester,
  ).segments.singleWhere((segment) => segment.label == '进行中');
  return (segment.count, segment.inProgressCount);
}

/// 浏览口径(空 facts)下: count = 概览 statusCounts 的中性浏览数,
/// inProgressCount = null —— ADR-184「无任务来源不把未知伪装成 0」。

Future<void> _select(WidgetTester tester, String label) async {
  if (tester.any(find.byType(NestedScrollView))) {
    tester
        .state<NestedScrollViewState>(find.byType(NestedScrollView).first)
        .outerController
        .jumpTo(0);
  }
  await tester.pump();
  await tester.tap(find.text(label).first);
  await tester.pump();
}

Future<(ProviderContainer, FixedBadgeSummaryNotifier)> _mount(
  WidgetTester tester,
  _Gateway gateway,
  bool subcontract, {
  bool defaultRepository = false,
  Map<String, int> facts = const {},
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => subcontract
            ? SubcontractDecompositionPage(
                repository: defaultRepository ? null : gateway,
                drawRepository: FakeSubcontractDrawGateway(),
              )
            : OperationsWorkbenchPage(
                department: OperationsWorkbenchDepartment.purchase,
                repository: defaultRepository ? null : gateway,
                draftCategoryBuilder:
                    (_, {required search, required externalHeader}) =>
                        Column(children: [externalHeader, const Text('暂无草稿')]),
              ),
      ),
    ],
  );
  addTearDown(router.dispose);
  // ADR-184 后分段红黄数来自徽章事实: 默认空 facts = 无任务来源, 分段回退
  // 中性浏览数(概览 statusCounts), 黄数恒 null —— 生命周期用例全部按浏览口径跑;
  // 事实驱动的口径由 badge facts 专测覆盖。
  final badges = FixedBadgeSummaryNotifier(badgeSummaryFixture(facts: facts));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        badgeSummaryProvider.overrideWith(() => badges),
        sharedPreferencesProvider.overrideWithValue(prefs),
        apiClientProvider.overrideWith((ref) => ref.watch(_apiSource)),
        apiBaseUrlProvider.overrideWithValue('http://localhost:8080/api'),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_reader)),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        sessionSnapshotProvider.overrideWith(_Snapshots.new),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  return (
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp))),
    badges,
  );
}

OperationsWorkbenchData _page(bool subcontract, int count, String? status) {
  final department = subcontract
      ? OperationsWorkbenchDepartment.subcontract
      : OperationsWorkbenchDepartment.purchase;
  return OperationsWorkbenchData(
    department: department,
    summary: OperationsWorkbenchSummary(
      totalTasks: count,
      overdueTasks: 0,
      openTasks: count,
      openQty: count,
      statusCounts: {
        'IN_PROGRESS': count,
        'FINANCE_REJECTED': count,
        'WAITING_ORDER': 0,
      },
    ),
    items: status == 'IN_PROGRESS'
        ? [
            OperationsWorkbenchTask.fromJson({
              'taskId': 'returned-$count',
              'goodsName': 'Part',
              'planNo': 'RETURNED-$count',
              'supplyRoute': subcontract ? 'SUBCONTRACT' : 'BUY',
              'taskStatus': 'FINANCE_REJECTED',
              'actionDocType': subcontract
                  ? 'SUBCONTRACT_ORDER'
                  : 'PURCHASE_ORDER',
              'actionDocId': 'returned-$count',
              'actionDocNo': 'RETURNED-$count',
              'openQty': count,
            }, department),
          ]
        : [],
    page: 1,
    size: 50,
    total: status == 'IN_PROGRESS' ? 1 : 0,
    totalPages: 1,
    capabilities: const OperationsWorkbenchCapabilities(),
  );
}

class _Gateway implements OperationsWorkbenchGateway {
  final gates = Queue<Completer<OperationsWorkbenchData>>();
  final queries = <Map<String, Object?>>[];
  int count = 1;
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
    queries.add({
      'status': status,
      'size': size,
      'keyword': keyword,
      'exception': exception,
      'filters': Map.of(columnFilters),
    });
    return gates.isEmpty
        ? _page(
            department == OperationsWorkbenchDepartment.subcontract,
            count,
            status,
          )
        : gates.removeFirst().future;
  }
}

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot(generation: 1);
  void emit(int generation) =>
      state = AsyncData(SessionSnapshot(generation: generation));
}

class _Api extends ApiClient {
  _Api({String server = 'http://localhost:8080/api'})
    : super(Dio(BaseOptions(baseUrl: server)));
  Completer<Map<String, dynamic>>? gate;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => path.startsWith('/operations/workbench/')
      ? (gate?.future ?? _jsonPage(1))
      : {'items': <Object?>[], 'page': 1, 'total': 0, 'totalPages': 1};
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

Map<String, dynamic> _jsonPage(int count) => {
  'items': <Object?>[],
  'page': 1,
  'size': 1,
  'total': 0,
  'totalPages': 1,
  'summary': {
    'totalTasks': 0,
    'overdueTasks': 0,
    'openTasks': count,
    'openQty': count,
    'statusCounts': {
      'IN_PROGRESS': count,
      'FINANCE_REJECTED': count,
      'WAITING_ORDER': 0,
    },
  },
  'capabilities': <String, Object?>{},
};
