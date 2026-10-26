import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/pages/employee_edit_page.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Repository extends Fake implements EmployeeRepository {
  bool corrected = false;
  bool failReadback = false;
  int identityWrites = 0;
  final updates = <Map<String, dynamic>>[];

  @override
  Future<EmployeeProfile> getById(String id) async {
    if (corrected && failReadback) throw StateError('readback unavailable');
    return EmployeeProfile(
      id: id,
      code: 'UT0010',
      fullName: '原姓名',
      gender: corrected ? 'female' : 'male',
      birthDate: corrected ? '1949-12-31' : '1990-01-01',
      status: 'active',
      employmentType: 'regular',
      idType: '身份证',
      idNumber: corrected ? '11010519491231002X' : '****1234',
      phone: '13800000000',
      accountStatus: 'active',
    );
  }

  @override
  Future<List<EmployeeSecondaryDepartment>> listSecondaryDepartments(
    String id,
  ) async => [];

  @override
  Future<void> changeIdentity(
    String id, {
    required String idType,
    required String idNumber,
  }) async {
    expect(id, 'employee-1');
    expect(idType, '身份证');
    expect(idNumber, '11010519491231002X');
    identityWrites++;
    corrected = true;
  }

  @override
  Future<EmployeeProfile> update(String id, Map<String, dynamic> body) async {
    updates.add(Map.of(body));
    return getById(id);
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Repository repository, {
  bool pii = true,
  Locale locale = const Locale('zh'),
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 1000));
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
        currentPermissionsProvider.overrideWithValue({
          Perm.employeeEdit,
          if (pii) Perm.employeePiiEdit,
        }),
        employeeRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp.router(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  router.push<void>('/edit');
  await tester.pumpAndSettle();
}

Future<void> _correct(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey('employee-edit-correct-identity')),
  );
  await tester.pumpAndSettle();
  final number = find.byKey(
    const ValueKey('employee-identity-correction-number'),
  );
  expect(tester.widget<TextField>(number).controller!.text, isEmpty);
  await tester.enterText(number, '11010519491231002x');
  await tester.tap(
    find.byKey(const ValueKey('employee-identity-correction-save')),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in const [Locale('zh'), Locale('en'), Locale('ko')]) {
    testWidgets(
      'identity edit copy and readback retry follow ${locale.languageCode}',
      (tester) async {
        final l10n = lookupAppLocalizations(locale);
        final repository = _Repository()..failReadback = true;
        await _pump(tester, repository, locale: locale);
        expect(find.text(l10n.employeeIdentitySectionTitle), findsOneWidget);
        expect(find.text(l10n.employeeIdentityCorrectTitle), findsOneWidget);
        expect(
          find.text(l10n.employeeIdentitySeparateSaveHint),
          findsOneWidget,
        );
        await _correct(tester);
        expect(repository.identityWrites, 1);
        expect(
          find.text(l10n.employeeIdentitySavedReadbackFailed),
          findsOneWidget,
        );
        repository.failReadback = false;
        await tester.tap(
          find.byKey(const ValueKey('employee-edit-identity-retry')),
        );
        await tester.pumpAndSettle();
        expect(repository.identityWrites, 1);
        expect(
          find.text(l10n.employeeIdentitySavedReadbackFailed),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'active login account can correct identity from edit page without losing unsaved fields',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      final name = find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == '原姓名',
      );
      await tester.enterText(name, '已修改姓名');
      await _correct(tester);
      expect(repository.identityWrites, 1);
      expect(find.text('身份证：11010519491231002X'), findsOneWidget);
      expect(find.text('已修改姓名'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(repository.updates.single, {'fullName': '已修改姓名'});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('identity entry requires pii edit permission', (tester) async {
    final repository = _Repository();
    await _pump(tester, repository, pii: false);
    expect(
      find.byKey(const ValueKey('employee-edit-correct-identity')),
      findsNothing,
    );
    expect(repository.identityWrites, 0);
  });

  testWidgets(
    'readback failure retries only the read after successful identity write',
    (tester) async {
      final repository = _Repository()..failReadback = true;
      await _pump(tester, repository);
      await _correct(tester);
      expect(repository.identityWrites, 1);
      expect(find.text('证件信息已保存，读取最新资料失败，请重试读取。'), findsOneWidget);
      repository.failReadback = false;
      await tester.tap(
        find.byKey(const ValueKey('employee-edit-identity-retry')),
      );
      await tester.pumpAndSettle();
      expect(repository.identityWrites, 1);
      expect(find.text('身份证：11010519491231002X'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
