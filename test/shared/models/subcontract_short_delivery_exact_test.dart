import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/subcontract_short_delivery.dart';
import 'package:uten_imp/features/basic_data/models/supplier_node.dart';

void main(){
  test('case displays the original decimal aliases, including a finite 50-place threshold',(){
    final row=SubcontractShortDeliveryCase.fromJson({
      'id':'case','orderedQty':9007199254740992,'orderedQtyExact':'9007199254740993.123456789012345678901234',
      'floorQty':1e-24,'floorQtyExact':'0.00000000000000000000000099999999999999999999999999',
      'shortfallQty':1e-24,'shortfallQtyExact':'0.000000000000000000000001',
      'shortfallPct':0.33,'shortfallPctExact':'0.333333333333333333333333',
    });
    expect(formatSubcontractQty(row.orderedQtyValue),'9007199254740993.123456789012345678901234');
    expect(formatSubcontractQty(row.floorQtyValue),'0.00000000000000000000000099999999999999999999999999');
    expect(formatSubcontractQty(row.shortfallQtyValue),'0.000000000000000000000001');
    expect(formatSubcontractPct(row.shortfallPctValue),'0.333333333333333333333333%');
  });
  test('a missing case quantity remains unknown',(){
    final row=SubcontractShortDeliveryCase.fromJson({'id':'missing'});
    expect(formatSubcontractQty(row.orderedQtyValue),'—');
    expect(formatSubcontractPct(row.shortfallPctValue),'—');
  });
  test('supplier summaries and supplier table retain the same exact percent',(){
    const raw='33.333333333333333333333333';
    final summary=SubcontractSupplierLossSummary.fromJson({'supplierId':'s','lossPct':33.33,'lossPctExact':raw});
    final supplier=SupplierListItem.fromJson({'id':'s','lossRate':33.33,'lossRateExact':raw});
    expect(formatSubcontractPct(summary.lossPctValue),'$raw%');
    expect(supplier.lossRateText,raw);
    final goods=SubcontractGoodsLossRow.fromJson({'goodsId':'g','maxLossPct':33.33,'maxLossPctExact':raw});
    expect(formatSubcontractPct(goods.maxLossPctValue),'$raw%');
  });
}
