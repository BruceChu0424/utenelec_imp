import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_employee_multi_picker.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/models/workforce_overview.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/production/pages/production_daily_report_edit_page.dart';
import 'package:uten_imp/features/production/providers/production_department_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  test(
    'production workforce tree keeps the center and production branch only',
    () async {
      final container = ProviderContainer(
        overrides: [
          departmentRepositoryProvider.overrideWithValue(
            _FakeDepartmentRepository(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final scope = await container.read(
        productionWorkforceTreeProvider.future,
      );

      expect(scope.tree.single.name, '制造与研发管理中心');
      expect(scope.tree.single.children.single.code, 'DEPT_PROD');
      expect(
        scope.tree.single.children.single.children.single.code,
        'WS_ASSEMBLY',
      );
      expect(scope.productionDepartmentId, 'production');
      expect(scope.initiallyExpandedIds, containsAll(['center', 'production']));
    },
  );

  testWidgets(
    'exact execution segment applies its only reportable source without reopening picker',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _api();
      final employees = _FakeEmployeeRepository();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            departmentRepositoryProvider.overrideWithValue(
              _FakeDepartmentRepository(),
            ),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            productionDailyReportRepositoryProvider.overrideWithValue(
              ProductionDailyReportRepository(api),
            ),
            employeeRepositoryProvider.overrideWithValue(employees),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(
            home: ProductionDailyReportEditPage(
              initialExecutionSegmentId: 'segment-1',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('选择报工子任务'), findsNothing);
      expect(find.text('成品灯'), findsOneWidget);
      expect(find.textContaining('SJ-001'), findsOneWidget);
      expect(find.text('10'), findsOneWidget);

      await tester.tap(find.byType(UtenEmployeeMultiPicker));
      await tester.pumpAndSettle();
      await tester.tap(find.text('张三(UT001)'));
      await tester.tap(find.text('李四(UT002)'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pumpAndSettle();

      expect(find.text('张三(UT001)'), findsOneWidget);
      expect(find.text('李四(UT002)'), findsOneWidget);
      expect(employees.lastDepartmentId, 'workshop');
      expect(employees.lastStatuses, {'active', 'probation'});
      expect(tester.takeException(), isNull);
    },
  );
}

ApiClient _api() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final data =
            request.path.endsWith(
              '/production/daily-reports/reportable-plan-lines',
            )
            ? {
                'items': [
                  {
                    'planItemId': 'plan-item-1',
                    'executionSegmentId': 'segment-1',
                    'executionSegmentCode': 'SEG-001',
                    'executionSegmentStatus': 'IN_PROGRESS',
                    'executionSegmentVersion': 3,
                    'orderItemId': 'order-item-1',
                    'planNo': 'SJ-001',
                    'goodsId': 'goods-1',
                    'goodsCode': 'P-001',
                    'goodsName': '成品灯',
                    'unitId': 'unit-1',
                    'unitRate': 1,
                    'maxReportQty': 10,
                    'orderNo': 'SO-001',
                    'departmentId': 'workshop',
                    'workshopName': '装配第一车间',
                  },
                ],
                'page': 1,
                'size': 2,
                'total': 1,
                'totalPages': 1,
              }
            : <dynamic>[];
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

class _FakeDepartmentRepository implements DepartmentRepository {
  @override
  Future<List<DepartmentNode>> tree() async => [
    DepartmentNode(
      id: 'center',
      code: 'MFG_CENTER',
      name: '制造与研发管理中心',
      level: '管理中心',
      children: [
        DepartmentNode(
          id: 'production',
          code: 'DEPT_PROD',
          name: '生产部',
          level: '一级部门',
          parentId: 'center',
          children: [
            DepartmentNode(
              id: 'workshop',
              code: 'WS_ASSEMBLY',
              name: '装配第一车间',
              level: '二级班组',
              parentId: 'production',
              children: const [],
            ),
          ],
        ),
        DepartmentNode(
          id: 'quality',
          code: 'DEPT_QA',
          name: '品质管理部',
          level: '一级部门',
          parentId: 'center',
          children: const [],
        ),
      ],
    ),
  ];

  @override
  Future<DepartmentInfo> detail(String id) => throw UnimplementedError();

  @override
  Future<WorkforceOverview> workforceOverview(String id) =>
      throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeEmployeeRepository implements EmployeeRepository {
  String? lastDepartmentId;
  Set<String>? lastStatuses;

  @override
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
  }) async {
    lastDepartmentId = departmentId;
    lastStatuses = statuses;
    return const PagedResult(
      items: [
        EmployeeSummary(
          id: 'employee-1',
          code: 'UT001',
          fullName: '张三',
          departmentId: 'workshop',
          departmentName: '装配第一车间',
        ),
        EmployeeSummary(
          id: 'employee-2',
          code: 'UT002',
          fullName: '李四',
          departmentId: 'workshop',
          departmentName: '装配第一车间',
        ),
      ],
      page: 1,
      size: 100,
      total: 2,
      totalPages: 1,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
