import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/pages/employee_detail_page.dart';
import 'package:uten_imp/features/employee/pages/employee_edit_page.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/employee/widgets/employee_identity_archive_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

EmployeeProfile _profile({bool verified = true}) => EmployeeProfile.fromJson({
  'id': 'canonical',
  'code': 'UT0010',
  'fullName': '合成员工',
  'status': 'active',
  if (verified) 'resolvedFromEmployeeId': 'alias',
  'historicalEducations': [
    {
      'id': 'original-education',
      'school': 'Historical school',
      'sourceEmployeeId': 'alias',
      'sourceEmployeeCode': 'UT0189',
      'historicalReadOnly': true,
    },
  ],
  'historicalCertificates': [
    {
      'id': 'original-certificate',
      'name': 'Historical certificate',
      'sourceEmployeeId': 'alias',
      'sourceEmployeeCode': 'UT0189',
      'historicalReadOnly': true,
    },
  ],
});

class _Api extends Fake implements ApiClient {}

class _Employees extends Fake implements EmployeeRepository {
  _Employees(this.verified);
  final bool verified;
  @override
  Future<EmployeeProfile> getById(String id) async =>
      _profile(verified: verified);
}

class _Actor extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'hr',
      code: 'HR',
      name: 'HR',
      permissions: [Perm.employeeView, Perm.employeeEdit],
    ),
  );
}

void main() {
  test('archived education stays in its own immutable source collection', () {
    final profile = _profile();
    expect(profile.historicalEducations.single.sourceEmployeeId, 'alias');
    expect(
      profile.historicalEducations.single.values['id'],
      'original-education',
    );
    expect(
      () => profile.historicalEducations.single.values['school'] = 'overwrite',
      throwsUnsupportedError,
    );
  });
  for (final language in ['zh', 'en', 'ko']) {
    testWidgets(
      '$language displays historical source rows without editing controls',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
            child: MaterialApp(
              locale: Locale(language),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: Scaffold(
                body: EmployeeIdentityArchiveSection(profile: _profile()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Historical school'), findsOneWidget);
        expect(find.textContaining('UT0189'), findsNWidgets(2));
        expect(
          find.textContaining(
            language == 'zh'
                ? '(只读)'
                : language == 'en'
                ? '(read only)'
                : '(읽기 전용)',
          ),
          findsNWidgets(2),
        );
        expect(find.byType(TextField), findsNothing);
        expect(find.byType(IconButton), findsNothing);
      },
    );
  }
  for (final edit in [false, true]) {
    testWidgets(
      'verified alias redirects ${edit ? 'edit' : 'detail'} to the canonical route',
      (tester) async {
        final router = await _pumpAlias(tester, verified: true, edit: edit);
        expect(
          router.routeInformationProvider.value.uri.path,
          edit ? '/employee/canonical/edit' : '/employee/canonical',
        );
        expect(find.text('canonical-opened'), findsOneWidget);
      },
    );
  }
  testWidgets('an unrelated response still fails the detail identity fence', (
    tester,
  ) async {
    final router = await _pumpAlias(tester, verified: false, edit: false);
    expect(router.routeInformationProvider.value.uri.path, '/employee/alias');
    expect(find.text('canonical-opened'), findsNothing);
  });
}

Future<GoRouter> _pumpAlias(
  WidgetTester tester, {
  required bool verified,
  required bool edit,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final suffix = edit ? '/edit' : '';
  final router = GoRouter(
    initialLocation: '/employee/alias$suffix',
    routes: [
      GoRoute(
        path: '/employee/:id$suffix',
        builder: (_, state) => state.pathParameters['id'] == 'canonical'
            ? const Scaffold(body: Text('canonical-opened'))
            : edit
            ? const EmployeeEditPage(employeeId: 'alias')
            : const EmployeeDetailPage(employeeId: 'alias'),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        apiClientProvider.overrideWithValue(_Api()),
        employeeRepositoryProvider.overrideWithValue(_Employees(verified)),
        sessionProvider.overrideWith(_Actor.new),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}
