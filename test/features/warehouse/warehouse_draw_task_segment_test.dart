// 生产领料任务中心 · 待领任务分段：子分类徽章 / 批量出库权限门控 / 跨页勾选 /
// 重放与单号错误提示契约（2026-09-10）。
import 'package:dio/dio.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/warehouse/pages/production_draw_batch_issue_page.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_error.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_draw_task.dart';
import 'package:uten_imp/features/warehouse/repositories/production_draw_task_repository.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_draw_task_segment.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

class _FakeRepository extends ProductionDrawTaskRepository {
  _FakeRepository() : super(ApiClient(Dio()));

  final Map<int, List<WarehouseDrawTask>> pages = {};
  Map<String, int> counts = const {};
  Object? countsError;
  final batchKeys = <String>[];
  late final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Consumer(
          builder: (context, ref, _) => Scaffold(
            body: WarehouseListScope(
              scope: ref.watch(_scopeProvider),
              child: WarehouseDrawTaskSegment(
                refreshTick: ref.watch(_refreshTickProvider),
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: RouteName.warehouseProductionDrawBatchIssue,
        builder: (_, state) => ProductionDrawBatchIssuePage(
          documentIds: (state.uri.queryParameters['documentIds'] ?? '').split(
            ',',
          ),
        ),
      ),
    ],
  );
  List<String>? batchDocIds;
  String? batchReason;
  WarehouseDrawBatchIssueResult Function(List<String> docIds)? onBatch;

  int get total => pages.values.fold(0, (sum, items) => sum + items.length);

  @override
  Future<Map<String, int>> statusBreakdown({
    WarehouseTaskScope scope = const WarehouseTaskScope.all(),
  }) async {
    final error = countsError;
    if (error != null) throw error;
    return counts;
  }

  @override
  Future<PagedResult<WarehouseDrawTask>> tasks({
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? sort,
    bool ascending = true,
    WarehouseTaskScope scope = const WarehouseTaskScope.all(),
  }) async {
    requests.add((page: page, sort: sort, ascending: ascending));
    scopes.add(scope);
    return _page(page, size);
  }

  /// 每次列表请求的页码与排序(表头排序用例断言服务端排序参数)。
  final requests = <({int page, String? sort, bool ascending})>[];

  /// 每次列表请求带的仓库范围(ADR-115)。
  final scopes = <WarehouseTaskScope>[];

  PagedResult<WarehouseDrawTask> _page(int page, int size) => PagedResult(
    items: pages[page] ?? const [],
    page: page,
    size: size,
    total: total,
    totalPages: pages.isEmpty ? 1 : pages.length,
  );

  @override
  Future<WarehouseDrawBatchIssueResult> issueFullBatch({
    required String idempotencyKey,
    required List<String> docIds,
    String? reason,
  }) async {
    batchKeys.add(idempotencyKey);
    batchDocIds = List.of(docIds);
    batchReason = reason;
    final handler = onBatch;
    if (handler != null) return handler(docIds);
    return WarehouseDrawBatchIssueResult(
      issuedCount: docIds.length,
      skippedCount: 0,
      replayedCount: 0,
      replayed: false,
      issuedDocNos: const [],
    );
  }
}

WarehouseDrawTask _task(
  String docId, {
  String status = 'READY_TO_PICK',
  String docStatus = '0',
}) => WarehouseDrawTask(
  taskId: 'task-$docId',
  planNo: 'SC-$docId',
  warehouseName: '主仓',
  goodsCode: 'G-$docId',
  goodsName: '货品$docId',
  spec: '',
  colorName: '',
  unitName: '个',
  openQty: 5,
  taskStatus: status,
  needDate: '2026-09-20',
  expectedDate: null,
  exceptionCode: null,
  actionDocId: docId,
  actionDocType: 'DRAW',
  actionDocNo: 'LL-$docId',
  actionDocStatus: docStatus,
);

late SharedPreferences _prefs;

final _refreshTickProvider = Provider<int>((ref) => 0);

/// 任务中心骨架往下传的仓库范围(ADR-115)；默认全部仓库。
final _scopeProvider = Provider<WarehouseTaskScope>(
  (ref) => const WarehouseTaskScope.all(),
);

class _FakeNames extends MasterNameService {
  _FakeNames() : super(ApiClient(Dio()));
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {}
  @override
  String goods(String? id) => '货品$id';
  @override
  String warehouse(String? id) => '主仓';
}

class _FakeStockRepository extends StockDocRepository {
  _FakeStockRepository(this.tasks) : super(ApiClient(Dio()), StockDocType.draw);
  final _FakeRepository tasks;
  @override
  Future<StockDocDetail> detail(String id) async {
    final task = tasks.pages.values
        .expand((rows) => rows)
        .firstWhere((row) => row.actionDocId == id);
    return StockDocDetail(
      id: id,
      docType: 'DRAW',
      billNo: task.actionDocNo,
      warehouseId: 'warehouse',
      departmentId: 'workshop',
      status: int.parse(task.actionDocStatus!),
      planNo: task.planNo,
      issueStatus: 0,
      items: [StockDocItem(id: 'line-$id', goodsId: id, qty: 5, issuedQty: 0)],
    );
  }
}

Widget _app(
  _FakeRepository repo,
  Set<String> permissions, {
  int refreshTick = 0,
  WarehouseTaskScope scope = const WarehouseTaskScope.all(),
}) => ProviderScope(
  overrides: [
    _scopeProvider.overrideWithValue(scope),
    sharedPreferencesProvider.overrideWithValue(_prefs),
    productionDrawTaskRepositoryProvider.overrideWithValue(repo),
    stockDocRepositoryProvider(
      StockDocType.draw,
    ).overrideWithValue(_FakeStockRepository(repo)),
    masterNameServiceProvider.overrideWithValue(_FakeNames()),
    currentPermissionsProvider.overrideWithValue(permissions),
    isSuperAdminProvider.overrideWithValue(false),
    _refreshTickProvider.overrideWithValue(refreshTick),
  ],
  child: MaterialApp.router(
    routerConfig: repo.router,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    builder: (context, child) => Stack(
      children: [
        child!,
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: AppNotificationHost(useSafeArea: false),
        ),
      ],
    ),
  ),
);

Future<void> _pump(
  WidgetTester tester,
  _FakeRepository repo,
  Set<String> permissions, {
  int refreshTick = 0,
  WarehouseTaskScope scope = const WarehouseTaskScope.all(),
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    _app(repo, permissions, refreshTick: refreshTick, scope: scope),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

const _issuer = {Perm.stockDocView, Perm.stockDocIssue};
const _approverIssuer = {
  Perm.stockDocView,
  Perm.stockDocIssue,
  Perm.stockDocApprove,
};

Finder _segments() => find.byKey(const Key('warehouse-draw-task-status'));
Finder _batchButton() => find.byKey(const Key('warehouse-draw-batch-issue'));

/// 表头三态全选在第 0 个，数据行勾选框按行序其后。
Finder _rowCheckbox(int rowIndex) => find.byType(Checkbox).at(rowIndex + 1);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  // ADR-115：任务中心选「我的仓库」时，待领任务列表按该范围请求；骨架外默认全部仓库。
  testWidgets('pending tasks are requested within the task-center scope', (
    tester,
  ) async {
    final repo = _FakeRepository()..pages[1] = [_task('d1')];
    await _pump(tester, repo, _issuer, scope: const WarehouseTaskScope.mine());
    expect(repo.scopes, isNotEmpty);
    expect(repo.scopes.last, const WarehouseTaskScope.mine());

    final unscoped = _FakeRepository()..pages[1] = [_task('d2')];
    await _pump(tester, unscoped, _issuer);
    expect(unscoped.scopes.last, const WarehouseTaskScope.all());
  });

  // 2026-09-24 用户口径「生产计划那里表头加个排序，能够快速排序」：表头排序交给服务端
  // 在整个结果集上排(不是只排当前页)，换排序回第 1 页；取消排序回服务端默认顺序。
  testWidgets('plan header sorts on the server and resets to page 1', (
    tester,
  ) async {
    final repo = _FakeRepository()
      ..pages[1] = [_task('d1'), _task('d2')]
      ..pages[2] = [_task('d3')];
    await _pump(tester, repo, _issuer);
    expect(repo.requests.last.sort, isNull);

    await tester.tap(find.text('生产计划'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从大到小'));
    await tester.pumpAndSettle();
    expect(repo.requests.last, (page: 1, sort: 'planNo', ascending: false));

    await tester.tap(find.text('领料单号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从小到大'));
    await tester.pumpAndSettle();
    expect(repo.requests.last, (page: 1, sort: 'docNo', ascending: true));

    await tester.tap(find.text('待领数量'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从大到小'));
    await tester.pumpAndSettle();
    expect(repo.requests.last, (page: 1, sort: 'openQty', ascending: false));
  });

  // 计数形态（docs/00-项目准则/14-徽章与计数口径.md）：「待完成」是这批活的总量段
  // → 红徽章；它的两个细分切片（待备料/待领取、部分领取）走中性括号，
  // 同一批活不在一行里红两遍。
  testWidgets(
    'pending segment covers all unfinished work without duplicate categories',
    (tester) async {
      final repo = _FakeRepository()
        ..pages[1] = [_task('a'), _task('b'), _task('c', status: 'PARTIAL')]
        ..counts = const {'OPEN_ANY': 3, 'READY_TO_PICK': 2, 'PARTIAL': 1};
      await _pump(tester, repo, _approverIssuer);

      // 总量段：红徽章，数字不带括号。
      expect(
        find.descendant(of: _segments(), matching: find.text('3')),
        findsOneWidget,
        reason: '「待完成」总量挂红徽章',
      );
      expect(
        find.descendant(
          of: _segments(),
          matching: find.byType(UtenNotificationBadge),
        ),
        findsOneWidget,
        reason: '整条子分类行只有一个红徽章',
      );
      expect(
        find.descendant(of: _segments(), matching: find.text('待备料 / 待领取')),
        findsNothing,
      );
      expect(find.text('部分领取'), findsOneWidget, reason: '仅表格行状态显示部分领取');
      expect(
        find.descendant(of: _segments(), matching: find.text('部分领取')),
        findsNothing,
      );
      expect(
        find.descendant(of: _segments(), matching: find.text('(2)')),
        findsNothing,
      );
    },
  );

  testWidgets('breakdown failure clears badges instead of keeping stale ones', (
    tester,
  ) async {
    final repo = _FakeRepository()
      ..pages[1] = [_task('a')]
      ..counts = const {'OPEN_ANY': 3, 'READY_TO_PICK': 2, 'PARTIAL': 1};
    await _pump(tester, repo, _approverIssuer);
    expect(
      find.descendant(of: _segments(), matching: find.text('3')),
      findsOneWidget,
    );

    repo.countsError = ApiException('NOT_FOUND', '资源不存在');
    await tester.pumpWidget(_app(repo, _approverIssuer, refreshTick: 1));
    await tester.pumpAndSettle();

    for (final count in const ['3', '2', '1']) {
      expect(
        find.descendant(of: _segments(), matching: find.text(count)),
        findsNothing,
        reason: '计数端点失败不能留旧徽章',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('batch issue button is gated by stock_doc:issue', (tester) async {
    final repo = _FakeRepository()..pages[1] = [_task('a')];
    await _pump(tester, repo, const {Perm.stockDocView});
    expect(_batchButton(), findsNothing);

    await _pump(tester, repo, _issuer);
    expect(_batchButton(), findsOneWidget);
  });

  testWidgets(
    'draft selection without approve permission is blocked with a hint',
    (tester) async {
      // 默认 docStatus='0'=草稿。
      final repo = _FakeRepository()..pages[1] = [_task('a')];
      await _pump(tester, repo, _issuer);

      await tester.tap(_rowCheckbox(0));
      await tester.pumpAndSettle();
      await tester.tap(_batchButton());
      await tester.pumpAndSettle();

      expect(find.textContaining('出库即审核'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(repo.batchDocIds, isNull);
    },
  );

  testWidgets(
    'approved documents can be batch issued without approve permission',
    (tester) async {
      final repo = _FakeRepository()..pages[1] = [_task('a', docStatus: '1')];
      await _pump(tester, repo, _issuer);

      await tester.tap(_rowCheckbox(0));
      await tester.pumpAndSettle();
      await tester.tap(_batchButton());
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.byKey(const Key('production-draw-detail-table')),
        findsOneWidget,
      );
      expect(repo.batchDocIds, isNull, reason: '进入详情只读取，不触发实际出库');
      await tester.tap(find.byKey(const Key('warehouse-draw-batch-confirm')));
      await tester.pumpAndSettle();

      expect(repo.batchDocIds, ['a']);
      expect(repo.batchReason, isNull);
      expect(find.textContaining('已出库 1 张领料单'), findsOneWidget);
    },
  );

  testWidgets(
    'cross-page selection sends every selected id with the shared remark and reports replay',
    (tester) async {
      final repo = _FakeRepository()
        ..pages[1] = [_task('a'), _task('b')]
        ..pages[2] = [_task('c')]
        ..onBatch = (docIds) => WarehouseDrawBatchIssueResult(
          issuedCount: 0,
          skippedCount: 0,
          replayedCount: docIds.length,
          replayed: true,
          issuedDocNos: const [],
        );
      await _pump(tester, repo, _approverIssuer);

      // 第 1 页表头全选，翻到第 2 页再勾一张：三张跨页保留。
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      await tester.tap(_rowCheckbox(0));
      await tester.pumpAndSettle();
      expect(find.text('已选 3 项'), findsOneWidget);

      await tester.tap(_batchButton());
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.byKey(const Key('production-draw-detail-table')),
        findsOneWidget,
      );
      expect(repo.batchDocIds, isNull, reason: '进入详情只读取，不触发实际出库');
      for (final bill in ['LL-a', 'LL-b', 'LL-c']) {
        expect(find.text(bill), findsOneWidget);
      }
      await tester.enterText(
        find.byKey(const Key('warehouse-draw-batch-remark')),
        '夜班统一发料',
      );
      await tester.tap(find.byKey(const Key('warehouse-draw-batch-confirm')));
      await tester.pumpAndSettle();

      expect(repo.batchDocIds, unorderedEquals(['a', 'b', 'c']));
      expect(repo.batchReason, '夜班统一发料');
      expect(find.textContaining('本批此前已完成'), findsOneWidget);
    },
  );

  testWidgets('server error with the bill number reaches the operator', (
    tester,
  ) async {
    final repo = _FakeRepository()
      ..pages[1] = [_task('a', docStatus: '1')]
      ..onBatch = (_) =>
          throw ApiException('CONFLICT', '领料单 LL-a：本仓剩余可领数量不足：当前 0，本次出库 5');
    await _pump(tester, repo, _issuer);

    await tester.tap(_rowCheckbox(0));
    await tester.pumpAndSettle();
    await tester.tap(_batchButton());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-draw-batch-confirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('领料单 LL-a：本仓剩余可领数量不足'), findsOneWidget);
    repo.onBatch = null;
    await tester.tap(find.byKey(const Key('warehouse-draw-batch-confirm')));
    await tester.pumpAndSettle();
    expect(repo.batchKeys, hasLength(2));
    expect(repo.batchKeys.first, repo.batchKeys.last, reason: '同样明细和备注重试复用幂等键');
  });

  testWidgets('422 field message replaces the generic validation text', (
    tester,
  ) async {
    final repo = _FakeRepository()
      ..pages[1] = [_task('a', docStatus: '1')]
      ..onBatch = (_) => throw ApiException(
        'VALIDATION_FAILED',
        '参数校验失败',
        fieldErrors: const [
          ApiFieldError(field: 'docIds', message: '一次最多批量出库 50 张领料单'),
        ],
      );
    await _pump(tester, repo, _issuer);

    await tester.tap(_rowCheckbox(0));
    await tester.pumpAndSettle();
    await tester.tap(_batchButton());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-draw-batch-confirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('一次最多批量出库 50 张领料单'), findsOneWidget);
    expect(find.text('参数校验失败'), findsNothing);
  });

  testWidgets('reload prunes selected documents that are no longer open', (
    tester,
  ) async {
    final repo = _FakeRepository()
      ..pages[1] = [_task('a', docStatus: '1'), _task('b', docStatus: '1')];
    await _pump(tester, repo, _issuer);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);

    // 刷新后 a 已领完（DONE）：勾选自动剔除，只剩 b。
    repo.pages[1] = [
      _task('a', docStatus: '1', status: 'DONE'),
      _task('b', docStatus: '1'),
    ];
    await tester.pumpWidget(_app(repo, _issuer, refreshTick: 1));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);

    await tester.tap(_batchButton());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-draw-batch-confirm')));
    await tester.pumpAndSettle();
    expect(repo.batchDocIds, ['b']);
  });

  for (final viewport in const [Size(375, 812), Size(844, 390)]) {
    testWidgets(
      'batch detail stays operable at $viewport without issuing on entry',
      (tester) async {
        final repo = _FakeRepository()..pages[1] = [_task('a')];
        await _pump(tester, repo, _approverIssuer);
        await tester.tap(_rowCheckbox(0));
        await tester.pumpAndSettle();
        await tester.tap(_batchButton());
        await tester.pumpAndSettle();
        tester.view.physicalSize = viewport;
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('production-draw-detail-table')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('warehouse-draw-batch-confirm')),
          findsOneWidget,
        );
        expect(repo.batchDocIds, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
