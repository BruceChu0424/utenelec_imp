import 'dart:io';

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
    'departmentId': 'dept-2',
    'positionId': 'position-2',
    'status': 'active',
    'confirmedAt': '2026-08-01',
  };

  test('sensitive employee edits fail closed without field permissions', () {
    final filtered = filterEmployeeEditPayloadForPermissions(payload, const {
      Perm.employeeEdit,
    });

    expect(filtered, const {'fullName': '张三'});
  });

  test('lifecycle fields are never submitted by ordinary edit', () {
    final filtered = filterEmployeeEditPayloadForPermissions(payload, const {
      Perm.employeeEdit,
      Perm.employeePiiEdit,
      Perm.employeeCompensationEdit,
    });

    expect(filtered, isNot(contains('departmentId')));
    expect(filtered, isNot(contains('positionId')));
    expect(filtered, isNot(contains('status')));
    expect(filtered, isNot(contains('confirmedAt')));
  });

  test('status control is read-only and build payload has no status write', () {
    final source = File(
      'lib/features/employee/pages/employee_edit_page.dart',
    ).readAsStringSync();

    expect(source, contains("ValueKey('employee-edit-status-readonly')"));
    expect(source, contains('onChanged: null'));
    expect(source, isNot(contains("code('status'")));
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
