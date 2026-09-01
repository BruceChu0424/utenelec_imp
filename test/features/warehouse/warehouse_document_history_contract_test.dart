import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/features/warehouse/config/warehouse_document_history_config.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_document_history.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_document_history_repository.dart';

void main() {
  test('all six warehouse history types use stable dedicated segments', () {
    expect(
      WarehouseDocumentHistoryType.values.map((type) => type.segment),
      <String>[
        'purchase-receipts',
        'subcontract-receipts',
        'subcontract-material-issues',
        'subcontract-returns',
        'subcontract-material-returns',
        'subcontract-wastes',
      ],
    );
    for (final type in WarehouseDocumentHistoryType.values) {
      expect(WarehouseDocumentHistoryType.tryParse(type.segment), type);
      expect(type.listPath(), '/warehouse/history/${type.segment}');
    }
  });

  test('list and detail routes keep exact permission and page surface', () {
    final expected = <WarehouseDocumentHistoryType, (String, String)>{
      WarehouseDocumentHistoryType.purchaseReceipt: (
        Perm.warehousePurchaseReceiptHistoryView,
        'warehouse.purchase-receipt-history',
      ),
      WarehouseDocumentHistoryType.subcontractReceipt: (
        Perm.warehouseSubcontractReceiptHistoryView,
        'warehouse.subcontract-receipt-history',
      ),
      WarehouseDocumentHistoryType.subcontractMaterialIssue: (
        Perm.warehouseSubcontractOutboundHistoryView,
        'warehouse.subcontract-outbound-history',
      ),
      WarehouseDocumentHistoryType.subcontractReturn: (
        Perm.warehouseSubcontractFinishedReturnHistoryView,
        'warehouse.subcontract-finished-return-history',
      ),
      WarehouseDocumentHistoryType.subcontractMaterialReturn: (
        Perm.warehouseSubcontractMaterialReturnHistoryView,
        'warehouse.subcontract-material-return-history',
      ),
      WarehouseDocumentHistoryType.subcontractWaste: (
        Perm.warehouseSubcontractWasteHistoryView,
        'warehouse.subcontract-waste-history',
      ),
    };

    for (final entry in expected.entries) {
      final listPath = entry.key.listPath();
      final detailPath = entry.key.detailPath('doc-1');
      expect(requiredAnyPermFor(listPath), <String>[entry.value.$1]);
      expect(requiredAnyPermFor(detailPath), <String>[entry.value.$1]);
      expect(pagePermissionScopeFor(listPath)?.surfaceKey, entry.value.$2);
      expect(pagePermissionScopeFor(detailPath)?.surfaceKey, entry.value.$2);
      expect(
        pagePermissionScopeBySurfaceKey(entry.value.$2)?.surfaceKey,
        entry.value.$2,
      );
    }
  });

  test(
    'detail parser keeps physical precision and ignores commercial extras',
    () {
      final detail = WarehouseDocumentHistoryDetail.fromJson(
        WarehouseDocumentHistoryType.purchaseReceipt,
        _detailJson,
      );

      expect(detail.header.sourceDocNo, 'PO-001');
      expect(detail.header.itemCount, 1);
      expect(detail.header.makerName, '仓管甲');
      expect(detail.items, hasLength(1));
      final line = detail.items.single;
      expect(line.lineNo, 1);
      expect(line.qty, '10.1250');
      expect(line.returnedQty, '1.0000');
      expect(line.passedBaseQty, '9.0000');
      expect(line.failedBaseQty, '1.1250');
      expect(line.inspectionStatus, 'PARTIAL');
      expect(line.sourceDocNo, 'PO-001');
      expect(line.parentGoodsName, '父件 A');

      final source = File(
        'lib/features/warehouse/models/warehouse_document_history.dart',
      ).readAsStringSync();
      for (final key in <String>{
        ...warehouseHistoryForbiddenCommercialKeys,
        'totalQuantity',
        'totalWeight',
      }) {
        expect(
          source,
          isNot(contains("json['$key']")),
          reason: 'warehouse parser must not retain commercial key $key',
        );
      }
    },
  );

  test(
    'repository sends normalized paging/search/status to the exact endpoint',
    () async {
      final api = _HistoryApi();
      final repository = WarehouseDocumentHistoryRepository(
        api,
        WarehouseDocumentHistoryType.subcontractMaterialReturn,
      );

      final result = await repository.list(
        page: 0,
        size: 999,
        keyword: '  G-001  ',
        status: ' 1 ',
      );

      expect(
        api.lastPath,
        '/warehouse/document-history/subcontract-material-returns',
      );
      expect(api.lastQuery, <String, dynamic>{
        'page': 1,
        'size': 100,
        'keyword': 'G-001',
        'status': '1',
      });
      expect(result.items.single.displayBillNo, 'WH-001');

      await repository.detail(' id/with space ');
      expect(
        api.lastPath,
        '/warehouse/document-history/subcontract-material-returns/'
        'id%2Fwith%20space',
      );
    },
  );
}

const Map<String, dynamic> _detailJson = <String, dynamic>{
  'id': 'history-1',
  'type': 'PURCHASE_RECEIPT',
  'billNo': 'WH-001',
  'billDate': '2026-08-31',
  'supplierName': '示例供应商',
  'warehouseName': '一号仓',
  'status': 1,
  'closed': false,
  'sourceDocumentNo': 'PO-001',
  'lineCount': 1,
  'totalQuantity': '10.1250',
  'totalWeight': '25.5000',
  'makerName': '仓管甲',
  'approverName': '仓管乙',
  'remark': '外箱完好',
  'createdAt': '2026-08-31T08:30:00+08:00',
  'currencyId': 'USD-SECRET',
  'exchangeRate': '7.1234',
  'taxRate': '13',
  'settlementMethodId': 'settlement-secret',
  'totalLocal': '999999.99',
  'apPosted': true,
  'claimAmount': '8888.88',
  'lines': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'line-1',
      'lineNumber': 1,
      'goodsId': 'goods-1',
      'goodsCode': 'G-001',
      'goodsName': '实物产品',
      'stockPlace': 'A01-01',
      'colorName': '本色',
      'unitName': '件',
      'quantity': '10.1250',
      'weight': '25.5000',
      'returnedQuantity': '1.0000',
      'iqcPassedBaseQuantity': '9.0000',
      'iqcFailedBaseQuantity': '1.1250',
      'iqcStatus': 'PARTIAL',
      'referenceDocumentNo': 'PO-001',
      'parentGoodsCode': 'P-001',
      'parentGoodsName': '父件 A',
      'unitPrice': '12345.67',
      'amountLocal': '999999.99',
    },
  ],
};

class _HistoryApi extends ApiClient {
  _HistoryApi() : super(Dio());

  String? lastPath;
  Map<String, dynamic>? lastQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    lastPath = path;
    lastQuery = query;
    if (query == null) return _detailJson;
    return <String, dynamic>{
      'items': <Map<String, dynamic>>[
        Map<String, dynamic>.from(_detailJson)..remove('lines'),
      ],
      'page': 1,
      'size': 100,
      'total': 1,
      'totalPages': 1,
    };
  }
}
