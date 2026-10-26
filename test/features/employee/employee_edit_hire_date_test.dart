import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/components/inputs/uten_date_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/pages/employee_edit_page.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

class _Repository extends Fake implements EmployeeRepository {
  final updates = <Map<String, dynamic>>[];
  static const profile = EmployeeProfile(
    id: 'e1',
    code: 'UT0001',
    fullName: '测试员工',
    gender: 'male',
    status: 'probation',
    employmentType: 'regular',
    hireDate: '2026-10-10',
  );
  @override
  Future<EmployeeProfile> getById(String id) async => profile;
  @override
  Future<List<EmployeeSecondaryDepartment>> listSecondaryDepartments(
    String id,
  ) async => [];
  @override
  Future<EmployeeProfile> update(String id, Map<String, dynamic> body) async {
    updates.add(body);
    return profile;
  }
}

void main() {
  testWidgets('入职日期更正要求原因，只提交变更日期与旧值，不开放状态/部门写入', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repo = _Repository();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: '/edit',
          builder: (_, _) => const EmployeeEditPage(employeeId: 'e1'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue({Perm.employeeEdit}),
          employeeRepositoryProvider.overrideWithValue(repo),
        ],
        child: MaterialApp.router(
          locale: const Locale('zh'),
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    router.push('/edit');
    await tester.pumpAndSettle();
    final date = find.byKey(const ValueKey('employee-edit-hire-date'));
    await tester.ensureVisible(date);
    tester.widget<UtenDateField>(date).onChanged(DateTime(2026, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(repo.updates, isEmpty, reason: '更正原因不可为空');
    final reason = find.byKey(const ValueKey('employee-edit-hire-date-reason'));
    await tester.ensureVisible(reason);
    await tester.enterText(reason, '核对原始入职登记');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(repo.updates.single, {
      'hireDate': '2026-10-01',
      'expectedHireDate': '2026-10-10',
      'hireDateChangeReason': '核对原始入职登记',
    });
    expect(find.text('home'), findsOneWidget);
  });
}
