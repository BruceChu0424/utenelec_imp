import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/inbound_allocation.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/widgets/warehouse_picker_panel.dart';

void main() {
  const hierarchy = [
    WarehouseDictEntry(id: 'main', name: '主仓'),
    WarehouseDictEntry(id: 'plastics', name: '塑料仓', parentId: 'main'),
    WarehouseDictEntry(id: 'hardware', name: '五金仓', parentId: 'main'),
    WarehouseDictEntry(id: 'other', name: '异地主仓'),
  ];
  const source = [
    WarehouseInboundAllocation(
      kind: WarehouseInboundAllocationKind.exactAnalysis,
      qty: 10,
      targetWarehouseId: 'plastics',
      analysisId: 'analysis',
      analysisMaterialId: 'material',
    ),
  ];
  bool sameMain(String? left, String right) =>
      warehousesShareMain(hierarchy, left, right);

  test('同主仓不同子仓保留本物料归属与实际入库仓', () {
    final rows = warehouseInboundAllocationForWarehouse(
      source,
      3,
      actualWarehouseId: 'hardware',
      sameMainWarehouse: sameMain,
      unitRate: 2,
    );
    expect(rows.single.qty, 6);
    expect(rows.single.kind, WarehouseInboundAllocationKind.exactAnalysis);
    expect(rows.single.analysisMaterialId, 'material');
    expect(rows.single.actualWarehouseId, 'hardware');
    expect(rows.single.isCrossWarehouse, isFalse);
  });

  test('不同主仓仍提示公共入库并保留来源记录', () {
    final row = warehouseInboundAllocationForWarehouse(
      source,
      5,
      actualWarehouseId: 'other',
      sameMainWarehouse: sameMain,
    ).single;
    expect(row.kind, WarehouseInboundAllocationKind.publicStock);
    expect(row.isCrossWarehouse, isTrue);
    expect(row.targetWarehouseId, 'plastics');
    expect(row.actualWarehouseId, 'other');
  });

  test('仓库缺失或异常层级不能将两个不同子仓归为同仓', () {
    expect(warehousesShareMain(hierarchy, 'missing', 'hardware'), isFalse);
    expect(
      warehousesShareMain(
        const [
          WarehouseDictEntry(id: 'a', name: 'A', parentId: 'b'),
          WarehouseDictEntry(id: 'b', name: 'B', parentId: 'a'),
        ],
        'a',
        'b',
      ),
      isFalse,
    );
  });

  test('每个物料最近成功收货仓随预计到货传到登记预填', () {
    final expectation = InboundExpectation.fromJson({
      'id': 'expectation',
      'orderType': 'PURCHASE',
      'orderId': 'order',
      'billNo': 'PO-1',
      'status': 'OPEN',
      'supplierId': 'supplier',
      'orderedQty': 2,
      'remainingQty': 2,
      'allowedActions': ['CREATE_PURCHASE_RECEIPT'],
      'items': [
        {
          'id': 'i1',
          'orderItemId': 'o1',
          'goodsId': 'g1',
          'goodsCode': 'G1',
          'goodsName': '塑料件',
          'remainingQty': 1,
          'lastReceiptWarehouseId': 'plastics',
        },
        {
          'id': 'i2',
          'orderItemId': 'o2',
          'goodsId': 'g2',
          'goodsCode': 'G2',
          'goodsName': '五金件',
          'remainingQty': 1,
          'lastReceiptWarehouseId': 'hardware',
        },
      ],
    });
    expect(
      expectation.toReceiptPrefill()!.items.map(
        (item) => item.lastReceiptWarehouseId,
      ),
      ['plastics', 'hardware'],
    );
  });
}
