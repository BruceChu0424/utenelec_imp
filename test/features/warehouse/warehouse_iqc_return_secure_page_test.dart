import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_return.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_iqc_return_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_iqc_return_page.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_iqc_return_repository.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  final task = WarehouseIqcReturnTask.fromJson(_taskJson);

  test('warehouse IQC parser, routes, and command stay physical-only', () {
    expect(task.canRecordReturn, isTrue);
    expect(requiredAnyPermFor(RouteName.warehouseIqcReturns), <String>[
      Perm.warehouseIqcReturnView,
    ]);
    expect(
      requiredAnyPermFor(RoutePath.warehouseIqcReturnDetail('case-1')),
      <String>[Perm.warehouseIqcReturnView],
    );
    expect(
      pagePermissionScopeFor(
        RoutePath.warehouseIqcReturnDetail('case-1'),
      )?.surfaceKey,
      'warehouse.iqc-return',
    );
    final command = const WarehouseIqcRecordReturnCommand(
      expectedVersion: 3,
      commandId: '00000000-0000-4000-8000-000000000001',
      returnReference: ' RET-001 ',
      returnDate: '2026-08-31',
      returnNote: ' 已交接 ',
    ).toJson();
    expect(command['expectedVersion'], 3);
    expect(command['returnReference'], 'RET-001');
    expect(command['returnNote'], '已交接');

    final source = File(
      'lib/features/warehouse/models/warehouse_iqc_return.dart',
    ).readAsStringSync();
    for (final key in warehouseIqcReturnForbiddenKeys) {
      expect(
        source,
        isNot(contains("json['$key']")),
        reason: 'warehouse IQC parser must ignore $key',
      );
    }
    final hubSource = File(
      'lib/features/warehouse/pages/warehouse_hub_page.dart',
    ).readAsStringSync();
    expect(hubSource, contains('RouteName.warehouseIqcReturns'));
    expect(hubSource, contains('Perm.warehouseIqcReturnView'));
    expect(hubSource, isNot(contains('RoutePath.procurementIqcRejections')));
  });

  testWidgets('warehouse IQC list and detail expose return facts only', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 850));
    final gateway = _IqcGateway(task);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warehouseIqcReturnRepositoryProvider.overrideWithValue(gateway),
          currentPermissionsProvider.overrideWithValue({
            Perm.procurementIqcRejectionRecordReturn,
          }),
        ],
        child: const MaterialApp(home: WarehouseIqcReturnPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('IQC 不合格实物退回'), findsOneWidget);
    expect(find.text('CJ-001'), findsOneWidget);
    expect(find.textContaining('不包含商业或财务'), findsOneWidget);
    expect(find.textContaining('贷项'), findsNothing);
    expect(find.textContaining('金额'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warehouseIqcReturnRepositoryProvider.overrideWithValue(gateway),
          currentPermissionsProvider.overrideWithValue({
            Perm.procurementIqcRejectionRecordReturn,
          }),
        ],
        child: MaterialApp(
          home: WarehouseIqcReturnDetailPage(id: 'case-1', repository: gateway),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('IQC 实物退回详情'), findsOneWidget);
    expect(find.text('登记实物退回'), findsOneWidget);
    expect(find.textContaining('贷项'), findsNothing);
    expect(find.textContaining('金额'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });
}

const _taskJson = <String, dynamic>{
  'id': 'case-1',
  'receiptType': 'PURCHASE',
  'receiptBillNo': 'CJ-001',
  'orderBillNo': 'CD-001',
  'supplierName': '供应商甲',
  'warehouseName': '一号仓',
  'goodsCode': 'G-001',
  'goodsName': '货品甲',
  'colorName': '本色',
  'unitName': '件',
  'failedBaseQuantity': '10.0000',
  'failedQuantity': '10.0000',
  'inspectionStatus': 'RESOLVED',
  'physicalReturnStatus': 'PENDING_RETURN',
  'version': 3,
  'allowedActions': <String>['RECORD_RETURN'],
  'failedAmountLocal': 9999,
  'currencyCode': 'CNY',
  'creditReference': 'SECRET-CREDIT',
};

class _IqcGateway implements WarehouseIqcReturnGateway {
  _IqcGateway(this.value);

  final WarehouseIqcReturnTask value;

  @override
  Future<PagedResult<WarehouseIqcReturnTask>> list({
    int page = 1,
    int size = 20,
    WarehouseIqcReceiptType? receiptType,
    String? physicalStatus,
    String? keyword,
  }) async => PagedResult(
    items: [value],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );

  @override
  Future<WarehouseIqcReturnTask> detail(String id) async => value;

  @override
  Future<WarehouseIqcReturnTask> recordReturn(
    String id,
    WarehouseIqcRecordReturnCommand command,
  ) async => value;
}
