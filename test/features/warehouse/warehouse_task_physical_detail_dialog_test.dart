import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_center_record.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_task_physical_detail_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

final _actor = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'actor-a'),
);
final _server = StateProvider<String>((ref) => 'https://warehouse.test/api');
final _warehouse = StateProvider<WarehouseTaskScope>(
  (ref) => const WarehouseTaskScope.warehouse('warehouse-a'),
);

const _row = WarehouseTaskCenterRecord(
  rowKey: 'OTHER:STOCK_DOC:original-id:item-id',
  id: 'original-id',
  sourceType: 'OTHER',
  recordType: 'STOCK_DOC',
  status: 'OTHER_REVERSED',
  statusLabel: '其它出库 · 已撤回',
  action: 'HISTORY_DETAIL',
  billNo: 'ORIGINAL-OUT',
  actionData: {'docType': 'OTHER_OUT'},
  line: WarehouseTaskLine(key: 'item-id', itemId: 'item-id'),
);

class _Api extends ApiClient {
  _Api() : super(Dio());
  Completer<Map<String, dynamic>>? pending;
  final calls = <({String path, Map<String, dynamic> query})>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!path.startsWith('/warehouse/task-center/')) return {};
    calls.add((path: path, query: {...?query}));
    if (pending != null) return pending!.future;
    final page = query?['linePage'] as int? ?? 1;
    return {
      'page': page,
      'size': 100,
      'total': 101,
      'totalPages': 2,
      'lines': [
        {
          'goodsCode': 'PHYSICAL-$page',
          'goodsName': '物料$page',
          'quantity': page == 1 ? 7 : 3,
          'unitName': '个',
          'price': 'PRIVATE-PRICE',
          'amount': 'PRIVATE-AMOUNT',
        },
      ],
    };
  }
}

Widget _app(_Api api) => ProviderScope(
  overrides: [
    apiClientProvider.overrideWithValue(api),
    authenticatedScopeProvider.overrideWith((ref) => ref.watch(_actor)),
    apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
    warehouseTaskScopeProvider.overrideWith((ref) => ref.watch(_warehouse)),
    currentPermissionsProvider.overrideWithValue({Perm.stockDocView}),
  ],
  child: const MaterialApp(
    home: Scaffold(
      body: WarehouseTaskPhysicalDetailDialog(
        row: _row,
        warehouseScope: WarehouseTaskScope.warehouse('warehouse-a'),
      ),
    ),
  ),
);

void main() {
  testWidgets('其它出库撤回详情仍走出库范围端点，全部明细可翻页且只显示物理字段', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _Api();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    expect(
      api.calls.single.path,
      '/warehouse/task-center/outbound/OTHER%3ASTOCK_DOC%3Aoriginal-id/detail',
    );
    expect(api.calls.single.query['scopeWarehouseId'], 'warehouse-a');
    expect(find.text('PHYSICAL-1'), findsOneWidget);
    expect(
      find.byType(MasterDataTableView<Map<String, dynamic>>),
      findsOneWidget,
    );
    expect(find.byType(DataTable), findsNothing);
    expect(find.textContaining('PRIVATE'), findsNothing);
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
    expect(api.calls.last.query['linePage'], 2);
    expect(find.text('PHYSICAL-1'), findsNothing);
    expect(find.text('PHYSICAL-2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final change in ['actor', 'server', 'warehouse']) {
    testWidgets('详情等待时切换$change立即清理旧身份，迟到物料不恢复', (tester) async {
      final api = _Api()..pending = Completer<Map<String, dynamic>>();
      await tester.pumpWidget(_app(api));
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WarehouseTaskPhysicalDetailDialog)),
      );
      switch (change) {
        case 'actor':
          container.read(_actor.notifier).state = const AuthenticatedScope(
            userId: 'actor-b',
          );
        case 'server':
          container.read(_server.notifier).state = 'https://other.test/api';
        case 'warehouse':
          container.read(_warehouse.notifier).state =
              const WarehouseTaskScope.warehouse('warehouse-b');
      }
      await tester.pump();
      expect(find.text('其它出库 · 已撤回'), findsNothing);
      api.pending!.complete({
        'items': [
          {'goodsName': 'OLD-PRIVATE-GOODS', 'acceptedQty': 8},
        ],
      });
      await tester.pumpAndSettle();
      expect(find.text('OLD-PRIVATE-GOODS'), findsNothing);
      expect(find.textContaining('已变化'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
