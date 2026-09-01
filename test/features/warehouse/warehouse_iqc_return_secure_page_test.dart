import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_return.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  final task = WarehouseIqcReturnTask.fromJson(_taskJson);

  test('warehouse IQC parser, routes, and command stay physical-only', () {
    expect(task.canRecordReturn, isTrue);
    expect(requiredAnyPermFor(RouteName.warehouseIqcReturns), <String>[
      Perm.warehouseIqcReturnView,
    ]);
    // 旧退回详情深链（按案件 id，现重定向到合并列表）仍按原路径鉴权与映射权限面。
    expect(
      requiredAnyPermFor('${RouteName.warehouseIqcReturns}/case-1'),
      <String>[Perm.warehouseIqcReturnView],
    );
    expect(
      pagePermissionScopeFor('${RouteName.warehouseIqcReturns}/case-1')
          ?.surfaceKey,
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
    // 2026-09-01 合并后：仓库 hub 只保留「品质部检查结果」一张卡，
    // 旧的退回列表入口重定向到合并页，不再单独露卡。
    final hubSource = File(
      'lib/features/warehouse/pages/warehouse_hub_page.dart',
    ).readAsStringSync();
    expect(hubSource, contains('RouteName.warehouseQualityResults'));
    expect(hubSource, contains('WarehouseQualityResultBadge'));
    expect(hubSource, isNot(contains('RoutePath.procurementIqcRejections')));
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
