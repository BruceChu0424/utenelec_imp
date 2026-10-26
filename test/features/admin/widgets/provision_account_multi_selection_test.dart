import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';
import 'package:uten_imp/features/admin/widgets/provision_account_dialog.dart';
import 'package:uten_imp/features/employee/providers/employee_picker_department_tree_provider.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

void main() {
  testWidgets(
    'account picker confirms multiple employees in one batch and keeps missing-phone rows disabled',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = ApiClient(
        Dio(BaseOptions(baseUrl: 'https://example.test/api')),
      );
      final repository = _EmployeeRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            adminRepositoryProvider.overrideWithValue(_AdminRepository()),
            employeeRepositoryProvider.overrideWithValue(repository),
            employeePickerDepartmentTreeProvider.overrideWith(
              (ref) async => [],
            ),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'hr'),
            ),
            isSuperAdminProvider.overrideWithValue(true),
            currentPermissionsProvider.overrideWithValue({Perm.accountSupport}),
            sensitiveReadBoundaryProvider.overrideWithValue(
              SensitiveReadBoundary(
                identity: const AuthenticatedScope(userId: 'hr'),
                api: api,
                permissions: {Perm.accountSupport},
                superAdmin: true,
              ),
            ),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () =>
                      showProvisionAccountDialog(context, onProvisioned: () {}),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final panel = tester.widget<UtenEmployeeSelectionPanel>(
        find.byType(UtenEmployeeSelectionPanel),
      );
      expect(panel.multiple, isTrue);
      expect(panel.confirmLabel, '开通所选账号');
      final candidates = await panel.loader(null);
      expect(candidates.last.enabled, isFalse);
      await tester.tap(find.text('员工甲'));
      await tester.tap(find.text('员工乙'));
      await tester.pump();
      expect(find.text('已选择 2 位员工'), findsOneWidget);
      await tester.tap(find.text('开通所选账号'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('batch-provision-accounts-dialog')),
        findsOneWidget,
      );
      expect(find.text('开通 2 个账号'), findsOneWidget);
      expect(repository.writes, 0);
    },
  );
}

class _AdminRepository extends Fake implements AdminRepository {
  @override
  Future<List<AccountProvisionCandidate>> provisionCandidates({
    String? search,
  }) async => [
    for (final pair in [('a', '员工甲'), ('b', '员工乙'), ('c', '缺手机员工')])
      AccountProvisionCandidate(
        employeeId: pair.$1,
        name: pair.$2,
        code: 'UT${pair.$1}',
        hasPhone: pair.$1 != 'c',
        accountStatus: 'notProvisioned',
        employmentStatus: 'active',
      ),
  ];
}

class _EmployeeRepository extends Fake implements EmployeeRepository {
  int writes = 0;
  @override
  Future<EmployeeAccountReadiness> accountReadiness(String id) async =>
      const EmployeeAccountReadiness(hasPhone: true);
}
