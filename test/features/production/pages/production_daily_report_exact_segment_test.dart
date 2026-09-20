import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_employee_multi_picker.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
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
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/production/widgets/production_daily_grid_columns.dart';

void main() {
  for (final scenario in [
    'ready',
    'material-failure',
    'draft-failure',
    'legacy-final',
  ]) {
    final failMaterialRead = scenario == 'material-failure';
    final failDraftRead = scenario == 'draft-failure';
    testWidgets('editing draft preserves stored use: $scenario', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      Map<String, dynamic>? saved;
      var detailUnavailable = failDraftRead;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            if (detailUnavailable &&
                request.method == 'GET' &&
                request.path.endsWith('/daily-reports/draft')) {
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.connectionError,
                ),
              );
              return;
            }
            if (request.method == 'PUT' &&
                request.path.endsWith('/daily-reports/draft')) {
              saved = Map<String, dynamic>.from(request.data as Map);
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.connectionError,
                ),
              );
              return;
            }
            if (failMaterialRead && request.path.endsWith('/clearance')) {
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.connectionError,
                ),
              );
              return;
            }
            dynamic data = <dynamic>[];
            if (request.path.endsWith('/daily-reports/draft')) {
              data = {
                'id': 'draft',
                'status': 0,
                'rowVersion': 1,
                'makerId': 'employee-1',
                'departmentId': 'workshop',
                'workshopName': '装配第一车间',
                'workerIds': ['employee-1'],
                'surplusReturnRequested': failMaterialRead,
                'items': [
                  {
                    'id': 'line',
                    'goodsId': 'goods-1',
                    'planId': 'plan-1',
                    'planItemId': 'plan-item-1',
                    'planNo': 'SJ-001',
                    'executionSegmentId': 'segment-1',
                    'unitId': 'unit-1',
                    'unitRate': 1,
                    'qty': 5,
                    'isFinal': scenario == 'legacy-final',
                    'remainingPlanQty': 20,
                  },
                ],
                'materialUsages': [
                  {
                    'demandId': 'demand-1',
                    'qtyBase': 7,
                    'planId': 'plan-1',
                    'materialExecutionSegmentId': 'segment-1',
                  },
                ],
              };
            } else if (request.path.endsWith('/material-usage-sources')) {
              data = [
                {
                  'executionSegmentId': 'segment-1',
                  'executionSegmentCode': 'SEG-001',
                  'canOpen': true,
                  'canSettle': true,
                  'shared': false,
                },
              ];
            } else if (request.path.endsWith('/clearance')) {
              data = [
                {
                  'planId': 'plan-1',
                  'demandId': 'demand-1',
                  'goodsId': 'raw',
                  'goodsName': '测试原料',
                  'executionSegmentId': 'segment-1',
                  'issuedQty': 10,
                  'unclearedQty': 10,
                  'availableToSettleQty': 10,
                  'requiredQty': 10,
                  'requiredForProductQty': 10,
                  'requirementMode': 'LINEAR',
                },
              ];
            } else if (request.path.endsWith('/direct-transfers/candidates')) {
              data = {'candidates': <dynamic>[]};
            }
            handler.resolve(
              Response(requestOptions: request, statusCode: 200, data: data),
            );
          },
        ),
      );
      final api = ApiClient(dio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            departmentRepositoryProvider.overrideWithValue(
              _FakeDepartmentRepository(),
            ),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            productionDailyReportRepositoryProvider.overrideWithValue(
              ProductionDailyReportRepository(api),
            ),
            employeeRepositoryProvider.overrideWithValue(
              _FakeEmployeeRepository(),
            ),
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue({
              Perm.productionDailyReportEdit,
            }),
            documentScopeCapabilityProvider(
              DocumentDataScope.productionPlan,
            ).overrideWith(
              (ref) async => const DocumentScopeCapability(
                scope: 'production_plan',
                writeAll: true,
                writableOwnerIds: {},
              ),
            ),
          ],
          child: const MaterialApp(
            home: Column(
              children: [
                AppNotificationHost(),
                Expanded(child: ProductionDailyReportEditPage(id: 'draft')),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (failDraftRead) {
        expect(find.byType(UtenEditableGrid<DailyGridRow>), findsNothing);
        expect(find.byKey(const ValueKey('uten-edit-save')), findsNothing);
        expect(saved, isNull);
        detailUnavailable = false;
        await tester.tap(find.text('重新读取草稿'));
        await tester.pumpAndSettle();
      }
      if (scenario == 'legacy-final') {
        await tester.tap(find.text('改为普通报工'));
        await tester.pumpAndSettle();
        expect(find.text('改为普通报工'), findsNothing);
      }
      if (!failMaterialRead) {
        expect(find.text('测试原料'), findsOneWidget);
        var grid = tester.widget<UtenEditableGrid<DailyGridRow>>(
          find.byType(UtenEditableGrid<DailyGridRow>),
        );
        final first = grid.controller.rows.firstWhere(
          (row) => !row.isMaterialRow,
        );
        final copy = first.clone();
        grid.controller.addRow(copy);
        await tester.pumpAndSettle();
        final material = grid.controller.rows.firstWhere(
          (row) => row.materialEditable,
        );
        material.materialUsed.text = '8';
        grid = tester.widget<UtenEditableGrid<DailyGridRow>>(
          find.byType(UtenEditableGrid<DailyGridRow>),
        );
        grid.onDeleteRow!(first, 0);
        await tester.pumpAndSettle();
        final remaining = grid.controller.rows
            .where((row) => row.materialEditable)
            .toList();
        expect(remaining, hasLength(1));
        expect(remaining.single.materialParent, copy);
        expect(remaining.single.materialUsed.text, '8');
      }
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(saved, isNotNull);
      expect(saved!['materialLines'], [
        {'demandId': 'demand-1', 'qtyBase': failMaterialRead ? 7 : 8},
      ]);
      expect(saved!['surplusReturnRequested'] == true, failMaterialRead);
      expect(
        (saved!['items'] as List).every(
          (item) => (item as Map)['isFinal'] != true,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  }

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
      expect(find.text('SEG-001'), findsOneWidget);
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

  testWidgets('新建日报勾选口径：来源行自动勾选，没勾行时保存置灰并说明原因', (tester) async {
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
          home: Column(
            children: [
              AppNotificationHost(),
              Expanded(
                child: ProductionDailyReportEditPage(
                  initialExecutionSegmentId: 'segment-1',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('成品灯'), findsOneWidget);

    final save = find.byKey(const ValueKey('uten-edit-save'));
    UtenButton saveButton() => tester.widget<UtenButton>(save);
    // 深链来源已应用到行 → 自动勾选（2026-09-18 勾选口径），保存可点。
    expect(saveButton().onPressed, isNotNull);
    // 取消行勾选（行框树序在表头框之前）→ 保存置灰，灰态点击说明原因。
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pump();
    expect(saveButton().onPressed, isNull);
    await tester.tap(save);
    await tester.pump();
    expect(find.textContaining('请先勾选要报工的明细行'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
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
    String? sort,
    String? order,
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
