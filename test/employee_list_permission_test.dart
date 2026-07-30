import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/pages/employee_list_page.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

class _EmployeeRepository extends Fake implements EmployeeRepository {
  @override
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
  }) async =>
      const PagedResult(items: [], page: 1, size: 20, total: 0, totalPages: 0);
}

Widget _app(Set<String> permissions) => ProviderScope(
  overrides: [
    currentPermissionsProvider.overrideWithValue(permissions),
    employeeRepositoryProvider.overrideWithValue(_EmployeeRepository()),
  ],
  child: const MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: EmployeeListPage(),
  ),
);

void main() {
  testWidgets('view-only users do not see the onboarding action', (
    tester,
  ) async {
    await tester.pumpWidget(_app({Perm.employeeView}));
    await tester.pumpAndSettle();

    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('employee creators with PII write access see onboarding', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app({Perm.employeeView, Perm.employeeCreate, Perm.employeePiiEdit}),
    );
    await tester.pumpAndSettle();

    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('employee create alone cannot start mandatory PII onboarding', (
    tester,
  ) async {
    await tester.pumpWidget(_app({Perm.employeeView, Perm.employeeCreate}));
    await tester.pumpAndSettle();

    expect(find.byType(FloatingActionButton), findsNothing);
  });
}
