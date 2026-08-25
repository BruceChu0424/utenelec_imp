import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';
import 'package:uten_imp/features/admin/widgets/admin_data_scope_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
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
                  roles: [],
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
