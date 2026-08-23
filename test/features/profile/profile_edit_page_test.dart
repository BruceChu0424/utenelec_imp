import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/profile/pages/profile_edit_page.dart';
import 'package:uten_imp/features/profile/repositories/profile_change_repository.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _confirmLabel = '\u786e\u8ba4';
const _passwordLabel = '\u5f53\u524d\u5bc6\u7801';

void main() {
  testWidgets(
    'existing emergency contact is not submitted when the form is unchanged',
    (tester) async {
      final profileChanges = _RecordingProfileChangeRepository();

      await _pumpProfileEdit(tester, profileChanges);
      expect(find.text('mother'), findsOneWidget);

      await tester.tap(find.text(_confirmLabel).last);
      await tester.pumpAndSettle();

      expect(profileChanges.verifyPasswordCalls, 0);
      expect(profileChanges.submitCalls, 0);
      expect(find.text('profile-home'), findsOneWidget);
      expect(find.text(_passwordLabel), findsNothing);
    },
  );

  testWidgets('changing one emergency field submits only that field', (
    tester,
  ) async {
    final profileChanges = _RecordingProfileChangeRepository();

    await _pumpProfileEdit(tester, profileChanges);
    final emergencyPhone = find.byWidgetPredicate(
      (widget) =>
          widget is EditableText && widget.controller.text == '13800138000',
    );
    expect(emergencyPhone, findsOneWidget);
    await tester.enterText(emergencyPhone, '13900139000');

    await tester.tap(find.text(_confirmLabel).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(_passwordLabel), findsWidgets);

    await tester.enterText(find.byType(EditableText).last, 'correct-password');
    await tester.tap(find.text(_confirmLabel).last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(profileChanges.verifyPasswordCalls, 1);
    expect(profileChanges.submitCalls, 1);
    final changes = profileChanges.lastRequest!.changes;
    expect(changes, hasLength(1));
    expect(changes.single.fieldCode, 'emergencyContact.0.phone');
    expect(changes.single.newValue, '13900139000');
    expect(find.text('profile-change-list'), findsOneWidget);
  });
}

Future<void> _pumpProfileEdit(
  WidgetTester tester,
  _RecordingProfileChangeRepository profileChanges,
) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();

  final router = GoRouter(
    initialLocation: RouteName.profileEdit,
    routes: [
      GoRoute(
        path: RouteName.profileEdit,
        builder: (_, _) => const ProfileEditPage(),
      ),
      GoRoute(
        path: '/profile',
        builder: (_, _) => const Scaffold(body: Text('profile-home')),
      ),
      GoRoute(
        path: RouteName.profileMyChanges,
        builder: (_, _) => const Scaffold(body: Text('profile-change-list')),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        sessionProvider.overrideWith(_ProfileSessionNotifier.new),
        employeeRepositoryProvider.overrideWithValue(
          _ProfileEmployeeRepository(),
        ),
        profileChangeRepositoryProvider.overrideWithValue(profileChanges),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _ProfileSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'user-1',
      code: 'E001',
      name: 'Test User',
      roles: [],
      employeeId: 'employee-1',
    ),
  );
}

class _ProfileEmployeeRepository extends Fake implements EmployeeRepository {
  @override
  Future<EmployeeProfile> getById(String id) async => const EmployeeProfile(
    id: 'employee-1',
    code: 'E001',
    fullName: 'Test User',
    emergencyContacts: [
      EmergencyContactView(
        id: 'contact-1',
        name: 'Emergency Contact',
        phone: '13800138000',
        relationship: 'mother',
      ),
    ],
  );
}

class _RecordingProfileChangeRepository extends Fake
    implements ProfileChangeRepository {
  int verifyPasswordCalls = 0;
  int submitCalls = 0;
  SubmitProfileChangeRequest? lastRequest;

  @override
  Future<void> verifyPassword(String password) async {
    verifyPasswordCalls += 1;
  }

  @override
  Future<SubmitProfileChangeResponse> submit(
    SubmitProfileChangeRequest request,
  ) async {
    submitCalls += 1;
    lastRequest = request;
    return const SubmitProfileChangeResponse(
      batchId: 'batch-1',
      requestIds: ['request-1'],
      count: 1,
    );
  }
}
