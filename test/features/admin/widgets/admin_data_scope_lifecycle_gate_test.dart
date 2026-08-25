import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_employee_multi_picker.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';
import 'package:uten_imp/features/admin/widgets/admin_data_scope_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('375px resigned account can only clear existing data scope', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = _ScopeLifecycleRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminRepositoryProvider.overrideWithValue(repository),
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
                  employeeName: '离职员工',
                  employeeStatus: 'resigned',
                  loginAccount: '13800000000',
                  status: 'disabled',
                  mustChangePassword: false,
                  roles: [],
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
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('不能新增额外查看范围'), findsOneWidget);
    expect(find.textContaining('离职办理'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('admin-data-handover-entry')),
      findsNothing,
    );
    expect(
      tester
          .widget<UtenEmployeeMultiPicker>(find.byType(UtenEmployeeMultiPicker))
          .enabled,
      isFalse,
    );
    final clear = find.ancestor(
      of: find.text('清空额外查看'),
      matching: find.byType(UtenButton),
    );
    expect(tester.widget<UtenButton>(clear).onPressed, isNotNull);

    await tester.tap(clear);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();
    expect(repository.updates, [const <String>[]]);
    expect(tester.takeException(), isNull);
  });
}

class _ScopeLifecycleRepository implements AdminRepository {
  final List<List<String>> updates = [];

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
  Future<List<String>> getUserDataScopes(String userId, String scope) async =>
      const ['owner-1'];

  @override
  Future<List<DataScopeOwner>> dataScopeOwners(String scope) async => const [
    DataScopeOwner(employeeId: 'owner-1', name: '原负责人', count: 3),
  ];

  @override
  Future<void> updateUserDataScopes(
    String userId,
    String scope,
    List<String> ownerEmployeeIds, {
    required List<String> expectedOwnerEmployeeIds,
  }) async {
    updates.add([...ownerEmployeeIds]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
