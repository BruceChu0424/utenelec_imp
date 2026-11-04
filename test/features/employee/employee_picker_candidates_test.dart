import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker_models.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_picker_candidates.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  test('员工列表分别解析账号和在职状态，旧响应缺账号字段时保持未知', () {
    for (final account in ['notProvisioned', 'active', 'locked', 'disabled']) {
      final employee = EmployeeSummary.fromJson({
        'id': 'employee-id',
        'code': 'UT001',
        'fullName': '张三',
        'status': 'onLeave',
        'accountStatus': account,
      });
      expect(employee.accountStatus, account);
      expect(employee.status, 'onLeave');
    }
    final legacy = EmployeeSummary.fromJson({
      'id': 'legacy-id',
      'code': 'UT002',
      'fullName': '李四',
      'status': 'active',
    });
    expect(legacy.accountStatus, isNull);
    expect(legacy.status, 'active');
  });

  test('员工候选首屏不拉全量，显式续页完整可达且保留部门状态及排序', () async {
    final repository = _Repository();
    Future<UtenEmployeePickerPage> read(int page) => repository.listPickerPage(
      UtenEmployeePickerQuery(page: page, keyword: '张'),
      size: 2,
      statuses: {'active', 'probation'},
      departmentId: 'workshop',
      includeSubtree: true,
      sort: 'code',
      order: 'asc',
      loadDepartments: () async => [],
    );
    final first = await read(1);
    expect(repository.queries.map((query) => query['page']), [1]);
    expect(first.totalPages, 3);
    final second = await read(2);
    final third = await read(3);
    final employees = {
      for (final employee in [...first.items, ...second.items, ...third.items])
        employee.id: employee,
    }.values;
    expect(employees.map((employee) => employee.id), ['e1', 'e2', 'e3']);
    expect(employees.map((employee) => employee.accountStatus), [
      'active',
      'locked',
      'notProvisioned',
    ]);
    expect(employees.map((employee) => employee.employmentStatus), [
      'active',
      'probation',
      'onLeave',
    ]);
    expect(repository.queries.map((query) => query['page']), [1, 2, 3]);
    for (final query in repository.queries) {
      expect(query['size'], 2);
      expect(query['search'], '张');
      expect(query['statuses'], {'active', 'probation'});
      expect(query['departmentId'], 'workshop');
      expect(query['includeSubtree'], isTrue);
      expect(query['sort'], 'code');
      expect(query['order'], 'asc');
    }
  });

  test('空候选不再请求后续页', () async {
    final repository = _Repository(empty: true);
    final result = await repository.listPickerPage(
      const UtenEmployeePickerQuery(),
      loadDepartments: () async => [],
    );
    expect(result.items, isEmpty);
    expect(result.totalPages, 0);
    expect(repository.queries, hasLength(1));
  });

  test('后续分页失败时不把不完整名单显示成完整候选', () async {
    final repository = _Repository(failPage: 2);
    final first = await repository.listPickerPage(
      const UtenEmployeePickerQuery(),
      loadDepartments: () async => [],
    );
    expect(first.items, hasLength(1));
    expect(first.totalPages, 3);
    await expectLater(
      repository.listPickerPage(
        const UtenEmployeePickerQuery(page: 2),
        loadDepartments: () async => [],
      ),
      throwsA(isA<StateError>()),
    );
    expect(repository.queries, hasLength(2));
  });
}

class _Repository implements EmployeeRepository {
  _Repository({this.empty = false, this.failPage});

  final bool empty;
  final int? failPage;
  final queries = <Map<String, Object?>>[];

  @override
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
    String? sort,
    String? order,
  }) async {
    queries.add({
      'page': page,
      'size': size,
      'search': search,
      'statuses': statuses,
      'departmentId': departmentId,
      'includeSubtree': includeSubtree,
      'sort': sort,
      'order': order,
    });
    if (page == failPage) throw StateError('连接中断');
    return PagedResult(
      items: empty
          ? const []
          : [
              // A boundary duplicate must not create two rows for one person.
              if (page == 2) _employee(1),
              _employee(page),
            ],
      page: page,
      size: size,
      total: empty ? 0 : 4,
      totalPages: empty ? 0 : 3,
    );
  }

  EmployeeSummary _employee(int index) => EmployeeSummary(
    id: 'e$index',
    fullName: '张$index',
    code: 'E$index',
    departmentId: 'workshop',
    departmentName: '生产车间',
    accountStatus: ['active', 'locked', 'notProvisioned'][index - 1],
    status: ['active', 'probation', 'onLeave'][index - 1],
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
