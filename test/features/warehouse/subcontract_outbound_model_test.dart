import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/models/subcontract_outbound.dart';

void main() {
  test('计划行解析并回传服务端权威颜色和单位 UUID', () {
    final line = OutboundPlanLine.fromJson({
      'planItemId': 'plan-item-1',
      'orderItemId': 'order-item-1',
      'parentGoodsId': 'parent-goods-1',
      'parentColorId': 'parent-color-1',
      'parentGoodsCode': 'P001',
      'parentGoodsName': '父件',
      'goodsId': 'goods-1',
      'goodsCode': 'G001',
      'goodsName': '子件',
      'goodsStockPlace': 'A-01',
      'colorId': 'color-1',
      'colorName': '黑色',
      'unitId': 'unit-1',
      'unitName': '个',
      'bomUnitQty': 2,
      'plannedQty': 20,
      'issuedQty': 4,
      'draftQty': 6,
    });

    expect(line.colorId, 'color-1');
    expect(line.unitId, 'unit-1');
    expect(line.toMaterialIssueItemPayload(qty: 5), {
      'goodsId': 'goods-1',
      'colorId': 'color-1',
      'unitId': 'unit-1',
      'qty': 5,
      'unitRate': 1,
      'orderItemId': 'order-item-1',
      'planItemId': 'plan-item-1',
      'parentGoodsId': 'parent-goods-1',
      'parentColorId': 'parent-color-1',
    });
  });

  test('无颜色和单位的计划行也显式回传空 UUID', () {
    final line = OutboundPlanLine.fromJson({
      'planItemId': 'plan-item-2',
      'orderItemId': 'order-item-2',
      'goodsId': 'goods-2',
    });

    expect(
      line.toMaterialIssueItemPayload(qty: 3),
      containsPair('colorId', null),
    );
    expect(
      line.toMaterialIssueItemPayload(qty: 3),
      containsPair('unitId', null),
    );
  });

  test('未知新流模式 fail closed，不得按历史发料行放行', () {
    final line = OutboundPlanLine.fromJson({
      'planItemId': 'plan-item-future',
      'orderItemId': 'order-item-future',
      'goodsId': 'goods-future',
      'flowMode': 'FUTURE_UNRECOGNIZED_MODE',
      'preparationStatus': 'READY_OUTBOUND',
      'plannedQty': 10,
      'readyOutboundQty': 10,
      'draftReservedQty': 2,
    });

    expect(line.flowMode, SubcontractOutboundFlowMode.unknown);
    expect(line.readyOutboundQty, 0);
    expect(line.maxEditableQty, 0);
  });
}
