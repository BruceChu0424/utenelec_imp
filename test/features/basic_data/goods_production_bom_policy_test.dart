import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';

void main() {
  test('goods models parse the fixed production BOM policy', () {
    final listItem = GoodsListItem.fromJson({
      'id': 'goods-1',
      'code': 'P-1',
      'productionBomPolicy': 'BOM_REQUIRED',
    });
    final detail = GoodsDetail.fromJson({
      'id': 'goods-1',
      'productionBomPolicy': 'DIRECT_MAKE',
    });

    expect(listItem.productionBomPolicy, 'BOM_REQUIRED');
    expect(detail.productionBomPolicy, 'DIRECT_MAKE');
  });

  test('production BOM policy choices are fixed and exhaustive', () {
    expect(kGoodsProductionBomPolicyOptions.map((option) => option.value), [
      'BOM_REQUIRED',
      'DIRECT_MAKE',
      'NOT_PRODUCED',
    ]);
  });
}
