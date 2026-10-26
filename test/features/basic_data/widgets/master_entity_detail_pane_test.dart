// 共享明细区(ADR-111)：批量启停/删除一次请求、失败逐条展示原因；行启停带列表行版本、
// 不先拉详情。锁住「选 100 条就是 200 次串行请求、catch 吞错只报 N 个跳过」不再回来。
// 2026-10-18 口径：批量操作走右键菜单（多选时出批量项），右下悬浮组只挂
// 「已选 N 项 + 添加X」——测试同步改为经 rowMenuBuilder 驱动批量命令。
import 'dart:async';
import 'package:dio/dio.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/features/basic_data/models/master_batch.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/master_batch_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/master_status_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_entity_detail_pane.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Row {
  const _Row(this.id, this.name, this.status, this.version);

  final String id;
  final String name;
  final String status;
  final int version;
}

class _FakeBatchRepository implements MasterBatchRepository {
  _FakeBatchRepository({this.failIds = const {}});

  final Set<String> failIds;
  final statusCalls = <(String, String, List<MasterBatchItem>)>[];
  final deleteCalls = <(String, List<MasterBatchItem>)>[];

  MasterBatchResult _result(List<MasterBatchItem> items) {
    final results = [
      for (final item in items)
        MasterBatchItemResult(
          id: item.id,
          label: '货品-${item.id}',
          ok: !failIds.contains(item.id),
          reason: failIds.contains(item.id)
              ? '货品「货品-${item.id}」不能删除：1) 它还是以下货品的 BOM 组件：FG-1 成品，请先在这些货品的 BOM 里移除它'
              : null,
        ),
    ];
    final ok = results.where((r) => r.ok).length;
    return MasterBatchResult(
      succeeded: ok,
      failed: results.length - ok,
      results: results,
    );
  }

  @override
  Future<MasterBatchResult> changeStatus({
    required String entityPath,
    required String status,
    required List<MasterBatchItem> items,
  }) async {
    statusCalls.add((entityPath, status, items));
    return _result(items);
  }

  @override
  Future<MasterBatchResult> delete({
    required String entityPath,
    required List<MasterBatchItem> items,
  }) async {
    deleteCalls.add((entityPath, items));
    return _result(items);
  }
}

class _FakeStatusRepository implements MasterStatusRepository {
  final calls = <(String, String, int?)>[];

  @override
  Future<void> change({
    required String resourcePath,
    required String status,
    int? version,
  }) async {
    calls.add((resourcePath, status, version));
  }
}

final _rows = [for (var i = 0; i < 100; i++) _Row('g$i', '货品$i', '使用', i + 7)];

class _Counters {
  int detailCalls = 0;
  int listCalls = 0;
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

Future<_Counters> _pump(
  WidgetTester tester,
  _FakeBatchRepository batch,
  _FakeStatusRepository status, {
  Future<PagedResult<_Row>> Function(MasterPaneQuery)? loadPage,
}) async {
  final counters = _Counters();
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final config = MasterEntityPaneConfig<_Row, _Row>(
    noun: '货品',
    icon: Icons.inventory_2_outlined,
    defaultCodePrefix: 'HP',
    columns: [
      MasterColumnDef<_Row>(
        key: 'name',
        label: '货品名称',
        width: 200,
        value: (r) => r.name,
      ),
    ],
    idOf: (r) => r.id,
    statusOf: (r) => r.status,
    versionOf: (r) => r.version,
    labelOf: (r) => r.name,
    loadCategory: (id) async => ProductCategoryDetail(
      id: id,
      code: 'C1',
      name: '成品类',
      level: 0,
      path: '成品类',
      childCount: 0,
    ),
    loadPage: (q) async {
      counters.listCalls++;
      if (loadPage != null) return loadPage(q);
      return PagedResult(
        items: _rows,
        page: 1,
        size: 100,
        total: _rows.length,
        totalPages: 1,
      );
    },
    loadFacets: (_) async => const MasterPaneFacets(fields: {}, nullCounts: {}),
    batchEntityPath: '/master/goods',
    statusResourceOf: (id) => '/master/goods/$id',
    canCreate: false,
    canEdit: true,
    canDelete: true,
    canStatus: true,
    loadDetail: (id) async {
      counters.detailCalls++;
      return _rows.first;
    },
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(Dio())),
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'pane-batch-test'),
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.goodsView,
          Perm.goodsStatus,
          Perm.goodsDelete,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(preferences),
        masterBatchRepositoryProvider.overrideWithValue(batch),
        masterStatusRepositoryProvider.overrideWithValue(status),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MasterEntityDetailPane<_Row, _Row>(
            config: config,
            categoryId: 'cat-1',
            externalKeyword: null,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return counters;
}

MasterDataTableView<_Row> _table(WidgetTester tester) => tester
    .widget<MasterDataTableView<_Row>>(find.byType(MasterDataTableView<_Row>));

/// 勾选全部 100 行(表格的勾选回调就是页面会收到的那一个)。
Future<void> _selectAll(WidgetTester tester) async {
  _table(tester).onSelectedIdsChanged!({for (final r in _rows) r.id});
  await tester.pumpAndSettle();
}

/// 右键多选批量菜单里的指定条目（作用于整个选中集）。取首行——它必须已在
/// 选中集内，多选分支才会出批量项。
UtenMenuItem _batchMenuEntry(WidgetTester tester, String label) =>
    _table(tester).rowMenuBuilder!(_rows[0])
        .whereType<UtenMenuItem>()
        .firstWhere((e) => e.label == label);

Future<void> _statusAction(WidgetTester tester, UtenMenuItem entry) async {
  unawaited(Future<void>.sync(entry.onTap));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, '确认'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('主档viewport仍在1且最新DTO为3时显式跳3走缓存并完成同DTO导航', (tester) async {
    final reads = <int>[];
    await _pump(
      tester,
      _FakeBatchRepository(),
      _FakeStatusRepository(),
      loadPage: (query) async {
        reads.add(query.page);
        return PagedResult<_Row>(
          items: _rows.skip((query.page - 1) * 20).take(20).toList(),
          page: query.page,
          size: 20,
          total: 60,
          totalPages: 3,
        );
      },
    );
    final rows = _table(tester).rowsController!;
    await rows.loadNextPage();
    await tester.pumpAndSettle();
    await rows.loadNextPage();
    await tester.pumpAndSettle();
    expect(rows.visiblePage, 1);
    rows.goToPage(3);
    await tester.pumpAndSettle();
    expect(rows.visiblePage, 3);
    expect(reads.where((page) => page == 3), hasLength(1));
  });

  testWidgets('主档跳到79并补78后默认返回刷新及写后刷新仍鲜读79', (tester) async {
    final reads = <int>[];
    await _pump(
      tester,
      _FakeBatchRepository(),
      _FakeStatusRepository(),
      loadPage: (query) async {
        reads.add(query.page);
        return PagedResult<_Row>(
          items: [
            for (var i = 0; i < 20; i++)
              _Row(
                'p${query.page}-$i',
                '第${query.page}页货品$i',
                '使用',
                query.page,
              ),
          ],
          page: query.page,
          size: 20,
          total: 2000,
          totalPages: 100,
        );
      },
    );
    final rows = _table(tester).rowsController!;
    rows.goToPage(79);
    await tester.pumpAndSettle();
    final settled = rows.settled;
    await tester.pumpAndSettle();
    await settled;
    expect(rows.pagination.value?.currentPage, 79);
    expect(reads, containsAll([79, 78, 80]));
    expect(reads, isNot(contains(77)));
    final pane =
        tester.state(find.byType(MasterEntityDetailPane<_Row, _Row>))
            as MasterEntityPaneController<_Row, _Row>;
    await pane.reload();
    await tester.pumpAndSettle();
    expect(_table(tester).currentPage, 79);
    expect(reads.where((page) => page == 79), hasLength(2));
    await pane.reload();
    await tester.pumpAndSettle();
    expect(_table(tester).currentPage, 79);
    expect(reads.where((page) => page == 79), hasLength(3));
  });

  testWidgets('主档补齐缓冲页不会把缓冲页继续当作新的预测中心', (tester) async {
    final reads = <int>[];
    await _pump(
      tester,
      _FakeBatchRepository(),
      _FakeStatusRepository(),
      loadPage: (query) async {
        reads.add(query.page);
        return PagedResult<_Row>(
          items: _rows.skip((query.page - 1) * 30).take(30).toList(),
          page: query.page,
          size: 30,
          total: 90,
          totalPages: 3,
        );
      },
    );
    expect(reads, [1, 2]);
    await PagedReadIntent.bufferSeed(() => _table(tester).onPageChange!(2));
    await tester.pumpAndSettle();
    expect(reads, [1, 2]);
    await _table(tester).onPageChange!(2);
    await tester.pumpAndSettle();
    expect(reads, [1, 2, 3]);
  });

  testWidgets('主档首屏预取下一页且往返分页复用数据，显式刷新重取', (tester) async {
    final reads = <int>[];
    await _pump(
      tester,
      _FakeBatchRepository(),
      _FakeStatusRepository(),
      loadPage: (query) async {
        reads.add(query.page);
        return PagedResult<_Row>(
          items: _rows.skip((query.page - 1) * 30).take(30).toList(),
          page: query.page,
          size: 30,
          total: 90,
          totalPages: 3,
        );
      },
    );
    expect(reads, [1, 2], reason: '仅提前一页，不遍历整个结果集');
    expect(_table(tester).currentPage, 1);
    expect(_table(tester).expensiveRowMounts, isFalse);
    await _table(tester).onPageChange!(2);
    await tester.pumpAndSettle();
    expect(_table(tester).currentPage, 2);
    expect(reads, [1, 2, 3], reason: '进入第二页后准备第三页');
    await _table(tester).onPageChange!(1);
    await tester.pumpAndSettle();
    expect(_table(tester).currentPage, 1);
    expect(reads, [1, 2, 3], reason: '返回已看过的第一页无需重新请求');
    final pane =
        tester.state(find.byType(MasterEntityDetailPane<_Row, _Row>))
            as MasterEntityPaneController<_Row, _Row>;
    await pane.reload();
    await tester.pumpAndSettle();
    expect(reads.where((page) => page == 1).length, 2);
    expect(reads.where((page) => page == 2).length, 2);
  });

  testWidgets('主档进入仍在预取的页只接管一个请求，预取不改变加载状态', (tester) async {
    final next = Completer<PagedResult<_Row>>();
    final reads = <int>[];
    await _pump(
      tester,
      _FakeBatchRepository(),
      _FakeStatusRepository(),
      loadPage: (query) async {
        reads.add(query.page);
        if (query.page == 2) return next.future;
        return PagedResult<_Row>(
          items: _rows.take(30).toList(),
          page: 1,
          size: 30,
          total: 60,
          totalPages: 2,
        );
      },
    );
    expect(reads, [1, 2]);
    expect(_table(tester).isLoading, isFalse);
    expect(_table(tester).loadingMore, isFalse);
    expect(_table(tester).currentPage, 1);
    final navigation = _table(tester).onPageChange!(2);
    await tester.pump();
    expect(reads, [1, 2]);
    next.complete(
      PagedResult<_Row>(
        items: _rows.skip(30).take(30).toList(),
        page: 2,
        size: 30,
        total: 60,
        totalPages: 2,
      ),
    );
    await navigation;
    await tester.pumpAndSettle();
    expect(_table(tester).currentPage, 2);
    expect(reads, [1, 2]);
  });

  testWidgets('批量禁用 100 条只发 1 次请求，带上每行版本，不逐条拉详情', (tester) async {
    final batch = _FakeBatchRepository();
    final status = _FakeStatusRepository();
    final counts = await _pump(tester, batch, status);
    await _selectAll(tester);

    await _statusAction(tester, _batchMenuEntry(tester, '批量禁用(100)'));
    await tester.pumpAndSettle();

    expect(batch.statusCalls, hasLength(1), reason: '选 100 条也只发一次批量命令');
    final (path, target, items) = batch.statusCalls.single;
    expect(path, '/master/goods');
    expect(target, '禁用');
    expect(items, hasLength(100));
    expect(items.first.version, 7, reason: '列表行版本随请求带上，服务端逐条比对');
    expect(status.calls, isEmpty, reason: '不再逐条 PATCH');
    expect(counts.detailCalls, 0, reason: '不再逐条拉详情拿版本');
    // 全部成功不弹结果框(只走顶部通知)。
    expect(find.byKey(const Key('master-batch-outcome')), findsNothing);
    // 全部成功：勾选清空。
    expect(_table(tester).selectedIds, isEmpty);
  });

  testWidgets('批量删除失败逐条展示服务端原因，失败行保留勾选', (tester) async {
    final batch = _FakeBatchRepository(failIds: {'g3', 'g4'});
    await _pump(tester, batch, _FakeStatusRepository());
    await _selectAll(tester);

    // 不等待 onTap：它会停在删除确认弹窗上，测试要在弹窗开着的当口去点「删除」
    //（与真实右键菜单交互同形，旧按钮测试的 tester.tap 也不等待按钮回调）。
    final confirmDelete = _batchMenuEntry(tester, '批量删除(100)').onTap;
    unawaited(Future<void>.sync(confirmDelete));
    await tester.pumpAndSettle();
    // 确认框(危险操作) → 删除。
    await tester.tap(find.widgetWithText(UtenButton, '删除'));
    await tester.pumpAndSettle();

    expect(batch.deleteCalls, hasLength(1));
    expect(batch.deleteCalls.single.$2, hasLength(100));
    expect(find.byKey(const Key('master-batch-outcome')), findsOneWidget);
    expect(find.text('已删除 98 个，2 个没有处理'), findsOneWidget);
    expect(find.text('货品-g3'), findsOneWidget);
    expect(find.textContaining('它还是以下货品的 BOM 组件'), findsNWidgets(2));
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(_table(tester).selectedIds, {'g3', 'g4'}, reason: '失败的留着方便处理后重试');
  });

  testWidgets('追加第二页后批量操作携带两页货品各自的版本', (tester) async {
    final batch = _FakeBatchRepository();
    await _pump(
      tester,
      batch,
      _FakeStatusRepository(),
      loadPage: (query) async => PagedResult<_Row>(
        items: [_rows[query.page - 1]],
        page: query.page,
        size: 1,
        total: 2,
        totalPages: 2,
      ),
    );
    _table(tester).onSelectedIdsChanged!({'g0'});
    await tester.pumpAndSettle();

    final displayedRows = _table(tester).rowsController!;
    await displayedRows.loadNextPage();
    await tester.pumpAndSettle();
    expect(displayedRows.items.map((row) => row.id), ['g0', 'g1']);
    expect(_table(tester).selectedIds, {'g0'});
    _table(tester).onSelectedIdsChanged!({'g0', 'g1'});
    await tester.pumpAndSettle();

    await _statusAction(tester, _batchMenuEntry(tester, '批量禁用(2)'));
    await tester.pumpAndSettle();
    expect(batch.statusCalls, hasLength(1));
    expect(
      {for (final item in batch.statusCalls.single.$3) item.id: item.version},
      {'g0': 7, 'g1': 8},
      reason: '仍显示的上一页行必须留在批量命令的版本快照中',
    );
  });

  testWidgets('行启停走单条窄命令，带列表行版本，不先拉详情', (tester) async {
    final status = _FakeStatusRepository();
    final counts = await _pump(tester, _FakeBatchRepository(), status);
    final menu = _table(tester).rowMenuBuilder!(_rows[2]);
    await _statusAction(
      tester,
      menu.whereType<UtenMenuItem>().firstWhere((e) => e.label == '禁用货品'),
    );
    await tester.pumpAndSettle();

    expect(status.calls, [('/master/goods/g2', '禁用', 9)]);
    expect(counts.detailCalls, 0);
  });

  testWidgets('单行勾选右键出单行菜单，未多选不出批量项', (tester) async {
    await _pump(tester, _FakeBatchRepository(), _FakeStatusRepository());
    _table(tester).onSelectedIdsChanged!({'g2'});
    await tester.pumpAndSettle();

    final labels = _table(tester).rowMenuBuilder!(_rows[2])
        .whereType<UtenMenuItem>()
        .map((e) => e.label)
        .toList();
    expect(labels, contains('禁用货品'));
    expect(
      labels.where((l) => l.startsWith('批量')),
      isEmpty,
      reason: '单选右键是单行菜单；批量项只在多选(>1)时出现',
    );
  });

  testWidgets('右下悬浮组只挂「已选 N 项 + 添加X」，添加随新增权限出现', (tester) async {
    // 默认 canCreate:false → 悬浮组只有已选胶囊，没有添加按钮。
    await _pump(tester, _FakeBatchRepository(), _FakeStatusRepository());
    expect(find.byKey(const ValueKey('master-add-entity')), findsNothing);
    expect(
      find.byKey(const ValueKey('master-table-clear-selection')),
      findsOneWidget,
    );
    // 标题行已删：数量进分类卡片标题，不再出现「货品 (100)」工具行文案。
    expect(find.text('货品 (100)'), findsNothing);
    expect(find.textContaining('（备注'), findsNothing);
    expect(
      find.text('成品类 (数量: 100)'),
      findsOneWidget,
      reason: '分类卡片标题 = 名称（备注）(数量: N)，与左侧列表同形',
    );
  });
}
