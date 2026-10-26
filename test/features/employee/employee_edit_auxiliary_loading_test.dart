import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/pages/employee_edit_page.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Repository extends Fake implements EmployeeRepository {
  static const profile = EmployeeProfile(
    id: 'employee-1',
    code: 'UT0001',
    fullName: '原姓名',
    gender: 'male',
    status: 'active',
    employmentType: 'regular',
  );
  final secondary = Completer<List<EmployeeSecondaryDepartment>>();
  final updates = <Map<String, dynamic>>[];
  final replacements = <List<String>>[];
  @override
  Future<EmployeeProfile> getById(String id) async => profile;
  @override
  Future<List<EmployeeSecondaryDepartment>> listSecondaryDepartments(
    String id,
  ) => secondary.future;
  @override
  Future<EmployeeProfile> update(String id, Map<String, dynamic> body) async {
    updates.add(Map.of(body));
    return profile;
  }

  @override
  Future<void> replaceSecondaryDepartments(
    String id,
    List<String> departments,
  ) async => replacements.add(List.of(departments));
}

Future<void> _pump(WidgetTester tester, _Repository repository) async {
  await tester.binding.setSurfaceSize(const Size(1200, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('员工列表')),
      ),
      GoRoute(
        path: '/edit',
        builder: (_, _) => const EmployeeEditPage(employeeId: 'employee-1'),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({Perm.employeeEdit}),
        employeeRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  router.push<void>('/edit');
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Finder _name() => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.controller?.text == '原姓名',
);
Finder _departments() =>
    find.byKey(const Key('employee-edit-secondary-departments'));

void main() {
  testWidgets(
    'late auxiliary departments do not block or overwrite core employee edits',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      expect(_name(), findsOneWidget);
      final text = tester.widget<TextField>(_name()).controller!;
      expect(
        tester.widget<UtenDepartmentPicker>(_departments()).enabled,
        isFalse,
      );
      await tester.enterText(_name(), '已修改姓名');
      repository.secondary.complete(const [
        EmployeeSecondaryDepartment(
          departmentId: 'existing',
          departmentName: '原兼职',
        ),
      ]);
      await tester.pumpAndSettle();
      expect(text.text, '已修改姓名');
      final picker = tester.widget<UtenDepartmentPicker>(_departments());
      expect(picker.enabled, isTrue);
      expect(picker.initialSelection.single.id, 'existing');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(repository.updates.single, {'fullName': '已修改姓名'});
      expect(repository.replacements, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saving the core profile before auxiliary readback never submits an empty department replacement',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      await tester.enterText(_name(), '先保存主档');
      await tester.tap(find.text('保存'));
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(repository.updates.single, {'fullName': '先保存主档'});
      expect(repository.replacements, isEmpty);
      repository.secondary.complete(const [
        EmployeeSecondaryDepartment(
          departmentId: 'keep',
          departmentName: '必须保留',
        ),
      ]);
      await tester.pumpAndSettle();
      expect(repository.replacements, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
