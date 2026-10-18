// ADR-098 / ADR-143 委外任务中心：分类（草稿/待处理/进行中/历史记录，ADR-171 起
// 领料并入「待处理」子分类）、进行中查询 status=IN_PROGRESS、状态列按 displayStage
// 上色并给回厂短交待判定加「紧急」标签、异常小类行挂短交/退回；进行中状态码按
// ADR-143 §4.1 的领料制词表。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart'
    show UtenStatusBadgeType;
import 'package:uten_imp/components/data_display/uten_status_cell_color.dart'
    show utenStatusBadgeCellColor;
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_decomposition_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/models/subcontract_short_delivery.dart'
    show subcontractProgressStatusLabel;
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import 'fake_subcontract_draw_gateway.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => <String, dynamic>{};
}

class _Gateway implements OperationsWorkbenchGateway {
  final List<String?> statuses = [];
  final List<String?> exceptions = [];
  final List<Map<String, String?>> filters = [];

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
    statuses.add(status);
    exceptions.add(exception);
    filters.add(Map.of(columnFilters));
    final items = status == 'IN_PROGRESS'
        ? [
            _order(
              'o-short',
              'FINANCE_APPROVED',
              'SHORT_DELIVERY',
              'SHORT_DELIVERY',
            ),
            _order('o-supplier', 'FINANCE_APPROVED', 'AT_SUPPLIER', null),
            // ADR-143：齐套还缺物料、已在途 → 等待物料。
            _order(
              'o-waiting-material',
              'FINANCE_APPROVED',
              'WAITING_MATERIAL',
              null,
            ),
            _order(
              'o-received',
              'FINANCE_APPROVED',
              'RECEIVED_PENDING_STOCK',
              null,
            ),
            _order(
              'o-rejected',
              'FINANCE_REJECTED',
              'FINANCE_REJECTED',
              'FINANCE_REJECTED',
            ),
          ]
        : <OperationsWorkbenchTask>[];
    return OperationsWorkbenchData(
      department: department,
      summary: const OperationsWorkbenchSummary(
        totalTasks: 4,
        overdueTasks: 0,
        openTasks: 4,
        openQty: 30,
        statusCounts: {
          'WAITING_ORDER': 1,
          'ORDER_PENDING_APPROVAL': 1,
          'FINANCE_APPROVED': 3,
          'FINANCE_REJECTED': 1,
          'IN_PROGRESS': 5,
        },
        exceptionCounts: {'SHORT_DELIVERY': 1, 'FINANCE_REJECTED': 1},
      ),
      items: items,
      page: 1,
      size: 50,
      total: items.length,
      totalPages: 1,
      capabilities: const OperationsWorkbenchCapabilities(
        canCreateSubcontractOrder: true,
      ),
      facets: const {
        'status': [
          MasterFacetBucket(
            value: 'SHORT_DELIVERY',
            label: 'SHORT_DELIVERY',
            count: 1,
          ),
          MasterFacetBucket(
            value: 'AT_SUPPLIER',
            label: 'AT_SUPPLIER',
            count: 1,
          ),
        ],
      },
    );
  }
}

OperationsWorkbenchTask _order(
  String id,
  String taskStatus,
  String displayStage,
  String? exceptionCode,
) => OperationsWorkbenchTask.fromJson({
  'taskId': id,
  'planNo': 'PP-$id',
  'supplyRoute': 'SUBCONTRACT',
  'goodsCode': 'FG-$id',
  'goodsName': '委外件 $id',
  'requiredQty': 10,
  'openQty': 4,
  'taskStatus': taskStatus,
  'displayStage': displayStage,
  'exceptionCode': ?exceptionCode,
  'actionDocType': 'SUBCONTRACT_ORDER',
  'actionDocId': id,
  'actionDocNo': 'EO-$id',
  'actionDocCanView': true,
  'actionDocCanEdit': false,
  'actionDocStatus': '1',
}, OperationsWorkbenchDepartment.subcontract);

void main() {
  testWidgets('三段合并与进行中状态列', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = _Gateway();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {
            Perm.subcontractApplicationView,
            Perm.subcontractOrderView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          apiClientProvider.overrideWithValue(_Api()),
          sharedPreferencesProvider.overrideWithValue(preferences),
          // ADR-184 后分段红黄数来自徽章事实(与网关 summary 同数): 待处理红 =
          // 申请待下单(subcontractTaskWaitingOrder), 进行中红 = 财务驳回(rework),
          // 黄 = 真实在办(subcontractTaskInProgress)。待处理红数 > 0 → 进页面
          // 自动选中「待处理」, 待处理拍平表随挂载可见。
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(
              facts: const {
                BadgeFact.subcontractTaskWaitingOrder: 1,
                BadgeFact.subcontractTaskRework: 1,
                BadgeFact.subcontractTaskShortDelivery: 0,
                BadgeFact.subcontractTaskInProgress: 5,
              },
            ),
          ),
        ],
        child: MaterialApp(
          home: SubcontractDecompositionPage(
            repository: gateway,
            drawRepository: FakeSubcontractDrawGateway(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('待处理'), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('历史记录'), findsOneWidget);
    // ADR-171 修订二：领料连子分类行也不是了——拍平进「待处理」表，只是
    // 领料行的一种状态(进页面红数自动选中「待处理」后同一张表可见)。
    expect(
      find.descendant(
        of: find.byKey(const Key('subcontract-decomposition-stages')),
        matching: find.text('领料'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const Key('subcontract-decomposition-pending-categories')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('subcontract-decomposition-pending-table')),
      findsOneWidget,
    );
    expect(find.text('等待财务审核'), findsNothing);
    expect(find.text('财务已通过'), findsNothing);
    expect(find.text('财务驳回'), findsNothing);

    await tester.tap(find.text('进行中'));
    await tester.pumpAndSettle();
    expect(gateway.statuses.last, 'IN_PROGRESS');
    // 状态列：回厂短交待判定带紧急标签且可点去判定；加工中/退回各自文案。
    expect(find.text('回厂短交待判定'), findsWidgets);
    expect(find.text('紧急'), findsOneWidget);
    expect(find.byTooltip('点击去判定'), findsOneWidget);
    expect(find.text('委外加工中'), findsWidgets);
    expect(find.text('已回厂待入库'), findsWidgets);
    expect(find.text('财务已退回'), findsWidgets);
    expect(find.text('等待物料'), findsWidgets);
    // 状态列档位（ADR-169 基准表）：短交待判定=红、委外加工中=青绿、
    // 等待物料=红（料没到不能领）、已回厂待入库=黄（等仓库入库）、财务驳回=红。
    final table = tester.widget<MasterDataTableView<OperationsWorkbenchTask>>(
      find.byKey(const Key('subcontract-decomposition-table')),
    );
    final statusColumn = table.columns.firstWhere((c) => c.key == 'status');
    final cellContext = tester.element(
      find.byType(SubcontractDecompositionPage),
    );
    Color? cellOf(String id) => statusColumn.cellColor!(
      cellContext,
      table.items.firstWhere((task) => task.taskId == id),
    );
    expect(
      cellOf('o-short'),
      utenStatusBadgeCellColor(UtenStatusBadgeType.danger),
    );
    expect(
      cellOf('o-supplier'),
      utenStatusBadgeCellColor(UtenStatusBadgeType.accent),
    );
    expect(
      cellOf('o-waiting-material'),
      utenStatusBadgeCellColor(UtenStatusBadgeType.danger),
    );
    expect(
      cellOf('o-received'),
      utenStatusBadgeCellColor(UtenStatusBadgeType.warning),
    );
    expect(
      cellOf('o-rejected'),
      utenStatusBadgeCellColor(UtenStatusBadgeType.danger),
    );
    // 短交是独立处置案件，保留手动入口；退回只在状态列，不自动收窄进行中。
    expect(
      find.byKey(const Key('subcontract-decomposition-exceptions')),
      findsOneWidget,
    );
    expect(gateway.exceptions.last, isNull);
    final exceptionRow = find.byKey(
      const Key('subcontract-decomposition-exceptions'),
    );
    expect(
      find.descendant(of: exceptionRow, matching: find.text('财务已退回')),
      findsNothing,
    );
    await tester.tap(
      find.descendant(of: exceptionRow, matching: find.text('回厂短交待判定')),
    );
    await tester.pumpAndSettle();
    expect(gateway.exceptions.last, 'SHORT_DELIVERY');
    await tester.tap(
      find.descendant(of: exceptionRow, matching: find.text('全部')),
    );
    await tester.pumpAndSettle();
    expect(gateway.exceptions.last, isNull);
    expect(gateway.statuses.last, 'IN_PROGRESS');
    table.onFilterChanged('status', 'FINANCE_REJECTED');
    await tester.pumpAndSettle();
    expect(gateway.filters.last['status'], 'FINANCE_REJECTED');
    table.onFilterChanged('status', null);
    await tester.pumpAndSettle();
    expect(gateway.filters.last, isNot(contains('status')));
    expect(tester.takeException(), isNull);
  });

  test('ADR-143 进行中状态码的状态列文案', () {
    expect(subcontractProgressStatusLabel('FINANCE_REVIEW_PENDING'), '改量待财务复核');
    expect(subcontractProgressStatusLabel('FINANCE_REVIEW_REJECTED'), '改量财务退回');
    expect(subcontractProgressStatusLabel('DRAWABLE'), '可领料·去领料');
    expect(subcontractProgressStatusLabel('DRAW_SUBMITTED'), '已提交领料·待仓库发料');
    expect(subcontractProgressStatusLabel('WAITING_MATERIAL'), '等待物料');
    expect(subcontractProgressStatusLabel('AT_SUPPLIER'), '委外加工中');
    // ADR-143 §二.3：委外件缺 BOM 的申请行等研发完善。
    expect(subcontractProgressStatusLabel('BOM_MISSING'), '缺 BOM·已通知研发');
    // ADR-156：直属物料齐套才解锁下单。
    expect(subcontractProgressStatusLabel('WAITING_KIT'), '等物料齐套');
    expect(subcontractProgressStatusLabel('KIT_PARTIAL'), '可部分下单');
    // 已删除的旧阶段码不再有文案(原样回落)；没有 BOM 的委外件不再走委外商自备料。
    for (final removed in [
      'AWAITING_OUTBOUND',
      'OUTBOUND_WAITING_COMPONENT',
      'WAITING_COMPONENT_STOCK',
      'COMPONENT_STOCK_READY',
      'SUPPLIER_SELF_SUPPLIED',
    ]) {
      expect(subcontractProgressStatusLabel(removed), removed);
    }
    // 待处理段的普通申请行仍不翻译 (沿用「计划申请已下达 / 待分解」)。
    expect(subcontractProgressStatusLabel('WAITING_ORDER'), 'WAITING_ORDER');
  });
}
