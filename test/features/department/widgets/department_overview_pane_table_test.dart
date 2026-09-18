// 部门管理右侧「在册员工」表格化（2026-09-17）：员工档案同款
// MasterDataTableView——列/表头筛选/滚动自动翻页，取代 UtenPersonCard 卡片列表。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/models/workforce_overview.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/department/widgets/department_overview_pane.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _FakeDepartmentRepository implements DepartmentRepository {
  @override
  Future<DepartmentInfo> detail(String id) async => DepartmentInfo(
    id: id,
    code: 'D01',
    name: '生产部',
    level: 'department',
    path: '生产部',
    childCount: 0,
    employeeCount: 2,
  );

  @override
  Future<WorkforceOverview> workforceOverview(String id) async =>
      WorkforceOverview.fromJson({
        'organizationId': id,
        'organizationName': id,
      });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeEmployeeRepository implements EmployeeRepository {
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
    const items = [
      EmployeeSummary(
        id: 'e1',
        code: 'E-001',
        fullName: '张三',
        departmentId: 'd1',
        departmentName: '生产部',
        positionName: '操作工',
        status: 'active',
        hireDate: '2015-06-01',
      ),
      EmployeeSummary(
        id: 'e2',
        code: 'E-002',
        fullName: '李四',
        departmentId: 'd1',
        departmentName: '生产部',
        positionName: '质检员',
        status: 'probation',
        hireDate: '2026-09-01',
      ),
    ];
    return PagedResult(
      items: items,
      page: page,
      size: size,
      total: items.length,
      totalPages: 1,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('在册员工以员工档案同款表格展示（列+筛选桶+行数）', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue({
            Perm.departmentView,
            Perm.employeeView,
          }),
          departmentRepositoryProvider.overrideWithValue(
            _FakeDepartmentRepository(),
          ),
          employeeRepositoryProvider.overrideWithValue(
            _FakeEmployeeRepository(),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: DepartmentOverviewPane(
              node: DepartmentNode(
                id: 'd1',
                code: 'D01',
                name: '生产部',
                level: 'department',
                children: const [],
              ),
              canEdit: false,
              canAddChild: false,
              canDelete: false,
              canViewEmployees: true,
              canCreateEmployee: false,
              onAddChild: () {},
              onEdit: (_) {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<EmployeeSummary>>(
      find.byKey(const Key('department-employee-table')),
    );
    expect(
      table.columns.map((c) => c.key),
      containsAll(<String>[
        'code',
        'fullName',
        'departmentName',
        'positionName',
        'status',
        'hireDate',
        'workYears',
      ]),
    );
    expect(table.items.length, 2, reason: '两位在册员工都进表格');
    expect(table.facets['status']!.map((b) => b.value), isNotEmpty);
    // 卡片列表已退役。
    expect(find.text('E-001 · 生产部 · 操作工'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}
