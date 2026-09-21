// ADR-098 委外任务中心：三段（待处理/进行中/历史记录）、进行中查询 status=IN_PROGRESS、
// 状态列按 displayStage 上色并给回厂短交待判定加「紧急」标签、异常小类行挂短交/退回。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_decomposition_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

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
    final items = status == 'IN_PROGRESS'
        ? [
            _order(
              'o-short',
              'FINANCE_APPROVED',
              'SHORT_DELIVERY',
              'SHORT_DELIVERY',
            ),
            _order('o-supplier', 'FINANCE_APPROVED', 'AT_SUPPLIER', null),
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
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {
            Perm.subcontractApplicationView,
            Perm.subcontractOrderView,
          }),
          apiClientProvider.overrideWithValue(_Api()),
        ],
        child: MaterialApp(
          home: SubcontractDecompositionPage(repository: gateway),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('待处理'), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('历史记录'), findsOneWidget);
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
    // 异常小类行：短交与退回都在（红徽章形态由 UtenFilterSegment 决定）。
    expect(
      find.byKey(const Key('subcontract-decomposition-exceptions')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
