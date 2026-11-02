import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/department_node.dart';
import 'package:uten_imp/shared/models/employee_reference.dart';

/// The HTTP fixture exposes the same six-field department projection as the
/// server. Manager fields stay out of that tree; known managers may appear as
/// minimal personnel references, never as an HR-directory response.
Future<bool> resolveProductionPersonReferenceFixture(
  RequestOptions request,
  RequestInterceptorHandler handler, {
  Future<List<DepartmentNode>> Function()? departments,
  List<Map<String, dynamic>> departmentRows = const [],
  EmployeeReferencePurpose purpose =
      EmployeeReferencePurpose.productionMaterialOwner,
}) async {
  if (!request.path.startsWith('/org/employee-references') &&
      request.path != '/production/workshop-assignment-defaults' &&
      request.path != '/business-references/departments') {
    return false;
  }
  expect(request.method, 'GET');
  if (request.path != '/business-references/departments') {
    expect(request.queryParameters['purpose'], purpose.apiValue);
  }
  final tree = departments == null
      ? departmentRows.map(DepartmentNode.fromJson).toList()
      : await departments();
  Map<String, Object?> project(DepartmentNode node) => {
    'id': node.id,
    'code': node.code,
    'name': node.name,
    'level': node.level,
    'parentId': node.parentId,
    'children': node.children.map(project).toList(),
  };
  final people = <String, Map<String, Object?>>{};
  void visit(DepartmentNode node) {
    final id = node.managerId;
    if (id != null &&
        id.isNotEmpty &&
        node.managerName?.trim().isNotEmpty == true) {
      people[id] = {
        'id': id,
        'code': 'TEST-$id',
        'fullName': node.managerName!,
        'departmentId': node.id,
        'departmentName': node.name,
        'status': 'active',
        'accountStatus': null,
        'positionName': null,
      };
    }
    for (final child in node.children) {
      visit(child);
    }
  }

  tree.forEach(visit);
  final Object data;
  switch (request.path) {
    case '/production/workshop-assignment-defaults':
      final ids = (request.queryParameters['ids'] as String).split(',').toSet();
      expect(ids.length, lessThanOrEqualTo(100));
      final workshops = tree
          .where((node) => node.code == kDeptCodeProduction)
          .expand((node) => node.children)
          .where((node) => ids.contains(node.id));
      data = [
        for (final node in workshops)
          {
            'departmentId': node.id,
            'departmentName': node.name,
            'responsibleEmployeeId': people.containsKey(node.managerId)
                ? node.managerId
                : null,
            'responsibleEmployeeName': people.containsKey(node.managerId)
                ? node.managerName
                : null,
          },
      ];
    case '/business-references/departments':
    case '/org/employee-references/departments':
      data = tree.map(project).toList();
    case '/org/employee-references/by-ids':
      final ids = (request.queryParameters['ids'] as String).split(',').toSet();
      data = people.values.where((row) => ids.contains(row['id'])).toList();
    case '/org/employee-references':
      final selected = people.values.where((row) {
        final department = request.queryParameters['departmentId'];
        final search = request.queryParameters['search'] as String?;
        return (department == null || department == row['departmentId']) &&
            (search == null ||
                '${row['code']} ${row['fullName']}'.contains(search));
      }).toList();
      data = {
        'items': selected,
        'page': 1,
        'size': request.queryParameters['size'] ?? 100,
        'total': selected.length,
        'totalPages': selected.isEmpty ? 0 : 1,
      };
    default:
      throw StateError(
        'Unexpected personnel-reference fixture route: ${request.path}',
      );
  }
  handler.resolve(
    Response<dynamic>(requestOptions: request, statusCode: 200, data: data),
  );
  return true;
}
