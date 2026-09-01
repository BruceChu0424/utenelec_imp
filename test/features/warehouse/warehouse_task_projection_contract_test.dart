import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_return.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_sales_outbound.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_iqc_return_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_sales_outbound_repository.dart';

void main() {
  test('warehouse sales projection ignores every commercial key', () {
    final detail = WarehouseSalesOutboundDetail.fromJson(_salesJson);
    expect(detail.header.billNo, 'XS-001');
    expect(detail.header.statusLabel, '待拣货');
    expect(detail.lines.single.quantity, '10.0000');
    expect(detail.lines.single.currentStockPlaceHint, 'A01-01');

    final source = File(
      'lib/features/warehouse/models/warehouse_sales_outbound.dart',
    ).readAsStringSync();
    for (final key in warehouseSalesOutboundForbiddenKeys) {
      expect(source, isNot(contains("json['$key']")));
    }
  });

  test(
    'warehouse IQC projection ignores amount and downstream finance keys',
    () {
      final task = WarehouseIqcReturnTask.fromJson(_iqcJson);
      expect(task.goodsLabel, 'G-001 · 拒收产品');
      expect(task.failedQuantity, '2.0000');
      expect(task.statusLabel, '待登记实物退回');
      expect(task.canRecordReturn, isTrue);

      final source = File(
        'lib/features/warehouse/models/warehouse_iqc_return.dart',
      ).readAsStringSync();
      for (final key in warehouseIqcReturnForbiddenKeys) {
        expect(source, isNot(contains("json['$key']")));
      }
    },
  );

  test(
    'dedicated repositories use warehouse endpoints and safe commands',
    () async {
      final api = _TaskApi();
      final sales = WarehouseSalesOutboundRepository(api);
      final iqc = WarehouseIqcReturnRepository(api);

      await sales.list(
        page: 2,
        keyword: ' XS ',
        warehouseWorkStatus: WarehouseSalesOutboundStatus.picking,
      );
      expect(api.lastPath, '/warehouse/sales-outbound');
      expect(api.lastQuery, containsPair('warehouseWorkStatus', 'PICKING'));
      await sales.transition(
        'sales-1',
        targetStatus: WarehouseSalesOutboundStatus.exception,
        reason: '  包装破损  ',
      );
      expect(api.lastPath, '/warehouse/sales-outbound/sales-1/warehouse-work');
      expect(api.lastBody, <String, dynamic>{
        'targetStatus': 'EXCEPTION',
        'reason': '包装破损',
      });

      await iqc.recordReturn(
        'iqc-1',
        const WarehouseIqcRecordReturnCommand(
          expectedVersion: 3,
          commandId: '11111111-1111-4111-8111-111111111111',
          returnReference: ' RET-001 ',
          returnDate: '2026-08-31',
          returnNote: ' 已交承运人 ',
        ),
      );
      expect(api.lastPath, '/warehouse/iqc-returns/iqc-1/record-return');
      expect(api.lastBody, containsPair('returnReference', 'RET-001'));
      expect(api.lastBody, containsPair('returnNote', '已交承运人'));
    },
  );
}

const Map<String, dynamic> _salesJson = <String, dynamic>{
  'id': 'sales-1',
  'billNo': 'XS-001',
  'billDate': '2026-08-31',
  'clientName': '示例客户',
  'warehouseName': '成品仓',
  'warehouseWorkStatus': 'PENDING_PICK',
  'allowedWarehouseTargets': ['PICKING', 'EXCEPTION'],
  'shipAddress': '收货地址',
  'contactPhone': '13800000000',
  'totalLocal': '999999.99',
  'currencyCode': 'USD-SECRET',
  'lines': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'line-1',
      'lineNumber': 1,
      'goodsCode': 'G-001',
      'goodsName': '实物产品',
      'currentStockPlaceHint': 'A01-01',
      'unitName': '件',
      'quantity': '10.0000',
      'unitPrice': '100.00',
      'amountLocal': '1000.00',
    },
  ],
};

const Map<String, dynamic> _iqcJson = <String, dynamic>{
  'id': 'iqc-1',
  'receiptType': 'PURCHASE',
  'receiptBillNo': 'PR-001',
  'orderBillNo': 'PO-001',
  'supplierName': '示例供应商',
  'warehouseName': '一号仓',
  'goodsCode': 'G-001',
  'goodsName': '拒收产品',
  'unitName': '件',
  'failedBaseQuantity': '2.0000',
  'failedQuantity': '2.0000',
  'inspectionStatus': 'RESOLVED',
  'physicalReturnStatus': 'PENDING_RETURN',
  'version': 3,
  'allowedActions': ['RECORD_RETURN'],
  'failedAmountLocal': '9999.99',
  'currencyCode': 'USD-SECRET',
  'creditReference': 'CREDIT-SECRET',
  'financeExceptionMessage': 'SECRET',
};

class _TaskApi extends ApiClient {
  _TaskApi() : super(Dio());

  String? lastPath;
  Map<String, dynamic>? lastQuery;
  Object? lastBody;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    lastPath = path;
    lastQuery = query;
    final row = path.contains('iqc-returns') ? _iqcJson : _salesJson;
    if (query == null) return row;
    return <String, dynamic>{
      'items': [row],
      'page': query['page'] ?? 1,
      'size': query['size'] ?? 20,
      'total': 1,
      'totalPages': 1,
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    lastPath = path;
    lastBody = body;
    return path.contains('iqc-returns') ? _iqcJson : _salesJson;
  }
}
