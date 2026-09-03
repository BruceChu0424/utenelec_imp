import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/production_finished_inbound_task.dart';
import 'package:uten_imp/features/warehouse/pages/production_finished_inbound_tasks_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('finished inbound queue uses the multi-select table at 375px', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final api = _FinishedInboundApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.stockDocView,
            Perm.stockDocApprove,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(home: ProductionFinishedInboundTasksPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('产成品入库任务'), findsOneWidget);
    expect(find.text('共 2 项 · 单击多选，双击详情'), findsOneWidget);
    expect(find.text('待登记成品仓与库位'), findsOneWidget);
    expect(find.text('短收余量待点收'), findsOneWidget);
    expect(find.text('SJ202608280001'), findsOneWidget);
    final tableFinder = find.byKey(
      const Key('production-finished-inbound-task-table'),
    );
    var table = tester
        .widget<MasterDataTableView<ProductionFinishedInboundTask>>(
          tableFinder,
        );
    expect(table.selectable, isTrue);
    expect(table.batchActionsBuilder, isNotNull);
    expect(table.columns.map((column) => column.label), [
      '任务步骤',
      '任务单号',
      '生产计划',
      '报工单',
      '货品',
      '仓库',
      '待处理数量',
      '行数',
      '单据日期',
      '进入队列时间',
    ]);
    final actionLabels = [
      for (final item in table.items)
        (table.rowMenuBuilder!(item).single as UtenMenuItem).label,
    ];
    expect(actionLabels, ['登记成品仓和库位', '进入最终点收']);

    await tester.tap(find.text('待登记成品仓与库位'));
    await tester.pump();
    table = tester.widget<MasterDataTableView<ProductionFinishedInboundTask>>(
      tableFinder,
    );
    // 2026-09-03 起待登记任务也可多选（键 reg:<reportId>），进入汇总登记页。
    // 单击行即选中：点步骤单元格会把该登记任务选进 reg: 键。
    expect(
      table.idOf!(table.items.first),
      'reg:20000000-0000-0000-0000-000000000001',
    );
    expect(
      find.byKey(const Key('production-finished-inbound-batch-register')),
      findsOneWidget,
    );
    expect(table.selectedIds, {'reg:20000000-0000-0000-0000-000000000001'});
    await tester.tap(find.text('短收余量待点收'));
    await tester.pump();
    table = tester.widget<MasterDataTableView<ProductionFinishedInboundTask>>(
      tableFinder,
    );
    expect(
      table.idOf!(table.items.last),
      'doc:10000000-0000-0000-0000-000000000001',
    );
    expect(table.selectedIds, {
      'reg:20000000-0000-0000-0000-000000000001',
      'doc:10000000-0000-0000-0000-000000000001',
    });
    final batchButton = find.byKey(
      const Key('production-finished-inbound-batch-confirm'),
    );
    expect(batchButton, findsOneWidget);
    await tester.tap(batchButton);
    await tester.pumpAndSettle();
    expect(find.text('批量全量点收 1 张'), findsOneWidget);
    await tester.tap(find.text('确认批量入库'));
    await tester.pumpAndSettle();

    expect(api.batchBody?['documentIds'], [
      '10000000-0000-0000-0000-000000000001',
    ]);
    expect(api.batchBody?['idempotencyKey'], startsWith('finished-in-batch-'));
    expect(find.text('短收余量待点收'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('finished inbound queue gives view-only staff no count promise', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(_FinishedInboundApi()),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.stockDocView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(home: ProductionFinishedInboundTasksPage()),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester
        .widget<MasterDataTableView<ProductionFinishedInboundTask>>(
          find.byKey(const Key('production-finished-inbound-task-table')),
        );
    final actionLabels = [
      for (final item in table.items)
        (table.rowMenuBuilder!(item).single as UtenMenuItem).label,
    ];
    expect(actionLabels, ['查看到货登记详情', '查看待点收详情']);
    expect(table.selectable, isFalse);
    expect(table.batchActionsBuilder, isNull);
    expect(tester.takeException(), isNull);
  });
}

class _FinishedInboundApi extends ApiClient {
  _FinishedInboundApi() : super(Dio());

  Map<String, dynamic>? batchBody;
  bool batchConfirmed = false;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/count')) return const {'count': 2};
    return {
      'items': [
        const {
          'taskStage': 'ARRIVAL_REGISTRATION',
          'taskId': '20000000-0000-0000-0000-000000000001',
          'reportId': '20000000-0000-0000-0000-000000000001',
          'documentId': null,
          'documentNo': null,
          'documentDate': '2026-08-28',
          'warehouseId': null,
          'warehouseName': null,
          'planId': '20000000-0000-0000-0000-000000000003',
          'planNo': 'SJ202608270001',
          'reportNos': 'RB202608280001',
          'goodsSummary': 'V5多功能三极插座E极插套(酸洗)',
          'lineCount': 1,
          'pendingQty': 1000,
          'createdAt': '2026-08-28T04:00:00Z',
          'residualTask': false,
        },
        if (!batchConfirmed)
          const {
            'taskStage': 'FINAL_COUNT',
            'taskId': '10000000-0000-0000-0000-000000000001',
            'reportId': '20000000-0000-0000-0000-000000000001',
            'documentId': '10000000-0000-0000-0000-000000000001',
            'documentNo': 'CPRK202608280001',
            'documentDate': '2026-08-28',
            'warehouseId': '10000000-0000-0000-0000-000000000002',
            'warehouseName': '半成品仓',
            'planId': '10000000-0000-0000-0000-000000000003',
            'planNo': 'SJ202608280001',
            'reportNos': 'RB202608280001',
            'goodsSummary': 'V5多功能三极插座E极插套(酸洗)',
            'lineCount': 1,
            'pendingQty': 1000,
            'createdAt': '2026-08-28T05:00:00Z',
            'residualTask': true,
          },
      ],
      'page': 1,
      'size': 40,
      'total': batchConfirmed ? 1 : 2,
      'totalPages': 1,
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    expect(path, ApiEndpoints.productionFinishedInboundBatchConfirm);
    batchBody = Map<String, dynamic>.from(body! as Map<String, dynamic>);
    batchConfirmed = true;
    return {
      'batchId': 'batch-1',
      'replay': false,
      'confirmedCount': 1,
      'items': [
        {
          'documentId': '10000000-0000-0000-0000-000000000001',
          'billNo': 'CPRK202608280001',
          'status': 1,
        },
      ],
    };
  }
}
