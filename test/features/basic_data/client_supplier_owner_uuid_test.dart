import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';
import 'package:uten_imp/features/basic_data/models/supplier_node.dart';

void main() {
  test('client detail keeps employee UUID and display name', () {
    final detail = ClientDetail.fromJson(const {
      'id': 'client-uuid',
      'ownerEmployeeId': 'employee-uuid',
      'ownerEmployeeName': '王业务',
      'empId': '17',
      'version': 4,
    });

    expect(detail.ownerEmployeeId, 'employee-uuid');
    expect(detail.ownerEmployeeName, '王业务');
    expect(detail.empId, '17');
    expect(detail.version, 4);
  });

  test('supplier detail keeps employee UUID and display name', () {
    final detail = SupplierDetail.fromJson(const {
      'id': 'supplier-uuid',
      'ownerEmployeeId': 'employee-uuid',
      'ownerEmployeeName': '李业务',
      'empId': '23',
      'version': 6,
    });

    expect(detail.ownerEmployeeId, 'employee-uuid');
    expect(detail.ownerEmployeeName, '李业务');
    expect(detail.empId, '23');
    expect(detail.version, 6);
  });
}
