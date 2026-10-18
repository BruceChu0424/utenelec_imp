import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/admin/widgets/page_permission_drawer.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_models.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_repository.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final superAdmin in [true, false]) {
    testWidgets('页面客户范围入口保持独立授权 superAdmin=$superAdmin', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final admin = _ScopeRepository();
      final adminState = StateProvider<bool>((ref) => superAdmin);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pagePermissionDelegationRepositoryProvider.overrideWithValue(
              _Repository(withClientScope: true),
            ),
            adminRepositoryProvider.overrideWithValue(admin),
            sharedPreferencesProvider.overrideWithValue(preferences),
            isSuperAdminProvider.overrideWith((ref) => ref.watch(adminState)),
            currentPermissionsProvider.overrideWithValue({
              Perm.authorizationManage,
            }),
          ],
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: PagePermissionDrawer(
              scope: PagePermissionScope(
                surfaceKey: 'basic.client',
                title: '客户资料',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('page-permission-staff-active')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('可查看数据范围'), findsOneWidget);
      expect(find.textContaining('本人负责及被指定共享的客户'), findsOneWidget);
      final entry = find.byKey(const ValueKey('page-data-scope-entry'));
      if (superAdmin) {
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expect(admin.targetEmployee, 'active');
        expect(admin.loadedScopes, ['client']);
        expect(find.text('仅本人'), findsOneWidget);
        expect(find.text('财务单据可见负责人'), findsNothing);
        expect(find.text('人员数据交接'), findsNothing);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(PagePermissionDrawer)),
        );
        final oldTarget = Completer<AdminUserSummary>();
        admin.delayedTarget = oldTarget;
        container.read(adminState.notifier).state = false;
        await tester.pumpAndSettle();
        expect(find.text('需要超级管理员配置可查看数据范围'), findsOneWidget);
        container.read(adminState.notifier).state = true;
        await tester.pump();
        await tester.pump();
        expect(admin.targetCalls, 2);
        admin.delayedTarget = null;
        container.read(adminState.notifier).state = false;
        await tester.pumpAndSettle();
        container.read(adminState.notifier).state = true;
        await tester.pumpAndSettle();
        expect(admin.targetCalls, 3);
        expect(admin.effectiveCalls, 2);
        oldTarget.complete(
          const AdminUserSummary(
            id: 'old-account',
            loginAccount: 'old-login',
            status: 'disabled',
            employeeId: 'active',
            currentEmployee: true,
            mustChangePassword: false,
            remoteAccess: false,
          ),
        );
        await tester.pumpAndSettle();
        expect(admin.effectiveCalls, 2, reason: '旧请求不得继续查询旧账号权限');
        expect(find.text('仅本人'), findsOneWidget);
        expect(find.textContaining('账号未启用'), findsNothing);
      } else {
        expect(entry, findsNothing);
        expect(admin.targetEmployee, isNull);
      }
      expect(tester.takeException(), isNull);
    });
  }
  for (final width in [320.0, 390.0]) {
    testWidgets('权限选人 $width 窄屏保留部门和未开通员工状态且不溢出', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository();
      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      expect(find.byType(UtenDepartmentTreeView), findsNothing);
      await tester.tap(find.byIcon(Icons.account_tree_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(UtenDepartmentTreeView), findsOneWidget);
      await tester.tap(find.byTooltip('返回内容'));
      await tester.pumpAndSettle();
      expect(find.text('胡钟炎'), findsOneWidget);
      expect(find.text('UT0006'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('胡钟炎'));
      await tester.pumpAndSettle();
      expect(repository.detailCalls, 0);
      expect(find.text('已选择：胡钟炎(UT0006)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('权限部门树只消费可管理组织，骨架节点只展开且不扩大人员查询', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _Repository();
    await tester.pumpWidget(_app(repository));
    await tester.pumpAndSettle();

    expect(repository.requestedDepartments, [null]);
    await tester.tap(find.text('可见管理中心'));
    await tester.pumpAndSettle();
    expect(repository.requestedDepartments, [null]);
    await tester.tap(
      find.descendant(
        of: find.byType(UtenDepartmentTreeView),
        matching: find.text('销售部'),
      ),
    );
    await tester.pumpAndSettle();
    expect(repository.requestedDepartments, [null, 'sales']);
    final tree = tester.widget<UtenDepartmentTreeView>(
      find.byType(UtenDepartmentTreeView),
    );
    expect(tree.nodes.map((node) => node.id), ['skeleton']);
    expect(tree.nodeEnabledPredicate!(tree.nodes.single), isFalse);
    expect(tree.selectedIds, {'sales'});
  });

  testWidgets('权限员工表展示重点信息，选中员工仍保留账号状态', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _Repository();
    await tester.pumpWidget(_app(repository));
    await tester.pumpAndSettle();

    final table = tester
        .widget<MasterDataTableView<PagePermissionStaffSummary>>(
          find.byKey(const ValueKey('page-permission-staff-table')),
        );
    expect(table.columns.map((column) => column.label), [
      '姓名',
      '工号',
      '部门',
      '岗位',
      '账号状态',
      '在职状态',
    ]);
    expect(find.text('胡钟炎'), findsOneWidget);
    expect(find.text('UT0006'), findsOneWidget);
    expect(find.text('销售员'), findsNWidgets(2));
    final accountStatus = find.byKey(
      const ValueKey('page-permission-account-status-unprovisioned'),
    );
    expect(accountStatus, findsOneWidget);
    await tester.tap(find.text('员工乙'));
    await tester.pumpAndSettle();
    expect(accountStatus, findsOneWidget);
    expect(repository.detailCalls, 0);
    expect(find.text('已选择：员工乙(UT0007)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('权限部门栏缩到160后搜索清除和层级操作保持可用', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _Repository();
    await tester.pumpWidget(_app(repository));
    await tester.pumpAndSettle();
    await tester.drag(find.byTooltip('拖动调整宽度 · 双击复位'), const Offset(-1400, 0));
    await tester.pumpAndSettle();
    final tree = find.byType(UtenDepartmentTreeView);
    expect(tester.getSize(tree).width, 160);
    final search = find.descendant(of: tree, matching: find.byType(TextField));
    // 2026-10-18 左缘贴 0 口径：左栏搜索框水平内边距为 0，贴满面板宽。
    expect(tester.getSize(search).width, 160);
    await tester.enterText(search, 'UT0006');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(repository.searches.last, 'UT0006');
    final clear = find.byTooltip('清除搜索');
    expect(tester.getRect(tree).contains(tester.getRect(clear).center), isTrue);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(repository.searches.last, '');
    await tester.tap(find.text('可见管理中心'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: tree, matching: find.text('销售部')));
    await tester.pumpAndSettle();
    expect(repository.requestedDepartments.last, 'sales');
    expect(tester.getSize(tree).width, 160);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(_Repository repository) => ProviderScope(
  overrides: [
    pagePermissionDelegationRepositoryProvider.overrideWithValue(repository),
    currentPermissionsProvider.overrideWithValue(const {}),
  ],
  child: MaterialApp(
    theme: ThemeData(platform: TargetPlatform.windows),
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const PagePermissionDrawer(
      scope: PagePermissionScope(surfaceKey: 'sales.order', title: '销售订货'),
    ),
  ),
);

class _Repository implements PagePermissionDelegationRepository {
  _Repository({this.withClientScope = false});
  final bool withClientScope;
  final requestedDepartments = <String?>[];
  final searches = <String?>[];
  var detailCalls = 0;

  @override
  Future<List<ManagedPermissionDepartment>> managedDepartments(
    String surfaceKey,
  ) async => const [
    ManagedPermissionDepartment(
      departmentId: 'skeleton',
      departmentName: '可见管理中心',
      level: '管理中心',
      selectable: false,
    ),
    ManagedPermissionDepartment(
      departmentId: 'sales',
      departmentName: '销售部',
      level: '一级部门',
      parentId: 'skeleton',
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
    requestedDepartments.add(departmentId);
    searches.add(search);
    return PagePermissionStaffPage(
      surfaceKey: surfaceKey,
      departmentId: departmentId,
      departmentName: '销售部',
      items: [
        for (final id in ['active', 'unprovisioned'])
          PagePermissionStaffSummary(
            employeeId: id,
            departmentId: 'sales',
            departmentName: '销售部',
            fullName: id == 'active' ? '胡钟炎' : '员工乙',
            code: id == 'active' ? 'UT0006' : 'UT0007',
            positionName: '销售员',
            departmentManager: false,
            hasAccount: id == 'active',
            accountActive: id == 'active',
            accountStatus: id == 'active' ? 'active' : 'notProvisioned',
            employmentStatus: id == 'active' ? 'onLeave' : 'probation',
          ),
      ],
      page: page,
      size: size,
      total: 2,
      totalPages: 1,
    );
  }

  @override
  Future<PagePermissionEmployeeDetail> employeePermissions({
    required String surfaceKey,
    required String departmentId,
    required String employeeId,
  }) async {
    detailCalls++;
    if (withClientScope) {
      return PagePermissionEmployeeDetail(
        surfaceKey: surfaceKey,
        surfaceTitle: '客户资料',
        departmentId: departmentId,
        departmentName: '销售部',
        employeeId: employeeId,
        fullName: '胡钟炎',
        departmentManager: false,
        hasAccount: true,
        superAdminMode: true,
        groups: const [
          PagePermissionSurfaceGroup(
            surfaceKey: 'basic.client',
            title: '客户资料',
            root: true,
            permissions: [
              PageStaffPermissionState(
                code: 'client:view:all',
                name: '查看全部客户资料',
                baseEffective: false,
                delegationEnabled: false,
                rowVersion: 0,
                effective: false,
                editable: true,
              ),
            ],
          ),
        ],
      );
    }
    throw UnsupportedError('This layout test does not load permission details');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ScopeRepository implements AdminRepository {
  String? targetEmployee;
  Completer<AdminUserSummary>? delayedTarget;
  int targetCalls = 0;
  int effectiveCalls = 0;
  final loadedScopes = <String>[];

  @override
  Future<AdminUserSummary> userByEmployeeId(String employeeId) async {
    targetEmployee = employeeId;
    targetCalls++;
    if (delayedTarget != null) return delayedTarget!.future;
    return const AdminUserSummary(
      id: 'account',
      employeeId: 'active',
      employeeName: '胡钟炎',
      employeeStatus: 'active',
      currentEmployee: true,
      loginAccount: '13800000000',
      status: 'active',
      mustChangePassword: false,
      remoteAccess: false,
    );
  }

  @override
  Future<EffectivePermissions> effectivePermissions(String userId) async {
    effectiveCalls++;
    return const EffectivePermissions(
      departmentPermissions: [],
      baselinePermissions: [],
      grants: [],
      revokes: [],
      effective: ['client:view'],
    );
  }

  @override
  Future<List<DataScopeCatalogItem>> dataScopeCatalog() async => const [
    DataScopeCatalogItem(
      scope: 'client',
      label: '客户资料可见负责人',
      description: '指定负责人',
      viewAllPermission: 'client:view:all',
      enabled: true,
      group: '客户与销售',
    ),
    DataScopeCatalogItem(
      scope: 'finance',
      label: '财务单据可见负责人',
      description: '财务',
      viewAllPermission: 'finance:view:all',
      enabled: true,
      group: '财务',
    ),
  ];

  @override
  Future<List<String>> getUserDataScopes(String userId, String scope) async {
    loadedScopes.add(scope);
    return [];
  }

  @override
  Future<List<DataScopeOwner>> dataScopeOwners(String scope) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
