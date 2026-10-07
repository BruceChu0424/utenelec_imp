import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';
import 'package:uten_imp/features/admin/widgets/page_permission_drawer.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_models.dart';
import 'package:uten_imp/shared/auth/page_permission_action.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_repository.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';
import 'package:uten_imp/shared/auth/permission_action_type.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';

void main() {
  testWidgets('AI permission shortcut opens the dedicated common drawer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _actionApp(
        canManage: true,
        superAdmin: true,
        scope: aiUsePermissionScope,
        label: 'AI 使用权限',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('AI 使用权限'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('page-permission-action')));
    await tester.pumpAndSettle();
    final drawer = tester.widget<PagePermissionDrawer>(
      find.byType(PagePermissionDrawer),
    );
    expect(drawer.scope.surfaceKey, 'system.ai-assistant');
    expect(find.text('AI 使用 · 页面权限'), findsOneWidget);
  });

  testWidgets('AI shortcut cannot bypass the server delegation capability', (
    tester,
  ) async {
    await tester.pumpWidget(
      _actionApp(
        canManage: false,
        superAdmin: true,
        scope: aiUsePermissionScope,
        label: 'AI 使用权限',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('page-permission-action')), findsNothing);
  });

  testWidgets(
    'delegation entry closes during retained-data refresh and failure',
    (tester) async {
      await tester.pumpWidget(_actionApp(canManage: true));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(UtenAppBar)),
      );
      final notifier =
          container.read(sessionSnapshotProvider.notifier) as _FixedSnapshot;
      final previous = container.read(sessionSnapshotProvider);
      expect(
        find.byKey(const ValueKey('page-permission-action')),
        findsOneWidget,
      );
      notifier.emit(
        const AsyncLoading<SessionSnapshot?>().copyWithPrevious(previous),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('page-permission-action')),
        findsNothing,
      );
      notifier.emit(
        AsyncError<SessionSnapshot?>(
          StateError('revoked'),
          StackTrace.current,
        ).copyWithPrevious(previous),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('page-permission-action')),
        findsNothing,
      );
      notifier.emit(AsyncData(SessionSnapshot()));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('page-permission-action')),
        findsNothing,
      );
    },
  );
  test('models parse grouped backend workspace DTO shapes', () {
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
      'surfaceKey': 'sales.hub',
      'surfaceTitle': '销售管理',
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
      'groups': [
        {
          'surfaceKey': 'sales.hub',
          'title': '销售管理',
          'root': true,
          'permissions': [
            {
              'code': 'sales_order:priority',
              'name': '销售订单优先级',
              'actorEffective': true,
              'targetBaseEffective': true,
              'effective': true,
              'configuredEffect': 'grant',
              'rowVersion': 3,
              'editable': true,
            },
          ],
        },
        {
          'surfaceKey': 'sales.quote',
          'title': '销售报价',
          'root': false,
          'permissions': [
            {
              'code': 'sales_quote:view',
              'name': '销售报价查看',
              'actorEffective': true,
              'targetBaseEffective': true,
              'effective': true,
              'configuredEffect': 'grant',
              'rowVersion': 1,
              'editable': true,
            },
          ],
        },
      ],
    });

    expect(staff.items.single.fullName, '张三');
    expect(staff.items.single.departmentName, '销售一组');
    expect(staff.items.single.accountActive, isTrue);
    expect(detail.superAdminMode, isTrue);
    expect(detail.surfaceTitle, '销售管理');
    expect(detail.groups, hasLength(2));
    expect(detail.groups.first.root, isTrue);
    expect(detail.groups.last.title, '销售报价');
    expect(detail.permissions, hasLength(2));
    expect(detail.permissions.first.baseEffective, isTrue);
    expect(detail.permissions.first.delegationEnabled, isTrue);
  });

  testWidgets('ordinary employee does not see permission settings action', (
    tester,
  ) async {
    await tester.pumpWidget(_actionApp(canManage: false));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('page-permission-action')), findsNothing);
  });

  testWidgets('enabled super admin opens in-place drawer with grouped tree', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_actionApp(canManage: true, superAdmin: true));
    await tester.pumpAndSettle();

    final action = find.byKey(const ValueKey('page-permission-action'));
    expect(action, findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();

    expect(find.byType(PagePermissionDrawer), findsOneWidget);
    expect(find.text('销售订货 · 页面权限'), findsOneWidget);
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

  testWidgets(
    'drawer groups by family, merges create into edit, and submits one atomic diff',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _FakePagePermissionRepository();

      await tester.pumpWidget(_drawerApp(repository));
      await tester.pumpAndSettle();

      // 选人前是选人视图：部门筛选 + 人员列表。
      expect(find.text('张三(S001)'), findsOneWidget);
      expect(find.text('销售订货查看'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('page-permission-staff-employee-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pumpAndSettle();

      // 普通页面（单根组）：不重复分组头，族行直接铺开。
      expect(find.text('销售管理 · 本页'), findsNothing);
      // 族折叠态：只看到族行（查看/编辑合并/执行·办理），明细行不可见。
      expect(find.text('查看'), findsOneWidget);
      expect(find.text('编辑（含新增与修改）'), findsOneWidget);
      expect(find.text('执行·办理'), findsOneWidget);
      expect(find.text('销售订货编辑'), findsNothing);

      // 展开编辑族：新增与修改两颗明细开关都在里面。
      await tester.tap(find.text('编辑（含新增与修改）'));
      await tester.pumpAndSettle();
      expect(find.text('销售订货编辑'), findsOneWidget);
      expect(find.text('销售订贷新增'), findsOneWidget);

      // 历史委派行在「执行·办理」族里，同样先展开。
      await tester.tap(find.text('执行·办理'));
      await tester.pumpAndSettle();
      final historical = tester.widget<Switch>(
        find.byKey(
          const ValueKey('page-permission-employee-1-sales_order:priority'),
        ),
      );
      expect(historical.value, isTrue);

      await tester.tap(
        find.byKey(
          const ValueKey('page-permission-employee-1-sales_order:edit'),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('page-permission-save')));
      await tester.pumpAndSettle();

      expect(repository.savedChanges, hasLength(1));
      expect(repository.savedChanges.single.code, Perm.salesOrderEdit);
      expect(repository.savedChanges.single.enabled, isTrue);
      expect(repository.savedChanges.single.expectedVersion, 0);
    },
  );

  testWidgets('hub drawer renders one section per child surface', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _FakePagePermissionRepository(hubTree: true);

    await tester.pumpWidget(_drawerApp(repository));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('page-permission-staff-employee-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    // hub 树：根面组保留没被认领的码，子面组各成一个分组条。
    expect(find.text('销售管理 · 本页'), findsOneWidget);
    expect(find.text('销售报价'), findsOneWidget);
    expect(find.text('销售订货'), findsOneWidget);
    expect(find.byType(PagePermissionDrawer), findsOneWidget);
  });

  testWidgets('family checkbox grants the whole family in one batch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _FakePagePermissionRepository();

    await tester.pumpWidget(_drawerApp(repository));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('page-permission-staff-employee-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    // 编辑族三态开关：一键全开 = 新增+修改两颗都进待提交集合。
    final familyRow = find.ancestor(
      of: find.text('编辑（含新增与修改）'),
      matching: find.byType(InkWell),
    );
    final checkbox = find.descendant(
      of: familyRow,
      matching: find.byType(Checkbox),
    );
    await tester.tap(checkbox);
    await tester.pump();
    expect(find.text('已修改 2 项'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('page-permission-save')));
    await tester.pumpAndSettle();
    expect(repository.savedChanges, hasLength(2));
    expect(repository.savedChanges.map((change) => change.code).toSet(), {
      Perm.salesOrderEdit,
      Perm.salesOrderCreate,
    });
  });

  testWidgets(
    'department is optional, uses managed tree and can clear to all',
    (tester) async {
      tester.view.physicalSize = const Size(900, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _FakePagePermissionRepository();

      await tester.pumpWidget(_drawerApp(repository));
      await tester.pumpAndSettle();

      final picker = tester.widget<UtenDepartmentTreeView>(
        find.byType(UtenDepartmentTreeView),
      );
      expect(picker.selectedIds, isEmpty);
      expect(picker.nodes, isNotEmpty);
      expect(picker.flatLevelColors, isTrue);
      expect(repository.requestedDepartments.first, isNull);
      expect(find.text('全部可管理部门'), findsOneWidget);
      final tree = find.byType(UtenDepartmentTreeView);
      await tester.tap(find.descendant(of: tree, matching: find.text('销售一组')));
      await tester.pumpAndSettle();
      expect(repository.requestedDepartments.last, 'department-1');
      expect(find.text('共 1 人'), findsOneWidget);
      await tester.tap(find.text('全部可管理部门'));
      await tester.pumpAndSettle();
      expect(repository.requestedDepartments.last, isNull);
    },
  );

  testWidgets('dirty state guards switching person and closing the drawer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _FakePagePermissionRepository();

    await tester.pumpWidget(_drawerApp(repository));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('page-permission-staff-employee-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('编辑（含新增与修改）'));
    await tester.pumpAndSettle();
    final editSwitch = find.byKey(
      const ValueKey('page-permission-employee-1-sales_order:edit'),
    );
    await tester.tap(editSwitch);
    await tester.pump();
    expect(tester.widget<Switch>(editSwitch).value, isTrue);
    expect(find.text('已修改 1 项'), findsOneWidget);

    // 换人需确认；取消则保持待提交状态。
    await tester.tap(find.text('更换'));
    await tester.pumpAndSettle();
    expect(find.text('丢弃未保存修改'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(editSwitch).value, isTrue);

    // 系统返回键也必须守住未保存修改，不能绕过抽屉上的关闭按钮。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('丢弃未保存修改'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(editSwitch).value, isTrue);

    // 关闭同样拦截。
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('丢弃未保存修改'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(PagePermissionDrawer), findsOneWidget);

    // 撤销修改恢复原值后即可直接关闭。
    await tester.tap(find.text('撤销修改'));
    await tester.pump();
    expect(tester.widget<Switch>(editSwitch).value, isFalse);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(PagePermissionDrawer), findsNothing);
  });

  testWidgets('search is debounced on server and staff list loads next page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _FakePagePermissionRepository(totalPages: 2);

    await tester.pumpWidget(_drawerApp(repository));
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
    'unprovisioned employee is visible but cannot provision without account support',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _FakePagePermissionRepository(hasAccount: false);
      final employeeRepository = _ProvisionEmployeeRepository();

      await tester.pumpWidget(
        _drawerApp(repository, employeeRepository: employeeRepository),
      );
      await tester.pumpAndSettle();

      expect(find.text('未开通账号'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('page-permission-staff-employee-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('provision-selected-employee-dialog')),
        findsNothing,
      );
      expect(employeeRepository.provisionCalls, 0);
      expect(find.text('此人还未开通账号，暂不能设置权限'), findsOneWidget);
      expect(find.text('请联系具备“账号支持”权限的人员开通登录账号。'), findsOneWidget);
      expect(repository.detailEmployeeIds, isEmpty);
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
      _drawerApp(
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
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
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
        _drawerApp(
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
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('provision-selected-employee-confirm')),
      );
      await tester.pump();

      expect(employeeRepository.readinessCalls, 1);
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
      expect(find.text('查看'), findsOneWidget);
      expect(employeeRepository.provisionCalls, 1);
    },
  );
}

Widget _actionApp({
  required bool canManage,
  bool superAdmin = false,
  PagePermissionScope? scope,
  String label = '权限设置',
}) {
  final router = GoRouter(
    initialLocation: '/sales/orders',
    routes: [
      GoRoute(
        path: '/sales/orders',
        builder: (_, _) => Scaffold(
          appBar: UtenAppBar(
            title: '销售订货',
            showPagePermissionAction: scope == null,
            actions: [
              if (scope != null)
                PagePermissionAction(scope: scope, label: label),
            ],
          ),
          body: const SizedBox.expand(),
        ),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      isSuperAdminProvider.overrideWithValue(superAdmin),
      // 可委派页面随会话快照(/auth/me)一次带回(ADR-108), 不再逐页请求 capability。
      sessionSnapshotProvider.overrideWith(
        () => _FixedSnapshot(
          SessionSnapshot(
            delegableSurfaceKeys: {
              if (canManage)
                (scope ?? pagePermissionScopeFor('/sales/orders')!).surfaceKey,
            },
          ),
        ),
      ),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

Widget _drawerApp(
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
      home: PagePermissionDrawer(
        scope: PagePermissionScope(surfaceKey: 'sales.order', title: '销售订货'),
      ),
    ),
  );
}

class _FakePagePermissionRepository
    implements PagePermissionDelegationRepository {
  _FakePagePermissionRepository({
    this.totalPages = 1,
    this.hasAccount = true,
    this.hubTree = false,
  });

  final int totalPages;
  bool hasAccount;
  final bool hubTree;
  String? lastSearch;
  final List<int> requestedPages = [];
  final List<String?> requestedDepartments = [];
  final List<String> detailEmployeeIds = [];
  List<PagePermissionChange> savedChanges = const [];

  @override
  Future<List<ManagedPermissionDepartment>> managedDepartments(
    String surfaceKey,
  ) async => [
    const ManagedPermissionDepartment(
      departmentId: 'department-1',
      departmentName: '销售一组',
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
    final items = [
      PagePermissionStaffSummary(
        employeeId: 'employee-1',
        departmentId: 'department-1',
        departmentName: '销售一组',
        code: 'S001',
        fullName: '张三',
        positionName: '业务员',
        departmentManager: false,
        hasAccount: hasAccount,
        accountActive: hasAccount,
      ),
    ];
    return PagePermissionStaffPage(
      surfaceKey: surfaceKey,
      departmentId: departmentId,
      departmentName: departmentId == null ? null : '销售一组',
      items: items,
      page: page,
      size: size,
      total: totalPages == 1 ? 1 : 2,
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
    return _detail(surfaceKey, departmentId, employeeId, hubTree: hubTree);
  }

  @override
  Future<PagePermissionEmployeeDetail> saveEmployeePermissions({
    required String surfaceKey,
    required String departmentId,
    required String employeeId,
    required List<PagePermissionChange> changes,
  }) async {
    savedChanges = List.of(changes);
    return _detail(
      surfaceKey,
      departmentId,
      employeeId,
      hubTree: hubTree,
      granted: {
        for (final change in changes)
          if (change.enabled) change.code: true,
      },
    );
  }
}

class _ProvisionEmployeeRepository extends Fake implements EmployeeRepository {
  _ProvisionEmployeeRepository({this.onProvisioned});

  final VoidCallback? onProvisioned;
  final Completer<EmployeeOnboardingResult> _completer =
      Completer<EmployeeOnboardingResult>();
  int provisionCalls = 0;
  int readinessCalls = 0;

  /// 开号确认弹窗一打开就读就绪检查：有手机号、证件没问题(提醒类用例见
  /// test/features/employee/employee_account_provision_flow_test.dart)。
  @override
  Future<EmployeeAccountReadiness> accountReadiness(String id) async {
    readinessCalls++;
    return const EmployeeAccountReadiness(hasPhone: true);
  }

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
  bool hubTree = false,
  Map<String, bool> granted = const {},
}) {
  final orderStates = [
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
      delegationEnabled: granted[Perm.salesOrderEdit] ?? false,
      rowVersion: granted.containsKey(Perm.salesOrderEdit) ? 1 : 0,
      effective: granted[Perm.salesOrderEdit] ?? false,
      editable: true,
    ),
    PageStaffPermissionState(
      code: Perm.salesOrderCreate,
      name: '销售订贷新增',
      actionType: PermissionActionType.create,
      description: '新增销售订货单',
      baseEffective: false,
      delegationEnabled: granted[Perm.salesOrderCreate] ?? false,
      rowVersion: granted.containsKey(Perm.salesOrderCreate) ? 1 : 0,
      effective: granted[Perm.salesOrderCreate] ?? false,
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
  ];
  if (hubTree) {
    return PagePermissionEmployeeDetail(
      surfaceKey: 'sales.hub',
      surfaceTitle: '销售管理',
      departmentId: departmentId,
      departmentName: '销售一组',
      employeeId: employeeId,
      code: 'S001',
      fullName: '张三',
      positionName: '业务员',
      departmentManager: false,
      hasAccount: true,
      superAdminMode: false,
      groups: [
        PagePermissionSurfaceGroup(
          surfaceKey: 'sales.hub',
          title: '销售管理',
          root: true,
          permissions: [orderStates[3]],
        ),
        PagePermissionSurfaceGroup(
          surfaceKey: 'sales.quote',
          title: '销售报价',
          root: false,
          permissions: [orderStates[0]],
        ),
        PagePermissionSurfaceGroup(
          surfaceKey: 'sales.order',
          title: '销售订货',
          root: false,
          permissions: [orderStates[1], orderStates[2]],
        ),
      ],
    );
  }
  return PagePermissionEmployeeDetail(
    surfaceKey: surfaceKey,
    surfaceTitle: '销售订货',
    departmentId: departmentId,
    departmentName: '销售一组',
    employeeId: employeeId,
    code: 'S001',
    fullName: '张三',
    positionName: '业务员',
    departmentManager: false,
    hasAccount: true,
    superAdminMode: false,
    groups: [
      PagePermissionSurfaceGroup(
        surfaceKey: surfaceKey,
        title: '销售订货',
        root: true,
        permissions: orderStates,
      ),
    ],
  );
}

class _FixedSnapshot extends SessionSnapshotNotifier {
  _FixedSnapshot(this._snapshot);

  final SessionSnapshot _snapshot;
  void emit(AsyncValue<SessionSnapshot?> value) => state = value;

  @override
  Future<SessionSnapshot?> build() async => _snapshot;
}
