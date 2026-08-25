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
  testWidgets('resigned employee is not a receiver and shows handover path', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminRepositoryProvider.overrideWithValue(_EmptyAdminRepository()),
          currentPermissionsProvider.overrideWithValue({Perm.employeeHandover}),
          isSuperAdminProvider.overrideWithValue(false),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AdminDataScopeSection(
                user: AdminUserSummary(
                  id: 'user-1',
                  employeeId: 'employee-1',
                  employeeStatus: 'resigned',
                  loginAccount: '13800000000',
                  status: 'disabled',
                  mustChangePassword: false,
                  roles: [],
                  remoteAccess: false,
                  employeeName: '离职员工',
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
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('已离职员工不能作为数据接手人'), findsOneWidget);
    expect(find.textContaining('离职办理'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('admin-data-handover-entry')),
      findsNothing,
    );
  });
}

class _EmptyAdminRepository implements AdminRepository {
  @override
  Future<List<DataScopeCatalogItem>> dataScopeCatalog() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
