import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/employee/pages/employee_edit_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  const payload = <String, dynamic>{
    'fullName': '张三',
    'phone': '13800138000',
    'bankAccount': '6222000000000000',
    'baseSalary': '12000',
    'housingFundBase': '12000',
  };

  test('sensitive employee edits fail closed without field permissions', () {
    final filtered = filterEmployeeEditPayloadForPermissions(payload, const {
      Perm.employeeEdit,
    });

    expect(filtered, const {'fullName': '张三'});
  });

  test('PII and compensation permissions are independent', () {
    final piiOnly = filterEmployeeEditPayloadForPermissions(payload, const {
      Perm.employeeEdit,
      Perm.employeePiiEdit,
    });
    expect(piiOnly, containsPair('phone', '13800138000'));
    expect(piiOnly, containsPair('bankAccount', '6222000000000000'));
    expect(piiOnly, isNot(contains('baseSalary')));

    final compensationOnly = filterEmployeeEditPayloadForPermissions(
      payload,
      const {Perm.employeeEdit, Perm.employeeCompensationEdit},
    );
    expect(compensationOnly, containsPair('baseSalary', '12000'));
    expect(compensationOnly, containsPair('housingFundBase', '12000'));
    expect(compensationOnly, isNot(contains('phone')));
  });
}
