import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/warehouse_node.dart';

void main() {
  test('workshop option is a UUID-backed minimal warehouse dictionary row', () {
    final option = WarehouseWorkshopOption.fromJson(const {
      'id': 'workshop-department-uuid',
      'code': 'WS_ZHUSU',
      'name': '注塑车间',
    });

    expect(option.id, 'workshop-department-uuid');
    expect(option.code, 'WS_ZHUSU');
    expect(option.name, '注塑车间');
  });

  test('warehouse parses workshop UUID truth and legacy operator snapshot', () {
    final warehouse = WarehouseDetail.fromJson(const {
      'id': 'warehouse-uuid',
      'workshopDepartmentId': 'workshop-department-uuid',
      'workshopDepartmentName': '注塑车间',
      'legacyOperatorId': 135,
      'workshopLegacyId': 999,
    });

    expect(warehouse.workshopDepartmentId, 'workshop-department-uuid');
    expect(warehouse.workshopDepartmentName, '注塑车间');
    expect(warehouse.legacyOperatorId, 135);
  });

  test('older payload alias remains readable as operator snapshot only', () {
    final warehouse = WarehouseListItem.fromJson(const {
      'id': 'warehouse-uuid',
      'workshopLegacyId': 174,
    });

    expect(warehouse.workshopDepartmentId, isNull);
    expect(warehouse.legacyOperatorId, 174);
  });
}
