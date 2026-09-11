// 生产领料任务中心 · 待领任务分段：子分类徽章 / 批量出库权限门控 / 跨页勾选 /
// 重放与单号错误提示契约（2026-09-10）。
import 'package:dio/dio.dart';
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

class _FakeRepository extends ProductionDrawTaskRepository {
  _FakeRepository() : super(ApiClient(Dio()));

  final Map<int, List<WarehouseDrawTask>> pages = {};
  Map<String, int> counts = const {};
  Object? countsError;
  List<String>? batchDocIds;
  String? batchReason;
  WarehouseDrawBatchIssueResult Function(List<String> docIds)? onBatch;

  int get total => pages.values.fold(0, (sum, items) => sum + items.length);

  @override
  Future<int> pendingCount() async => total;

  @override
  Future<Map<String, int>> statusBreakdown() async {
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
  }) async => PagedResult(
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

Widget _app(
  _FakeRepository repo,
  Set<String> permissions, {
  int refreshTick = 0,
}) => ProviderScope(
  overrides: [
    sharedPreferencesProvider.overrideWithValue(_prefs),
    productionDrawTaskRepositoryProvider.overrideWithValue(repo),
    currentPermissionsProvider.overrideWithValue(permissions),
    isSuperAdminProvider.overrideWithValue(false),
  ],
  child: MaterialApp(
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
    home: Scaffold(body: WarehouseDrawTaskSegment(refreshTick: refreshTick)),
  ),
);

Future<void> _pump(
  WidgetTester tester,
  _FakeRepository repo,
  Set<String> permissions, {
  int refreshTick = 0,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(_app(repo, permissions, refreshTick: refreshTick));
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

  // 计数形态（docs/00-项目准则/14-徽章与计数口径.md）：「待完成」是这批活的总量段
  // → 红徽章；它的两个细分切片（待备料/待领取、部分领取）走中性括号，
  // 同一批活不在一行里红两遍。
  testWidgets('sub-segment counts render the server breakdown in both forms', (
    tester,
  ) async {
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
    // 细分切片：中性括号。
    for (final count in const ['(2)', '(1)']) {
      expect(
        find.descendant(of: _segments(), matching: find.text(count)),
        findsOneWidget,
        reason: '细分切片 $count 用中性括号',
      );
    }
  });

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
      expect(find.byType(AlertDialog), findsOneWidget);
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
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('LL-a、LL-b、LL-c'), findsOneWidget);
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
}
