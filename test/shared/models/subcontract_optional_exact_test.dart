import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';

void main(){
  test('subcontract optional facts retain server decimal aliases before editor prefill',(){
    const value='9007199254740993.123456789012345678901234';
    final item=SubcontractDocItem.fromJson({
      'id':'line','endingQty':1,'endingQtyExact':value,
      'standardQty':1,'standardQtyExact':value,
      'wasteRate':1,'wasteRateExact':'0.000000000000000000000001',
      'girthQty':1,'girthQtyExact':value,'boxQty':1,'boxQtyExact':value,
    });
    expect(item.endingQtyText,value);expect(item.standardQtyText,value);
    expect(item.wasteRateText,'0.000000000000000000000001');
    expect(item.girthQtyText,value);expect(item.boxQtyText,value);
  });
  test('manual header declaration and suggestion use their own recorded values',(){
    const value='9007199254740993.123456789012345678901234';
    final detail=SubcontractDocDetail.fromJson({
      'id':'doc','items':<dynamic>[],'totalWeight':1,'totalWeightExact':value,
      'deductAmount':1,'deductAmountExact':value,
    });
    expect(detail.totalWeightText,value);expect(detail.deductAmountText,value);
  });
}
