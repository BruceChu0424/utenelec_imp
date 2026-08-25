import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';
import 'package:uten_imp/features/admin/widgets/admin_data_scope_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'loads preserved owner scopes after view-all permission is removed',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();

      final repository = _TransitionScopeRepository();
      final effective = ValueNotifier<AsyncValue<EffectivePermissions>>(
        const AsyncValue.data(
          EffectivePermissions(
            departmentPermissions: [],
            baselinePermissions: [],
            grants: [],
            revokes: [],
            effective: ['client:view:all'],
          ),
        ),
      );
      addTearDown(effective.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            adminRepositoryProvider.overrideWithValue(repository),
            currentPermissionsProvider.overrideWithValue(const {}),
            sharedPreferencesProvider.overrideWithValue(preferences),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ValueListenableBuilder<AsyncValue<EffectivePermissions>>(
                  valueListenable: effective,
                  builder: (_, value, _) => AdminDataScopeSection(
                    user: const AdminUserSummary(
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
                    effectiveAsync: value,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.loadedScopes, isEmpty);
      expect(find.text('查看全部覆盖'), findsOneWidget);

      effective.value = const AsyncValue.data(
        EffectivePermissions(
          departmentPermissions: [],
          baselinePermissions: [],
          grants: [],
          revokes: [],
          effective: [],
        ),
      );
      await tester.pumpAndSettle();

      expect(repository.loadedScopes, ['client']);
      expect(find.text('额外查看 1 人'), findsWidgets);
      expect(find.textContaining('已包含 1 位历史只读原负责人'), findsOneWidget);
    },
  );
}

class _TransitionScopeRepository implements AdminRepository {
  final loadedScopes = <String>[];

  @override
  Future<List<DataScopeCatalogItem>> dataScopeCatalog() async => const [
    DataScopeCatalogItem(
      scope: 'client',
      label: '客户资料可见负责人',
      description: '加看指定负责人的客户',
      viewAllPermission: 'client:view:all',
      enabled: true,
      group: '客户与销售',
    ),
  ];

  @override
  Future<List<String>> getUserDataScopes(String userId, String scope) async {
    loadedScopes.add(scope);
    return const ['owner-1'];
  }

  @override
  Future<List<DataScopeOwner>> dataScopeOwners(String scope) async => const [
    DataScopeOwner(
      employeeId: 'owner-1',
      name: '负责人甲',
      count: 3,
      status: 'resigned',
      historicalOnly: true,
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
