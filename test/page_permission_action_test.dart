import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';
import 'package:uten_imp/features/admin/pages/page_permission_settings_page.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_models.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_repository.dart';
import 'package:uten_imp/shared/auth/permission_action_type.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test('models parse bounded backend workspace DTO shapes', () {
    final staff = PagePermissionStaffPage.fromJson({
      'surfaceKey': 'sales.order',
      'departmentId': 'department-1',
      'departmentName': '销售一组',
      'page': 1,
      'size': 40,
      'total': 1,
      'totalPages': 1,
      'staff': [
        {
          'employeeId': 'employee-1',
          'departmentId': 'department-1',
          'departmentName': '销售一组',
          'code': 'S001',
          'fullName': '张三',
          'positionName': '业务员',
          'departmentManager': false,
          'hasAccount': true,
          'accountActive': true,
        },
      ],
    });
    final detail = PagePermissionEmployeeDetail.fromJson({
      'surfaceKey': 'sales.order',
      'departmentId': 'department-1',
      'departmentName': '销售一组',
      'settingMode': 'CENTRAL_OVERRIDE',
      'employee': {
        'employeeId': 'employee-1',
        'code': 'S001',
        'fullName': '张三',
        'departmentManager': false,
        'hasAccount': true,
      },
      'permissions': [
        {
          'code': 'sales_order:view',
          'name': '销售订货查看',
          'actorEffective': true,
          'targetBaseEffective': true,
          'effective': true,
          'configuredEffect': 'grant',
          'rowVersion': 3,
          'editable': true,
        },
      ],
    });

    expect(staff.items.single.fullName, '张三');
    expect(staff.items.single.departmentName, '销售一组');
    expect(staff.items.single.accountActive, isTrue);
    expect(detail.superAdminMode, isTrue);
    expect(detail.permissions.single.baseEffective, isTrue);
    expect(detail.permissions.single.delegationEnabled, isTrue);
  });

  testWidgets('ordinary employee does not see permission settings action', (
    tester,
  ) async {
    await tester.pumpWidget(_actionApp(canManage: false));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('page-permission-action')), findsNothing);
  });

  testWidgets('enabled super admin opens independent page with full catalog', (
    tester,
  ) async {
    await tester.pumpWidget(_actionApp(canManage: true, superAdmin: true));
    await tester.pumpAndSettle();

    final action = find.byKey(const ValueKey('page-permission-action'));
    expect(action, findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();

    expect(find.text('独立权限设置页'), findsOneWidget);
  });

  testWidgets('disabled release gate hides action even for super admin', (
    tester,
  ) async {
    await tester.pumpWidget(_actionApp(canManage: false, superAdmin: true));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('page-permission-action')), findsNothing);
  });

  testWidgets('department manager capability shows action', (tester) async {
    await tester.pumpWidget(_actionApp(canManage: true));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('page-permission-action')),
      findsOneWidget,
    );
  });

  testWidgets('expanded page uses split view and submits one atomic diff', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _FakePagePermissionRepository();

    await tester.pumpWidget(_settingsApp(repository));
    await tester.pumpAndSettle();

    expect(find.byType(UtenSplitView), findsOneWidget);
    expect(find.text('张三'), findsWidgets);
    expect(find.text('销售订货查看'), findsOneWidget);
    expect(find.text('供应商查看'), findsNothing);
    final historical = tester.widget<SwitchListTile>(
      find.byKey(
        const ValueKey('page-permission-employee-1-sales_order:priority'),
      ),
    );
    expect(historical.value, isTrue);

    await tester.tap(
      find.byKey(const ValueKey('page-permission-employee-1-sales_order:edit')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('page-permission-save')));
    await tester.pumpAndSettle();

    expect(repository.savedChanges, hasLength(1));
    expect(repository.savedChanges.single.code, Perm.salesOrderEdit);
    expect(repository.savedChanges.single.enabled, isTrue);
    expect(repository.savedChanges.single.expectedVersion, 0);
  });

  testWidgets('page settings filters authoritative action types', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_settingsApp(_FakePagePermissionRepository()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('page-permission-action-edit')));
    await tester.pumpAndSettle();

    expect(find.text('销售订货编辑'), findsOneWidget);
    expect(find.text('销售订货查看'), findsNothing);
    expect(find.text('编辑销售订货草稿'), findsOneWidget);
  });
  testWidgets(
    'department is optional, uses managed tree and can clear to all',
    (tester) async {
      tester.view.physicalSize = const Size(900, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _FakePagePermissionRepository();

      await tester.pumpWidget(_settingsApp(repository));
      await tester.pumpAndSettle();

      final picker = tester.widget<UtenDepartmentPicker>(
        find.byType(UtenDepartmentPicker),
      );
      expect(picker.initialSelection, isEmpty);
      expect(picker.treeOverride, isNotEmpty);
      expect(repository.requestedDepartments.first, isNull);
      expect(find.text('全部可管理范围'), findsOneWidget);
      expect(find.textContaining('销售一组'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byType(UtenDepartmentPicker),
          matching: find.byType(InputDecorator),
        ),
      );
      await tester.pumpAndSettle();
      final tree = find.byType(UtenDepartmentTreeView);
      await tester.tap(find.descendant(of: tree, matching: find.text('销售一组')));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(repository.requestedDepartments.last, 'department-1');
      expect(find.text('共 1 人 · 所选部门及其子部门'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('uten-department-picker-clear')),
      );
      await tester.pumpAndSettle();

      expect(repository.requestedDepartments.last, isNull);
      expect(find.text('全部可管理范围'), findsOneWidget);
    },
  );

  testWidgets(
    'cancel discard restores selected and cleared department filter',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _FakePagePermissionRepository();

      await tester.pumpWidget(_settingsApp(repository));
      await tester.pumpAndSettle();

      Future<void> chooseDepartment(String name) async {
        await tester.tap(
          find.descendant(
            of: find.byType(UtenDepartmentPicker),
            matching: find.byType(InputDecorator),
          ),
        );
        await tester.pumpAndSettle();
        final tree = find.byType(UtenDepartmentTreeView);
        await tester.tap(find.descendant(of: tree, matching: find.text(name)));
        await tester.pump();
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
      }

      await chooseDepartment('销售一组');
      expect(repository.requestedDepartments.last, 'department-1');

      final editPermission = find.byKey(
        const ValueKey('page-permission-employee-1-sales_order:edit'),
      );
      await tester.tap(editPermission);
      await tester.pump();
      expect(tester.widget<SwitchListTile>(editPermission).value, isTrue);

      await chooseDepartment('研发部');
      expect(find.text('丢弃未保存修改'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      var picker = tester.widget<UtenDepartmentPicker>(
        find.byType(UtenDepartmentPicker),
      );
      expect(picker.initialSelection.single.id, 'department-1');
      expect(repository.requestedDepartments.last, 'department-1');
      expect(tester.widget<SwitchListTile>(editPermission).value, isTrue);

      await tester.tap(
        find.byKey(const ValueKey('uten-department-picker-clear')),
      );
      await tester.pumpAndSettle();
      expect(find.text('丢弃未保存修改'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      picker = tester.widget<UtenDepartmentPicker>(
        find.byType(UtenDepartmentPicker),
      );
      expect(picker.initialSelection.single.id, 'department-1');
      expect(repository.requestedDepartments.last, 'department-1');
      expect(tester.widget<SwitchListTile>(editPermission).value, isTrue);
    },
  );

  testWidgets('compact page keeps list then opens selected employee detail', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const longDepartment = '总经办直属战略与国际业务协同管理办公室';
    final repository = _FakePagePermissionRepository(
      departmentName: longDepartment,
      accountActive: false,
    );

    await tester.pumpWidget(_settingsApp(repository));
    await tester.pumpAndSettle();

    expect(find.text('张三(S001)'), findsOneWidget);
    expect(find.textContaining(longDepartment), findsOneWidget);
    expect(find.byTooltip('账号未启用'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.text('销售订货查看'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('page-permission-staff-employee-1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('销售订货查看'), findsOneWidget);
    expect(find.byTooltip('返回人员列表'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search is debounced on server and staff list loads next page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _FakePagePermissionRepository(totalPages: 2);

    await tester.pumpWidget(_settingsApp(repository));
    await tester.pumpAndSettle();
    final searchField = find.descendant(
      of: find.byType(UtenSearchBar),
      matching: find.byType(TextField),
    );
    await tester.enterText(searchField, '李');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(repository.lastSearch, '李');
    expect(repository.requestedDepartments.last, isNull);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(repository.requestedPages, containsAllInOrder([1, 1, 2]));
  });

  testWidgets(
    'wide auto selection prefers an existing account and never prompts',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _FakePagePermissionRepository(
        staffItems: const [
          PagePermissionStaffSummary(
            employeeId: 'employee-1',
            departmentId: 'department-1',
            departmentName: '销售一组',
            code: 'S001',
            fullName: '张三',
            positionName: '业务员',
            departmentManager: false,
            hasAccount: false,
            accountActive: false,
          ),
          PagePermissionStaffSummary(
            employeeId: 'employee-2',
            departmentId: 'department-1',
            departmentName: '销售一组',
            code: 'S002',
            fullName: '李四',
            positionName: '业务员',
            departmentManager: false,
            hasAccount: true,
            accountActive: true,
          ),
        ],
      );

      await tester.pumpWidget(
        _settingsApp(
          repository,
          permissions: const {Perm.accountSupport},
          employeeRepository: _ProvisionEmployeeRepository(),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('provision-selected-employee-dialog')),
        findsNothing,
      );
      expect(repository.detailEmployeeIds, ['employee-2']);
      expect(find.text('李四'), findsWidgets);
    },
  );

  testWidgets(
    'unprovisioned employee is visible but cannot provision without account support',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _FakePagePermissionRepository(hasAccount: false);
      final employeeRepository = _ProvisionEmployeeRepository();

      await tester.pumpWidget(
        _settingsApp(repository, employeeRepository: employeeRepository),
      );
      await tester.pumpAndSettle();

      expect(find.text('未开通账号'), findsOneWidget);
      expect(find.text('此人还未开通账号，暂不能设置权限'), findsOneWidget);
      expect(find.text('请联系具备“账号支持”权限的人员开通登录账号。'), findsOneWidget);
      expect(repository.detailEmployeeIds, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey('page-permission-staff-employee-1')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('provision-selected-employee-dialog')),
        findsNothing,
      );
      expect(employeeRepository.provisionCalls, 0);
    },
  );

  testWidgets('account support can cancel selected employee provisioning', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _FakePagePermissionRepository(hasAccount: false);
    final employeeRepository = _ProvisionEmployeeRepository();

    await tester.pumpWidget(
      _settingsApp(
        repository,
        permissions: const {Perm.accountSupport},
        employeeRepository: employeeRepository,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('page-permission-staff-employee-1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('开通账号确认'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('provision-selected-employee-cancel')),
    );
    await tester.pumpAndSettle();

    expect(employeeRepository.provisionCalls, 0);
    expect(find.text('此人还未开通账号，暂不能设置权限'), findsOneWidget);
    expect(repository.detailEmployeeIds, isEmpty);
  });

  testWidgets(
    'successful provisioning waits once, shows credentials, then loads permissions',
    (tester) async {
      tester.view.physicalSize = const Size(900, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _FakePagePermissionRepository(hasAccount: false);
      final employeeRepository = _ProvisionEmployeeRepository(
        onProvisioned: () => repository.hasAccount = true,
      );

      await tester.pumpWidget(
        _settingsApp(
          repository,
          permissions: const {Perm.accountSupport},
          employeeRepository: employeeRepository,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('page-permission-staff-employee-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('provision-selected-employee-confirm')),
      );
      await tester.pump();

      expect(employeeRepository.provisionCalls, 1);
      expect(find.text('开通中'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('provision-selected-employee-confirm')),
            )
            .onPressed,
        isNull,
      );

      employeeRepository.completeSuccess();
      await tester.pumpAndSettle();

      expect(find.text('账号已创建'), findsOneWidget);
      expect(repository.detailEmployeeIds, isEmpty);
      await tester.tap(find.text('我已妥善保存'));
      await tester.pumpAndSettle();

      expect(repository.detailEmployeeIds, ['employee-1']);
      expect(find.text('销售订货查看'), findsOneWidget);
      expect(employeeRepository.provisionCalls, 1);
    },
  );
}

Widget _actionApp({required bool canManage, bool superAdmin = false}) {
  final router = GoRouter(
    initialLocation: '/sales/orders',
    routes: [
      GoRoute(
        path: '/sales/orders',
        builder: (_, _) => const Scaffold(
          appBar: UtenAppBar(title: '销售订货'),
          body: SizedBox.expand(),
        ),
      ),
      GoRoute(
        path: '/page-permissions/:surfaceKey',
        builder: (_, _) => const Scaffold(body: Text('独立权限设置页')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      isSuperAdminProvider.overrideWithValue(superAdmin),
      pageDelegationCapabilityProvider.overrideWith(
        (ref, surfaceKey) async => PageDelegationCapability(
          surfaceKey: surfaceKey,
          superAdmin: superAdmin,
          canManage: canManage,
        ),
      ),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

Widget _settingsApp(
  PagePermissionDelegationRepository repository, {
  Set<String> permissions = const {},
  EmployeeRepository? employeeRepository,
}) {
  return ProviderScope(
    overrides: [
      pagePermissionDelegationRepositoryProvider.overrideWithValue(repository),
      currentPermissionsProvider.overrideWithValue(permissions),
      if (employeeRepository != null)
        employeeRepositoryProvider.overrideWithValue(employeeRepository),
    ],
    child: const MaterialApp(
      locale: Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PagePermissionSettingsPage(surfaceKey: 'sales.order'),
    ),
  );
}

class _FakePagePermissionRepository
    implements PagePermissionDelegationRepository {
  _FakePagePermissionRepository({
    this.totalPages = 1,
    this.departmentName = '销售一组',
    this.accountActive = true,
    this.hasAccount = true,
    this.staffItems,
  });

  final int totalPages;
  final String departmentName;
  final bool accountActive;
  bool hasAccount;
  final List<PagePermissionStaffSummary>? staffItems;
  String? lastSearch;
  final List<int> requestedPages = [];
  final List<String?> requestedDepartments = [];
  final List<String> detailEmployeeIds = [];
  List<PagePermissionChange> savedChanges = const [];

  @override
  Future<PageDelegationCapability> capability(String surfaceKey) async =>
      PageDelegationCapability(
        surfaceKey: surfaceKey,
        superAdmin: false,
        canManage: true,
      );

  @override
  Future<List<ManagedPermissionDepartment>> managedDepartments(
    String surfaceKey,
  ) async => [
    ManagedPermissionDepartment(
      departmentId: 'department-1',
      departmentName: departmentName,
      level: '二级班组',
      code: 'DEPT_SALES_1',
      sortOrder: 10,
    ),
    const ManagedPermissionDepartment(
      departmentId: 'department-2',
      departmentName: '研发部',
      level: '一级部门',
      code: 'DEPT_RD',
      sortOrder: 20,
    ),
  ];

  @override
  Future<PagePermissionStaffPage> staffPage({
    required String surfaceKey,
    String? departmentId,
    String? search,
    int page = 1,
    int size = 40,
  }) async {
    lastSearch = search;
    requestedPages.add(page);
    requestedDepartments.add(departmentId);
    final items = page == 1
        ? staffItems ??
              [
                PagePermissionStaffSummary(
                  employeeId: 'employee-1',
                  departmentId: 'department-1',
                  departmentName: departmentName,
                  code: 'S001',
                  fullName: '张三',
                  positionName: '业务员',
                  departmentManager: false,
                  hasAccount: hasAccount,
                  accountActive: hasAccount && accountActive,
                ),
              ]
        : [
            PagePermissionStaffSummary(
              employeeId: 'employee-2',
              departmentId: 'department-1',
              departmentName: departmentName,
              code: 'S002',
              fullName: '李四',
              positionName: '业务员',
              departmentManager: false,
              hasAccount: true,
              accountActive: accountActive,
            ),
          ];
    return PagePermissionStaffPage(
      surfaceKey: surfaceKey,
      departmentId: departmentId,
      departmentName: departmentId == null ? null : departmentName,
      items: items,
      page: page,
      size: size,
      total: staffItems?.length ?? (totalPages == 1 ? 1 : 2),
      totalPages: totalPages,
    );
  }

  @override
  Future<PagePermissionEmployeeDetail> employeePermissions({
    required String surfaceKey,
    required String departmentId,
    required String employeeId,
  }) async {
    detailEmployeeIds.add(employeeId);
    return _detail(surfaceKey, departmentId, employeeId);
  }

  @override
  Future<PagePermissionEmployeeDetail> saveEmployeePermissions({
    required String surfaceKey,
    required String departmentId,
    required String employeeId,
    required List<PagePermissionChange> changes,
  }) async {
    savedChanges = List.of(changes);
    return _detail(surfaceKey, departmentId, employeeId, editEnabled: true);
  }
}

class _ProvisionEmployeeRepository extends Fake implements EmployeeRepository {
  _ProvisionEmployeeRepository({this.onProvisioned});

  final VoidCallback? onProvisioned;
  final Completer<EmployeeOnboardingResult> _completer =
      Completer<EmployeeOnboardingResult>();
  int provisionCalls = 0;

  @override
  Future<EmployeeOnboardingResult> provisionAccount(String id) {
    provisionCalls++;
    return _completer.future;
  }

  void completeSuccess() {
    onProvisioned?.call();
    _completer.complete(
      const EmployeeOnboardingResult(
        employee: EmployeeProfile(
          id: 'employee-1',
          code: 'S001',
          fullName: '张三',
          departmentId: 'department-1',
          departmentName: '销售一组',
          positionName: '业务员',
          status: 'active',
          phone: '13800138000',
          accountStatus: 'active',
        ),
        temporaryPassword: '123456',
        loginAccount: '13800138000',
      ),
    );
  }
}

PagePermissionEmployeeDetail _detail(
  String surfaceKey,
  String departmentId,
  String employeeId, {
  bool editEnabled = false,
}) => PagePermissionEmployeeDetail(
  surfaceKey: surfaceKey,
  departmentId: departmentId,
  departmentName: '销售一组',
  employeeId: employeeId,
  code: employeeId == 'employee-2' ? 'S002' : 'S001',
  fullName: employeeId == 'employee-2' ? '李四' : '张三',
  positionName: '业务员',
  departmentManager: false,
  hasAccount: true,
  superAdminMode: false,
  permissions: [
    const PageStaffPermissionState(
      code: Perm.salesOrderView,
      name: '销售订货查看',
      actionType: PermissionActionType.view,
      description: '查看销售订货列表和详情',
      baseEffective: true,
      delegationEnabled: false,
      rowVersion: 0,
      effective: true,
      editable: false,
      reason: '部门权限已生效',
    ),
    PageStaffPermissionState(
      code: Perm.salesOrderEdit,
      name: '销售订货编辑',
      actionType: PermissionActionType.edit,
      description: '编辑销售订货草稿',
      baseEffective: false,
      delegationEnabled: editEnabled,
      rowVersion: editEnabled ? 1 : 0,
      effective: editEnabled,
      editable: true,
    ),
    const PageStaffPermissionState(
      code: Perm.salesOrderPriority,
      name: '销售订单优先级',
      actionType: PermissionActionType.execute,
      description: '设置销售订单行优先级',
      baseEffective: false,
      delegationEnabled: true,
      rowVersion: 3,
      effective: false,
      editable: true,
      reason: '历史委派已失效，仅允许关闭',
    ),
  ],
);
