import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations_zh.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/repositories/department_roster_snapshot.dart';
import 'package:uten_imp/features/department/widgets/department_org_chart_dialog.dart';
import 'package:uten_imp/features/department/widgets/department_roster_print.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

class _Repository extends Fake implements EmployeeRepository {
  _Repository(int count)
    : rows = List.generate(
        count,
        (index) => EmployeeSummary(
          id: 'e$index',
          code: 'C$index',
          fullName: '原始姓名龘$index',
          departmentId: index < 300 ? 'root' : 'child',
          departmentName: '原部门',
          positionName: '原岗位',
          gender: index.isEven ? 'male' : 'female',
        ),
      );
  final List<EmployeeSummary> rows;
  final calls = <({int page, int size, String? department, bool subtree})>[];
  int? wrongPage;
  int? emptyPage;
  int? failPage;
  int extraTotal = 0;
  void Function(int page)? onRequest;

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
    calls.add((
      page: page,
      size: size,
      department: departmentId,
      subtree: includeSubtree,
    ));
    onRequest?.call(page);
    if (page == failPage) throw ApiException('FIXTURE_DISCONNECTED', '合成断线');
    final start = ((page - 1) * size).clamp(0, rows.length);
    final end = (start + size).clamp(0, rows.length);
    return PagedResult(
      items: page == emptyPage ? [] : rows.sublist(start, end),
      page: page == wrongPage ? page - 1 : page,
      size: size,
      total: rows.length + extraTotal,
      totalPages: (rows.length + size - 1) ~/ size,
    );
  }
}

void main() {
  test(
    'both complete consumers share all 601 authorized people including the seventh page',
    () async {
      final repository = _Repository(601);
      final snapshot = await loadDepartmentRosterSnapshot(
        repository: repository,
        departmentId: 'root',
        isCurrent: () => true,
      );
      expect(snapshot.employees, repository.rows);
      expect(snapshot.byDepartment['root'], hasLength(300));
      expect(snapshot.byDepartment['child'], hasLength(301));
      expect(
        repository.calls.map((call) => call.page),
        orderedEquals([1, 2, 3, 4, 5, 6, 7]),
      );
      expect(
        repository.calls.every(
          (call) =>
              call.size == 100 && call.department == 'root' && call.subtree,
        ),
        isTrue,
      );
      expect(
        () => snapshot.byDepartment['root']!.clear(),
        throwsUnsupportedError,
      );

      final table = await loadDepartmentRosterPrintTable(
        repository: repository,
        departmentId: 'root',
        l10n: AppLocalizationsZh(),
        isCurrent: () => true,
      );
      expect(table.rows, hasLength(601));
      expect(table.rowIds!.last, 'e600');
      expect(table.rows.last, [
        'C600',
        '原始姓名龘600',
        '男',
        '原部门',
        '原岗位',
        '',
        '',
        '—',
      ]);
    },
  );

  test('empty authorized department is a complete empty snapshot', () async {
    final repository = _Repository(0);
    final result = await loadDepartmentRosterSnapshot(
      repository: repository,
      departmentId: 'empty',
      isCurrent: () => true,
    );
    expect(result.employees, isEmpty);
    expect(result.byDepartment, isEmpty);
    expect(repository.calls, hasLength(1));
  });

  for (final failure in [
    'wrong-page',
    'empty-continuation',
    'incomplete-total',
    'network',
  ]) {
    test('$failure refuses a partial print/chart result', () async {
      final repository = _Repository(601);
      switch (failure) {
        case 'wrong-page':
          repository.wrongPage = 2;
        case 'empty-continuation':
          repository.emptyPage = 2;
        case 'incomplete-total':
          repository.extraTotal = 1;
        case 'network':
          repository.failPage = 2;
      }
      await expectLater(
        loadDepartmentRosterPrintTable(
          repository: repository,
          departmentId: 'root',
          l10n: AppLocalizationsZh(),
          isCurrent: () => true,
        ),
        throwsA(isA<ApiException>()),
      );
      expect(repository.calls.length, lessThanOrEqualTo(7));
    });
  }

  test(
    'retiring an identity after a page stops continuation and publishes no snapshot',
    () async {
      final repository = _Repository(601);
      var current = true;
      repository.onRequest = (page) {
        if (page == 2) current = false;
      };
      await expectLater(
        loadDepartmentRosterSnapshot(
          repository: repository,
          departmentId: 'root',
          isCurrent: () => current,
        ),
        throwsA(isA<UiWorkCancelled>()),
      );
      expect(repository.calls, hasLength(2));
    },
  );

  test(
    '10001 people keep formatting and grouping in explicit UI work slices',
    () async {
      final repository = _Repository(10001);
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      addTearDown(timer.cancel);
      final table = await loadDepartmentRosterPrintTable(
        repository: repository,
        departmentId: 'root',
        l10n: AppLocalizationsZh(),
        isCurrent: () => true,
        budget: UiWorkBudget(maxItems: 32, slice: const Duration(hours: 1)),
      );
      expect(table.rows, hasLength(10001));
      expect(table.rows.last[1], '原始姓名龘10000');
      expect(ticks, greaterThan(1));
      expect(repository.calls, hasLength(101));
    },
  );

  test(
    'outline preserves manager/director placement, raw names, child order and no duplicate manager',
    () async {
      final repository = _Repository(601);
      final snapshot = await loadDepartmentRosterSnapshot(
        repository: repository,
        departmentId: 'root',
        isCurrent: () => true,
      );
      final root = DepartmentNode(
        id: 'root',
        code: 'ROOT',
        name: '原部门龘',
        level: '管理中心',
        managerId: 'e0',
        managerName: '原始姓名龘0',
        headcount: 601,
        children: [
          DepartmentNode(
            id: 'child',
            code: 'CHILD',
            name: '子部门',
            level: '一级部门',
            managerId: 'outside',
            managerName: '挂职负责人',
            children: [],
          ),
        ],
      );
      final lines = await buildDepartmentOrgChartPrintLines(
        root,
        snapshot.byDepartment,
      );
      expect(lines.where((line) => line.kind == 'member'), hasLength(600));
      expect(lines.first.text, '原部门龘');
      expect(lines.first.detail, contains('601 人'));
      expect(lines[1].text, '★ 原始姓名龘0(负责人)');
      expect(
        lines.where((line) => line.kind == 'manager').last.text,
        '★ 挂职负责人(负责人，非本部门直属(挂职))',
      );
      expect(
        lines.where((line) => line.kind == 'member').last.text,
        '原始姓名龘600 · 原岗位',
      );
      expect(lines.last.depth, 1);
    },
  );

  test(
    'a cyclic department hierarchy is rejected rather than duplicated',
    () async {
      final children = <DepartmentNode>[];
      final root = DepartmentNode(
        id: 'cycle',
        code: 'C',
        name: '循环',
        level: '管理中心',
        children: children,
      );
      children.add(root);
      await expectLater(
        buildDepartmentOrgChartPrintLines(root, const {}),
        throwsFormatException,
      );
    },
  );
}
