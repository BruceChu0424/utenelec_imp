import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_line_grid.dart';

void main() {
  const white = WmMaterialOption(
    goodsId: 'pc-e15',
    goodsName: 'PC面板料E-15',
    colorId: 'white',
    colorName: '白色',
    unitName: 'kg',
    warehouseAvailableQty: 100,
    leafWarehouses: [
      WmLeafStock(warehouseId: 'c01', warehouseName: '五金仓库', availableQty: 100),
    ],
  );
  const unspecified = WmMaterialOption(
    goodsId: 'pc-e15',
    goodsName: 'PC面板料E-15',
    unitName: 'kg',
  );

  test('a selected empty leaf cannot borrow the quantity at another leaf', () {
    expect(wmSelectedLeafAvailable(white, 'c01'), 100);
    expect(wmSelectedLeafAvailable(white, 'other'), 0);
    expect(wmSelectedLeafAvailable(white, null), 0);
  });

  test('unspecified color remains distinct from white stock', () {
    expect(white.key, isNot(unspecified.key));
    expect(wmSelectedLeafAvailable(unspecified, 'c01'), 0);
    expect(wmSelectedLeafAvailable(null, 'c01'), 0);
  });
}
