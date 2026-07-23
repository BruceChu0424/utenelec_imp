// 模型反序列化测试（项目首批测试，建立 *_test.dart 约定）。
// 验证 API 模型 fromJson 与后端 JSON 字段对齐。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/auth/models/auth_session.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  group('AuthResult.fromJson', () {
    test('解析登录响应（含角色/权限）', () {
      final r = AuthResult.fromJson({
        'accessToken': 'a',
        'refreshToken': 'r',
        'expiresIn': 900,
        'mustChangePassword': true,
        'user': {
          'id': 'u1',
          'loginAccount': 'admin',
          'name': '系统管理员',
          'code': 'ADMIN',
          'department': '行政与人力资源部',
          'position': null,
          'roles': ['admin', 'hr'],
          'permissions': ['employee:view', 'department:edit'],
        }
      });
      expect(r.accessToken, 'a');
      expect(r.mustChangePassword, isTrue);
      expect(r.user.id, 'u1');
      expect(r.user.roles, containsAll(['admin', 'hr']));
      expect(r.user.permissions, contains('employee:view'));
      expect(r.user.isAdmin, isTrue);
    });
  });

  group('DepartmentNode.fromJson', () {
    test('递归解析子部门', () {
      final node = DepartmentNode.fromJson({
        'id': 'd1',
        'code': 'MFG_CENTER',
        'name': '制造与研发管理中心',
        'level': '管理中心',
        'parentId': 'root',
        'children': [
          {'id': 'd2', 'code': 'DEPT_PROD', 'name': '生产部', 'level': '一级部门', 'children': []},
        ],
      });
      expect(node.name, '制造与研发管理中心');
      expect(node.hasChildren, isTrue);
      expect(node.children.first.code, 'DEPT_PROD');
    });
  });

  group('PagedResult + EmployeeSummary', () {
    test('解析分页员工列表', () {
      final page = PagedResult.fromJson({
        'items': [
          {'id': 'e1', 'code': 'E001', 'fullName': '张三', 'departmentName': '生产部', 'status': 'active'},
        ],
        'page': 1,
        'size': 20,
        'total': 1,
        'totalPages': 1,
      }, EmployeeSummary.fromJson);
      expect(page.items, hasLength(1));
      expect(page.items.first.fullName, '张三');
      expect(page.total, 1);
    });
  });

  group('EmployeeProfile', () {
    test('解析详情（敏感字段已脱敏）', () {
      final p = EmployeeProfile.fromJson({
        'id': 'e1',
        'code': 'E001',
        'fullName': '张三',
        'gender': 'male',
        'status': 'active',
        'phone': '138****1234',
        'idNumber': '****1234',
        'emergencyContacts': [],
        'history': [],
      });
      expect(p.fullName, '张三');
      expect(p.phone, '138****1234'); // 非权限角色看到的脱敏值
      expect(p.emergencyContacts, isEmpty);
    });
  });
}
