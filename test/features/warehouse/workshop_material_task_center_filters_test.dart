import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_task_center.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_view.dart';

import 'workshop_material_test_support.dart';

class _SavedQuery extends PlatformTableLayoutNotifier {
  _SavedQuery(super.tableKey);
  @override
  PlatformTableLayout build() {
    super.build();
    return const PlatformTableLayout(
      order: ['requestNo', 'status', 'kind'],
      filters: {'status': 'DONE', 'kind': 'ISSUE'},
      hasQueryPreferences: true,
    );
  }

  @override
  void persist() {}
}

class _Requisitions extends FakeWorkshopMaterialRepository {
  final queries =
      <
        ({
          WarehouseTaskView view,
          String? status,
          String? kind,
          int page,
          Map<String, String> scope,
        })
      >[];
  final rows = [
    for (var index = 1; index <= 20; index++)
      WmRequisition(
        id: 'issue-$index',
        requestNo: 'ISSUE-$index',
        kind: 'ISSUE',
        status: 'PENDING',
      ),
    const WmRequisition(
      id: 'return-21',
      requestNo: 'RETURN-21',
      kind: 'RETURN',
      status: 'DONE',
    ),
  ];

  @override
  Future<PagedResult<WmRequisition>> requisitions({
    WarehouseTaskView view = WarehouseTaskView.active,
    String? status,
    String? kind,
    String? workshopId,
    String? keyword,
    int page = 1,
    int size = 20,
    Map<String, String> scope = const {},
  }) async {
    queries.add((
      view: view,
      status: status,
      kind: kind,
      page: page,
      scope: Map.of(scope),
    ));
    final matching = rows
        .where(
          (row) =>
              (view == WarehouseTaskView.active
                  ? row.status == 'PENDING'
                  : row.status != 'PENDING') &&
              (status == null || row.status == status) &&
              (kind == null || row.kind == kind),
        )
        .toList();
    return PagedResult(
      items: matching.skip((page - 1) * size).take(size).toList(),
      page: page,
      size: size,
      total: matching.length,
      totalPages: (matching.length + size - 1) ~/ size,
    );
  }
}

MasterDataTableView<WmRequisition> _table(WidgetTester tester) =>
    tester.widget(find.byType(MasterDataTableView<WmRequisition>));

void main() {
  testWidgets('旧记录查询偏好不能覆盖待收退回入口的默认数据范围', (tester) async {
    final repo = _Requisitions();
    const key =
        'features.warehouse.materialbin.widgets.workshop_material_task_center.WmRequisitionSegmentState.build.1';
    await pumpWorkshopMaterialPage(
      tester,
      ProviderScope(
        overrides: [
          platformTableLayoutProvider(key).overrideWith(() => _SavedQuery(key)),
        ],
        child: const Scaffold(
          body: WmRequisitionSegment(
            status: 'PENDING',
            kind: 'RETURN',
            keyword: '',
            refreshTick: 0,
            header: SizedBox.shrink(),
          ),
        ),
      ),
      repo: repo,
    );
    expect(
      repo.queries.every(
        (query) => query.status == 'PENDING' && query.kind == 'RETURN',
      ),
      isTrue,
    );
    expect(_table(tester).filters, {'status': 'PENDING', 'kind': 'RETURN'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('申请状态/类型表头由服务端过滤全结果，清空保留仓库范围', (tester) async {
    final repo = _Requisitions();
    await pumpWorkshopMaterialPage(
      tester,
      const Scaffold(
        body: WarehouseListScope(
          scope: WarehouseTaskScope.warehouse('warehouse-1'),
          child: WmRequisitionSegment(
            view: WarehouseTaskView.history,
            keyword: '',
            refreshTick: 0,
            header: SizedBox.shrink(),
          ),
        ),
      ),
      repo: repo,
    );
    expect(repo.queries.last.view, WarehouseTaskView.history);
    expect(find.text('RETURN-21'), findsOneWidget);
    expect(_table(tester).totalPages, 1);
    expect(_table(tester).requiredLeadingColumnKeys, ['status']);
    _table(tester).onFilterChanged('status', 'DONE');
    await tester.pumpAndSettle();
    expect(repo.queries.last.status, 'DONE');
    expect(repo.queries.last.page, 1);
    expect(find.text('RETURN-21'), findsOneWidget);
    expect(find.text('退料已收'), findsOneWidget);
    _table(tester).onFilterChanged('kind', 'RETURN');
    await tester.pumpAndSettle();
    expect(repo.queries.last.kind, 'RETURN');
    _table(tester).onFilterChanged('status', null);
    await tester.pumpAndSettle();
    _table(tester).onFilterChanged('kind', null);
    await tester.pumpAndSettle();
    expect(repo.queries.last.status, isNull);
    expect(repo.queries.last.kind, isNull);
    expect(repo.queries.last.scope, {'scopeWarehouseId': 'warehouse-1'});
    expect(repo.queries.last.view, WarehouseTaskView.history);
    expect(_table(tester).totalPages, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('待发料默认范围仍是PENDING/ISSUE，旧非法表头值清回全部', (tester) async {
    final repo = _Requisitions();
    await pumpWorkshopMaterialPage(
      tester,
      const Scaffold(
        body: WmRequisitionSegment(
          status: 'PENDING',
          kind: 'ISSUE',
          keyword: '',
          refreshTick: 0,
          header: SizedBox.shrink(),
        ),
      ),
      repo: repo,
    );
    expect(repo.queries.last.status, 'PENDING');
    expect(repo.queries.last.kind, 'ISSUE');
    expect(find.text('领料待发'), findsWidgets);
    _table(tester).onFilterChanged('status', 'OLD_UNKNOWN_STATUS');
    await tester.pumpAndSettle();
    expect(repo.queries.last.status, isNull);
    expect(repo.queries.last.kind, 'ISSUE');
    expect(tester.takeException(), isNull);
  });
}
