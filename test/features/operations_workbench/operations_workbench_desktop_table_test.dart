import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/pages/operations_workbench_page.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';

void main() {
  testWidgets(
    'warehouse discovery stage exposes its row with unknown quantities and a valid entry',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final task = OperationsWorkbenchTask.fromJson({
        'taskId': 'discovery-1',
        'supplyRoute': 'MAKE',
        'taskStatus': 'MATERIALS_TO_DEFINE',
        'goodsName': '待登记外壳用料',
        'goodsCount': 1,
        'openLineCount': 1,
        'unitName': 'kg',
        'actionDocType': 'MATERIAL_DISCOVERY',
        'actionDocId': 'request-1',
        'actionDocCanView': true,
      }, OperationsWorkbenchDepartment.warehouse);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.warehouse,
              repository: _FakeGateway(
                OperationsWorkbenchData(
                  department: OperationsWorkbenchDepartment.warehouse,
                  summary: const OperationsWorkbenchSummary(
                    totalTasks: 1,
                    overdueTasks: 0,
                    openTasks: 1,
                    openQty: 0,
                    statusCounts: {'MATERIALS_TO_DEFINE': 1},
                  ),
                  items: [task],
                  page: 1,
                  size: 20,
                  total: 1,
                  totalPages: 1,
                  capabilities: const OperationsWorkbenchCapabilities(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('待填写物料'));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<OperationsWorkbenchTask>>(
        find.descendant(
          of: find.byKey(const Key('operations-workbench-desktop-table')),
          matching: find.byWidgetPredicate(
            (widget) => widget is MasterDataTableView<OperationsWorkbenchTask>,
          ),
        ),
      );
      for (final key in [
        'requiredQty',
        'allocatedQty',
        'fulfilledQty',
        'openQty',
      ]) {
        expect(
          table.columns.singleWhere((column) => column.key == key).value(task),
          '—',
        );
      }
      expect(
        table.columns
            .singleWhere((column) => column.key == 'status')
            .value(task),
        '待填写物料',
      );
      expect(table.canOpenRow!(task), isTrue);
      expect(task.actionDocument?.path, '/warehouse/tasks/draw');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('expanded desktop table renders header and rows with items', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: OperationsWorkbenchPage(
            department: OperationsWorkbenchDepartment.purchase,
            repository: _FakeGateway(
              OperationsWorkbenchData(
                department: OperationsWorkbenchDepartment.purchase,
                summary: const OperationsWorkbenchSummary(
                  totalTasks: 2,
                  overdueTasks: 0,
                  openTasks: 2,
                  openQty: 16,
                  statusCounts: {'WAITING_ORDER': 2},
                ),
                items: [
                  _task(id: 't1', goodsName: '桌面行一', actionDocItemId: 'ri-1'),
                  _task(id: 't2', goodsName: '桌面行二', actionDocItemId: 'ri-2'),
                ],
                page: 1,
                size: 20,
                total: 2,
                totalPages: 1,
                capabilities: const OperationsWorkbenchCapabilities(
                  canCreatePurchaseOrder: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 新范式：默认不选阶段，内容区只有引导占位不发列表请求；
    // 点「申请待分解」段后表格才加载。
    expect(find.text('在上方选择阶段后开始办理'), findsOneWidget);
    await tester.tap(find.text('申请待分解'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 桌面表格路径（expanded 断点）
    expect(
      find.byKey(const Key('operations-workbench-desktop-table')),
      findsOneWidget,
    );
    // 表头
    expect(find.text('计划号'), findsOneWidget);
    expect(find.text('货品名称'), findsOneWidget);
    // 表体行
    expect(find.text('桌面行一'), findsOneWidget);
    expect(find.text('桌面行二'), findsOneWidget);
    // 表格区域必须有非零高度
    final tableSize = tester.getSize(
      find.byKey(const Key('operations-workbench-desktop-table')),
    );
    expect(tableSize.height, greaterThan(100));
  });

  testWidgets('server facets flow into headers and come back as f.* filters', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gateway = _RecordingGateway(
      OperationsWorkbenchData(
        department: OperationsWorkbenchDepartment.purchase,
        summary: const OperationsWorkbenchSummary(
          totalTasks: 1,
          overdueTasks: 0,
          openTasks: 1,
          openQty: 8,
          statusCounts: {'WAITING_ORDER': 1},
        ),
        items: [_task(id: 't1', goodsName: '筛选行', actionDocItemId: 'ri-1')],
        page: 1,
        size: 20,
        total: 1,
        totalPages: 1,
        capabilities: const OperationsWorkbenchCapabilities(
          canCreatePurchaseOrder: true,
        ),
        // 服务端 facet key：docNo/goods 与本页列 key（actionDocNo/goodsName）不同名。
        facets: const {
          'goods': [
            MasterFacetBucket(value: 'goods-1', count: 1, label: 'MAT-t1 筛选行'),
          ],
          'status': [
            MasterFacetBucket(value: 'WAITING_ORDER', count: 1, label: '待处理'),
          ],
        },
        nullCounts: const {'spec': 1},
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: OperationsWorkbenchPage(
            department: OperationsWorkbenchDepartment.purchase,
            repository: gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('申请待分解'));
    await tester.pumpAndSettle();

    final tableFinder = find.descendant(
      of: find.byKey(const Key('operations-workbench-desktop-table')),
      matching: find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<OperationsWorkbenchTask>,
      ),
    );
    final table = tester.widget<MasterDataTableView<OperationsWorkbenchTask>>(
      tableFinder,
    );
    // facets/nullCounts 已按本页列 key 对齐（goods→goodsName）。
    expect(table.facets.keys, containsAll(<String>['goodsName', 'status']));
    expect(table.facets['goodsName']?.single.value, 'goods-1');
    expect(table.nullCounts['spec'], 1);

    // 选桶 → gateway 收到服务端 key（repository 再以 f.{key} 前缀回传）。
    table.onFilterChanged('goodsName', 'goods-1');
    await tester.pumpAndSettle();
    expect(gateway.columnFilters.last['goods'], 'goods-1');

    final refreshed = tester
        .widget<MasterDataTableView<OperationsWorkbenchTask>>(tableFinder);
    expect(refreshed.filters['goodsName'], 'goods-1');
    expect(tester.takeException(), isNull);
  });
}

class _RecordingGateway implements OperationsWorkbenchGateway {
  _RecordingGateway(this.data);

  final OperationsWorkbenchData data;
  final List<Map<String, String?>> columnFilters = [];

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
    this.columnFilters.add(Map<String, String?>.of(columnFilters));
    return data;
  }
}

class _FakeGateway implements OperationsWorkbenchGateway {
  _FakeGateway(this.data);

  final OperationsWorkbenchData data;

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
  }) async => data;
}

OperationsWorkbenchTask _task({
  required String id,
  required String goodsName,
  String? actionDocItemId,
}) {
  return OperationsWorkbenchTask(
    taskId: id,
    packageId: 'package-1',
    planId: 'plan-1',
    planNo: 'PP-001',
    warehouseName: '原材料仓',
    goodsCode: 'MAT-$id',
    goodsName: goodsName,
    spec: 'φ20',
    colorName: '本色',
    unitName: '件',
    supplyRoute: 'PURCHASE',
    requiredQty: 10,
    allocatedQty: 4,
    fulfilledQty: 2,
    supplyPeggedQty: 4,
    openQty: 8,
    taskStatus: 'WAITING_ORDER',
    needDate: '2026-08-01',
    expectedDate: null,
    exceptionCode: null,
    updatedAt: '2026-07-31T10:00:00+08:00',
    actionDocument: actionDocItemId == null
        ? null
        : const OperationsActionDocument(
            id: 'request-1',
            docType: 'PURCHASE_REQUEST',
            number: 'PR-request-1',
            path: '/purchase/requests/request-1',
            canView: true,
            canEdit: false,
            status: '1',
          ),
    actionDocItemId: actionDocItemId,
    actionDocumentRestricted: false,
  );
}
