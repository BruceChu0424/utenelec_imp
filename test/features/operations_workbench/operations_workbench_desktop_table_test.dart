import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart'
    show UtenStatusBadgeType;
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/data_display/uten_status_cell_color.dart'
    show utenStatusBadgeCellColor;
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/pages/operations_workbench_page.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

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
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            // 覆写 prefs 后真实 api 链路（仓库字典预热）会在测试环境发起真网络
            // 请求并永久挂起，页面停在加载圈；注入假 api 让预热走空数据。
            apiClientProvider.overrideWithValue(_FakeApi()),
            // ADR-184：阶段红黄数改由徽章事实提供；红 1 的「待填写物料」
            // 段保持 actionable，进页面才会自动选中并直接出表。
            fixedBadgeSummaryOverride(
              badgeSummaryFixture(
                facts: const {
                  BadgeFact.productionDrawMaterialsToDefine: 1,
                  BadgeFact.productionDrawReady: 0,
                  BadgeFact.productionDrawPartial: 0,
                },
              ),
            ),
          ],
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
      // 2026-10-04 起红1的「待填写物料」阶段自动选中（原手动 tap 因表格行
      // 状态列同名文本产生二义查找，且已是选中态无需再点）。
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
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          apiClientProvider.overrideWithValue(_FakeApi()),
          // ADR-184：红 2 的「申请待分解」段改由徽章事实提供，保持进页面自动选中。
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(
              facts: const {
                BadgeFact.purchaseTaskWaitingOrder: 2,
                BadgeFact.purchaseTaskRework: 0,
                BadgeFact.purchaseTaskInProgress: 0,
              },
            ),
          ),
        ],
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

    // 2026-10-04 起进页面自动选中红2的「申请待分解」段：表格直接加载，不再有
    // 引导占位；再点已选段不重复发请求。
    expect(find.text('在上方选择阶段后开始办理'), findsNothing);
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
    // 2026-10-10 列口径：「供给方式」「执行入口」列退役（执行入口与单据号/
    // 状态两列同源同值；受限提示并入单据号列）。
    final table = tester.widget<MasterDataTableView<OperationsWorkbenchTask>>(
      find.descendant(
        of: find.byKey(const Key('operations-workbench-desktop-table')),
        matching: find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView<OperationsWorkbenchTask>,
        ),
      ),
    );
    final columnKeys = table.columns.map((column) => column.key).toSet();
    expect(columnKeys.contains('supplyRoute'), isFalse);
    expect(columnKeys.contains('action'), isFalse);
    final first = table.items.first;
    final context = tester.element(
      find.byKey(const Key('operations-workbench-desktop-table')),
    );
    expect(
      table.columns
          .singleWhere((column) => column.key == 'exception')
          .cellColor!(context, first),
      utenStatusBadgeCellColor(UtenStatusBadgeType.success),
    );
    final unfinished =
        table.columns
                .singleWhere((column) => column.key == 'openQty')
                .cellBuilder!(context, first)
            as Text;
    expect(unfinished.style?.fontWeight, FontWeight.w700);
    expect(unfinished.style?.color, Theme.of(context).colorScheme.error);
    expect(
      table.columns
          .singleWhere((column) => column.key == 'actionDocNo')
          .value(first),
      'PR-request-1',
    );
    // 仓库列（2026-10-10）：测试环境没有主档字典（api 未注入、预热静默失败），
    // 回退服务端下发的叶仓名；单据号列承接受限提示的行为见 page_test。
    expect(
      table.columns
          .singleWhere((column) => column.key == 'warehouseName')
          .value(first),
      '原材料仓',
    );
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
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          apiClientProvider.overrideWithValue(_FakeApi()),
          // ADR-184：红 1 的「申请待分解」段改由徽章事实提供（本用例不断言
          // 红黄数，事实按 statusCounts 同值给出，保持原有自动选中后手动复点）。
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(
              facts: const {
                BadgeFact.purchaseTaskWaitingOrder: 1,
                BadgeFact.purchaseTaskRework: 0,
                BadgeFact.purchaseTaskInProgress: 0,
              },
            ),
          ),
        ],
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
    expect(refreshed.serverColumnSearch, isTrue);
    expect(
      refreshed.columns.any((column) => column.key == 'supplierName'),
      isTrue,
    );
    refreshed.onFilterChanged('search.goodsName', '开关 面板');
    await tester.pumpAndSettle();
    final searched = tester
        .widget<MasterDataTableView<OperationsWorkbenchTask>>(tableFinder);
    expect(gateway.columnFilters.last, {
      'goods': 'goods-1',
      'search.goods': '开关 面板',
    });
    expect(searched.filters['search.goodsName'], '开关 面板');
    searched.onFilterChanged('search.goodsCode', 'M3_20%');
    await tester.pumpAndSettle();
    final export = tester.widget<UtenExportButton>(
      find.byKey(const Key('purchase-workbench-export')),
    );
    expect(export.endpoint, '/operations/workbench/purchase/export');
    expect(export.queryParams, {
      'status': 'WAITING_ORDER',
      'f.goods': 'goods-1',
      'search.goods': '开关 面板',
      'search.goodsCode': 'M3_20%',
    });
    expect(export.queryParams.containsKey('page'), isFalse);
    expect(export.queryParams.containsKey('size'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('merged status column tiers follow the ADR-169 baseline', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          apiClientProvider.overrideWithValue(_FakeApi()),
          // ADR-184：本用例只断言状态列配色，事实按 statusCounts 同值给出
          // （申请待分解红 1 仍自动选中，再手动切「进行中」）。
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(
              facts: const {
                BadgeFact.purchaseTaskWaitingOrder: 1,
                BadgeFact.purchaseTaskRework: 1,
                BadgeFact.purchaseTaskInProgress: 4,
              },
            ),
          ),
        ],
        child: MaterialApp(
          home: OperationsWorkbenchPage(
            department: OperationsWorkbenchDepartment.purchase,
            repository: _FakeGateway(
              OperationsWorkbenchData(
                department: OperationsWorkbenchDepartment.purchase,
                summary: const OperationsWorkbenchSummary(
                  totalTasks: 5,
                  overdueTasks: 0,
                  openTasks: 5,
                  openQty: 40,
                  statusCounts: {
                    'WAITING_ORDER': 1,
                    'ORDER_PENDING_APPROVAL': 1,
                    'FINANCE_APPROVED': 1,
                    'FINANCE_REJECTED': 1,
                    'COMPLETED': 1,
                    'IN_PROGRESS': 4,
                  },
                ),
                items: [
                  _task(id: 'w', goodsName: '申请待分解行'),
                  _task(
                    id: 'p',
                    goodsName: '等待财务审核行',
                    taskStatus: 'ORDER_PENDING_APPROVAL',
                  ),
                  _task(
                    id: 'a',
                    goodsName: '财务已通过行',
                    taskStatus: 'FINANCE_APPROVED',
                  ),
                  _task(
                    id: 'r',
                    goodsName: '财务驳回行',
                    taskStatus: 'FINANCE_REJECTED',
                  ),
                  _task(id: 'c', goodsName: '已完成行', taskStatus: 'COMPLETED'),
                ],
                page: 1,
                size: 20,
                total: 5,
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
    await tester.tap(find.text('进行中'));
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<OperationsWorkbenchTask>>(
      find.descendant(
        of: find.byKey(const Key('operations-workbench-desktop-table')),
        matching: find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView<OperationsWorkbenchTask>,
        ),
      ),
    );
    final statusColumn = table.columns.firstWhere((c) => c.key == 'status');
    final context = tester.element(find.byType(OperationsWorkbenchPage));
    Color? cellOf(String id) => statusColumn.cellColor!(
      context,
      table.items.firstWhere((task) => task.taskId == id),
    );
    // ADR-169 基准表：申请待分解(可生成订货单)=绿、等财务=黄、财务已通过=蓝、
    // 财务驳回=红、已完成=绿。
    expect(cellOf('w'), utenStatusBadgeCellColor(UtenStatusBadgeType.success));
    expect(cellOf('p'), utenStatusBadgeCellColor(UtenStatusBadgeType.warning));
    expect(cellOf('a'), utenStatusBadgeCellColor(UtenStatusBadgeType.info));
    expect(cellOf('r'), utenStatusBadgeCellColor(UtenStatusBadgeType.danger));
    expect(cellOf('c'), utenStatusBadgeCellColor(UtenStatusBadgeType.success));
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

/// 其余请求（徽章、仓库字典预热等）一律回空, 不走真网络（ADR-184 起覆写
/// sharedPreferencesProvider 后, 真实 api 链路在测试环境会挂起加载）。
class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio(BaseOptions(baseUrl: 'http://localhost:8080/api')));

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {'items': <Object?>[], 'page': 1, 'total': 0, 'totalPages': 1};

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

OperationsWorkbenchTask _task({
  required String id,
  required String goodsName,
  String? actionDocItemId,
  String taskStatus = 'WAITING_ORDER',
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
    taskStatus: taskStatus,
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
