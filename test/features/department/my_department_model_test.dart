import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/department/models/my_department.dart';

void main() {
  test('安全花名册保留部门定位并按姓名或工号大小写无关匹配', () {
    final row = MyDepartmentStaffRow.fromJson(const {
      'employeeId': 'employee-1',
      'departmentId': 'department-1',
      'code': 'E-Alpha',
      'fullName': '张三',
      'departmentManager': false,
      'isSelf': false,
    });

    expect(row.departmentId, 'department-1');
    expect(row.matchesSearch(' 张三 '), isTrue);
    expect(row.matchesSearch('e-alpha'), isTrue);
    expect(row.matchesSearch('李四'), isFalse);
  });
}
