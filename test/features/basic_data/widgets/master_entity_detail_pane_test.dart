// 共享明细区(ADR-111)：批量启停/删除一次请求、失败逐条展示原因；行启停带列表行版本、
// 不先拉详情。锁住「选 100 条就是 200 次串行请求、catch 吞错只报 N 个跳过」不再回来。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/features/basic_data/models/master_batch.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/master_batch_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/master_status_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_entity_detail_pane.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
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

Future<_Counters> _pump(
  WidgetTester tester,
  _FakeBatchRepository batch,
  _FakeStatusRepository status,
) async {
  final counters = _Counters();
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final config = MasterEntityPaneConfig<_Row, _Row>(
    noun: '货品',
    icon: Icons.inventory_2_outlined,
    defaultCodePrefix: 'HP',
    keyPrefix: 'goods',
    searchHint: '搜索',
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
        sharedPreferencesProvider.overrideWithValue(preferences),
        masterBatchRepositoryProvider.overrideWithValue(batch),
        masterStatusRepositoryProvider.overrideWithValue(status),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: MasterEntityDetailPane<_Row, _Row>(
            config: config,
            categoryId: 'cat-1',
            canEditCategory: false,
            canAddCategory: false,
            canDeleteCategory: false,
            externalKeyword: null,
            onAddChild: () {},
            onEditCategory: (_) {},
            onDeleteCategory: () {},
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

void main() {
  testWidgets('批量禁用 100 条只发 1 次请求，带上每行版本，不逐条拉详情', (tester) async {
    final batch = _FakeBatchRepository();
    final status = _FakeStatusRepository();
    final counts = await _pump(tester, batch, status);
    await _selectAll(tester);

    await tester.tap(find.byKey(const ValueKey('master-batch-disable')));
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
    // 全部成功：勾选清空，批量按钮回灰。
    expect(_table(tester).selectedIds, isEmpty);
    expect(
      tester
          .widget<UtenButton>(
            find.byKey(const ValueKey('master-batch-disable')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('批量删除失败逐条展示服务端原因，失败行保留勾选', (tester) async {
    final batch = _FakeBatchRepository(failIds: {'g3', 'g4'});
    await _pump(tester, batch, _FakeStatusRepository());
    await _selectAll(tester);

    await tester.tap(find.byKey(const ValueKey('master-batch-delete')));
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

  testWidgets('行启停走单条窄命令，带列表行版本，不先拉详情', (tester) async {
    final status = _FakeStatusRepository();
    final counts = await _pump(tester, _FakeBatchRepository(), status);
    final menu = _table(tester).rowMenuBuilder!(_rows[2]);
    await menu
        .whereType<UtenMenuItem>()
        .firstWhere((e) => e.label == '禁用货品')
        .onTap();
    await tester.pumpAndSettle();

    expect(status.calls, [('/master/goods/g2', '禁用', 9)]);
    expect(counts.detailCalls, 0);
  });
}
