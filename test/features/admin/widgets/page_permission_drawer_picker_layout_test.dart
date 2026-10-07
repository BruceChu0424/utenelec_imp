import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/admin/widgets/page_permission_drawer.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_models.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_repository.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets('权限选人 $width 窄屏保留部门和未开通员工状态且不溢出', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository();
      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      expect(find.byType(UtenDepartmentTreeView), findsOneWidget);
      expect(find.text('胡钟炎(UT0006)'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.byKey(const ValueKey('page-permission-staff-active')),
      );
      await tester.pumpAndSettle();
      expect(repository.detailCalls, 0);
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
}

Widget _app(_Repository repository) => ProviderScope(
  overrides: [
    pagePermissionDelegationRepositoryProvider.overrideWithValue(repository),
    currentPermissionsProvider.overrideWithValue(const {}),
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

class _Repository implements PagePermissionDelegationRepository {
  final requestedDepartments = <String?>[];
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
            departmentManager: false,
            hasAccount: id == 'active',
            accountActive: id == 'active',
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
    throw UnsupportedError('This layout test does not load permission details');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
