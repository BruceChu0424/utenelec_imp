import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_employee_multi_picker.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';
import 'package:uten_imp/features/admin/widgets/admin_data_scope_section.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/employee/providers/employee_picker_department_tree_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'owner picker requires every name code and department word within its provided authorized candidates',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            adminRepositoryProvider.overrideWithValue(_SearchScopeRepository()),
            employeePickerDepartmentTreeProvider.overrideWith(
              (ref) async => [
                DepartmentNode(
                  id: 'company',
                  code: 'COMPANY',
                  name: '测试公司',
                  level: '公司',
                  children: [
                    DepartmentNode(
                      id: 'rd',
                      code: 'RD',
                      name: '工程研发部',
                      level: '一级部门',
                      parentId: 'company',
                      children: [],
                    ),
                    DepartmentNode(
                      id: 'fin',
                      code: 'FIN',
                      name: '财务部',
                      level: '一级部门',
                      parentId: 'company',
                      children: [],
                    ),
                  ],
                ),
              ],
            ),
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue({}),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AdminDataScopeSection(
                  user: AdminUserSummary(
                    id: 'user-1',
                    employeeId: 'employee-1',
                    employeeStatus: 'active',
                    currentEmployee: true,
                    loginAccount: '13800000000',
                    status: 'active',
                    mustChangePassword: false,
                    remoteAccess: false,
                  ),
                  effectiveAsync: AsyncValue.data(
                    EffectivePermissions(
                      departmentPermissions: [],
                      baselinePermissions: [],
                      grants: [],
                      revokes: [],
                      effective: [],
                    ),
                  ),
                  viewAllPermissions: {'client:view:all'},
                  showHandover: false,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final picker = find.byWidgetPredicate((widget) {
        if (widget is! UtenEmployeeMultiPicker) return false;
        final key = widget.key;
        return key is ValueKey<String> && key.value.startsWith('scope-client-');
      });
      expect(picker, findsOneWidget);
      final pickerWidget = tester.widget<UtenEmployeeMultiPicker>(picker);
      expect(pickerWidget.enabled, isTrue);
      expect(pickerWidget.initialSelection, isEmpty);
      expect(pickerWidget.label, '额外查看哪些负责人的数据');
      expect(
        tester
            .widget<InputDecorator>(
              find.descendant(
                of: picker,
                matching: find.byType(InputDecorator),
              ),
            )
            .decoration
            .hintText,
        pickerWidget.label,
      );
      await tester.tap(picker);
      await tester.pumpAndSettle();
      final search = find.descendant(
        of: find.byKey(const Key('uten-employee-picker-search')),
        matching: find.byType(TextField),
      );
      await tester.enterText(search, '研发 张三 UT003');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('employee-picker-item-owner-match')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('employee-picker-item-owner-other')),
        findsNothing,
      );
      await tester.enterText(search, '研发 李四');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('employee-picker-item-owner-match')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('employee-picker-item-owner-other')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'switching page scope rejects an old request after returning to the same scope',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repository = _DelayedScopeRepository();
      final filter = ValueNotifier<Set<String>>({'client:view:all'});
      addTearDown(filter.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            adminRepositoryProvider.overrideWithValue(repository),
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue({}),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ValueListenableBuilder<Set<String>>(
                  valueListenable: filter,
                  builder: (_, value, _) => AdminDataScopeSection(
                    user: const AdminUserSummary(
                      id: 'user-1',
                      employeeId: 'employee-1',
                      employeeStatus: 'active',
                      currentEmployee: true,
                      loginAccount: '13800000000',
                      status: 'active',
                      mustChangePassword: false,
                      remoteAccess: false,
                    ),
                    effectiveAsync: const AsyncValue.data(
                      EffectivePermissions(
                        departmentPermissions: [],
                        baselinePermissions: [],
                        grants: [],
                        revokes: [],
                        effective: [],
                      ),
                    ),
                    viewAllPermissions: value,
                    showHandover: false,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(repository.clientRequests, 1);
      filter.value = {'finance:view:all'};
      await tester.pumpAndSettle();
      filter.value = {'client:view:all'};
      await tester.pumpAndSettle();
      expect(repository.clientRequests, 2);
      expect(find.text('仅本人'), findsOneWidget);
      repository.firstClient.complete(['old-owner']);
      await tester.pumpAndSettle();
      expect(find.text('仅本人'), findsOneWidget);
      expect(find.text('额外查看 1 人'), findsNothing);
      expect(find.text('人员数据交接'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('catalog groups finance and explains view-all/disabled states', (
    tester,
  ) async {
    final repository = _ScopeRepositoryFake();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminRepositoryProvider.overrideWithValue(repository),
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue({Perm.employeeHandover}),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AdminDataScopeSection(
                user: AdminUserSummary(
                  id: 'user-1',
                  employeeId: 'employee-1',
                  employeeStatus: 'active',
                  currentEmployee: true,
                  loginAccount: '13800000000',
                  status: 'active',
                  mustChangePassword: false,
                  remoteAccess: false,
                  employeeName: '张三',
                ),
                effectiveAsync: AsyncValue.data(
                  EffectivePermissions(
                    departmentPermissions: [],
                    baselinePermissions: [],
                    grants: [],
                    revokes: [],
                    effective: ['client:view:all'],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('可查看数据'), findsOneWidget);
    expect(find.text('客户与销售'), findsOneWidget);
    expect(find.text('财务'), findsOneWidget);
    expect(find.text('查看全部覆盖'), findsOneWidget);
    expect(find.text('功能未启用'), findsOneWidget);
    expect(find.text('当前全员可见全部货品'), findsOneWidget);
    expect(find.text('财务单据可见负责人'), findsOneWidget);
    expect(find.text('人员数据交接'), findsOneWidget);
    expect(repository.loadedScopes, ['finance']);
  });
}

class _DelayedScopeRepository extends _ScopeRepositoryFake {
  final firstClient = Completer<List<String>>();
  int clientRequests = 0;

  @override
  Future<List<String>> getUserDataScopes(String userId, String scope) async {
    if (scope == 'client' && ++clientRequests == 1) return firstClient.future;
    return [];
  }
}

class _ScopeRepositoryFake implements AdminRepository {
  final loadedScopes = <String>[];

  @override
  Future<List<DataScopeCatalogItem>> dataScopeCatalog() async => const [
    DataScopeCatalogItem(
      scope: 'client',
      label: '客户资料可见业务员',
      description: '加看指定负责人的客户',
      viewAllPermission: 'client:view:all',
      enabled: true,
      group: '客户与销售',
    ),
    DataScopeCatalogItem(
      scope: 'goods',
      label: '外贸货品可见业务员',
      description: '货品负责人范围',
      viewAllPermission: 'goods:view:all',
      enabled: false,
      disabledReason: '当前全员可见全部货品',
      group: '客户与销售',
    ),
    DataScopeCatalogItem(
      scope: 'finance',
      label: '财务单据可见制单人',
      description: '额外查看负责人名下财务单据',
      viewAllPermission: 'finance:view:all',
      enabled: true,
      group: '财务',
    ),
  ];

  @override
  Future<List<String>> getUserDataScopes(String userId, String scope) async {
    loadedScopes.add(scope);
    return const [];
  }

  @override
  Future<List<DataScopeOwner>> dataScopeOwners(String scope) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _SearchScopeRepository extends _ScopeRepositoryFake {
  @override
  Future<List<DataScopeOwner>> dataScopeOwners(String scope) async => const [
    DataScopeOwner(
      employeeId: 'owner-match',
      name: '张三',
      code: 'UT003',
      count: 2,
      departmentId: 'rd',
      departmentName: '工程研发部',
    ),
    DataScopeOwner(
      employeeId: 'owner-other',
      name: '李四',
      code: 'UT004',
      count: 3,
      departmentId: 'fin',
      departmentName: '财务部',
    ),
  ];
}
