import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/profile/models/profile_change_request.dart';
import 'package:uten_imp/features/profile/pages/profile_edit_page.dart';
import 'package:uten_imp/features/profile/providers/profile_change_providers.dart';
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
      final employees = _ProfileEmployeeRepository();

      await _pumpProfileEdit(tester, profileChanges, employees: employees);
      expect(find.text('mother'), findsOneWidget);
      expect(employees.getMeCalls, 1);
      expect(employees.getByIdCalls, 0);

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

  testWidgets('invalid phone is shown inline and blocks submit', (
    tester,
  ) async {
    final profileChanges = _RecordingProfileChangeRepository();

    await _pumpProfileEdit(tester, profileChanges);
    final primaryPhone = find.byWidgetPredicate(
      (widget) =>
          widget is EditableText && widget.controller.text == '13812345678',
    );
    await tester.enterText(primaryPhone, '123');

    await tester.tap(find.text(_confirmLabel).last);
    await tester.pump();

    // 2026-09-04 ⓘ字段说明全站化后，校验错误经 UtenOverflowMessage 以
    // Semantics(label) + 可见文本承载；断言用 Tooltip/Semantics 谓词与
    // 可见文本双保险。
    expect(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.label?.contains('手机号格式不正确') == true,
          )
          .evaluate()
          .isNotEmpty,
      isTrue,
    );
    expect(profileChanges.verifyPasswordCalls, 0);
    expect(profileChanges.submitCalls, 0);
    expect(find.text(_passwordLabel), findsNothing);
    expect(find.byType(ProfileEditPage), findsOneWidget);
  });

  testWidgets(
    'missing emergency contact shows HR registration guidance and submits nothing',
    (tester) async {
      final profileChanges = _RecordingProfileChangeRepository();
      final employees = _ProfileEmployeeRepository(
        includeEmergencyContact: false,
      );

      await _pumpProfileEdit(tester, profileChanges, employees: employees);

      expect(
        find.textContaining('\u8bf7\u5148\u8054\u7cfb\u4eba\u4e8b\u767b\u8bb0'),
        findsOneWidget,
      );
      expect(find.text('Emergency Contact'), findsNothing);
      expect(find.text('mother'), findsNothing);

      await tester.tap(find.text(_confirmLabel).last);
      await tester.pumpAndSettle();

      expect(profileChanges.verifyPasswordCalls, 0);
      expect(profileChanges.submitCalls, 0);
      expect(find.text('profile-home'), findsOneWidget);
    },
  );

  testWidgets(
    'historically missing optional emergency relationship does not block the form',
    (tester) async {
      final profileChanges = _RecordingProfileChangeRepository();
      final employees = _ProfileEmployeeRepository(emergencyRelationship: null);

      await _pumpProfileEdit(tester, profileChanges, employees: employees);
      await tester.tap(find.text(_confirmLabel).last);
      await tester.pumpAndSettle();

      expect(profileChanges.verifyPasswordCalls, 0);
      expect(profileChanges.submitCalls, 0);
      expect(find.text('profile-home'), findsOneWidget);
    },
  );

  testWidgets('field query parameter locates and focuses the target input', (
    tester,
  ) async {
    final profileChanges = _RecordingProfileChangeRepository();

    await _pumpProfileEdit(
      tester,
      profileChanges,
      initialLocation:
          '${RouteName.profileEdit}?field=${Uri.encodeComponent('email')}',
    );

    final emailField = find.byWidgetPredicate(
      (widget) => widget is EditableText && widget.controller.text == 'e@x.io',
    );
    expect(emailField, findsOneWidget);
    final emailEditable = tester.widget<EditableText>(emailField);
    expect(emailEditable.focusNode.hasFocus, isTrue);
  });
}

Future<void> _pumpProfileEdit(
  WidgetTester tester,
  _RecordingProfileChangeRepository profileChanges, {
  _ProfileEmployeeRepository? employees,
  String initialLocation = RouteName.profileEdit,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 2200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();

  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: RouteName.profileEdit,
        builder: (_, s) =>
            ProfileEditPage(initialField: s.uri.queryParameters['field']),
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
          employees ?? _ProfileEmployeeRepository(),
        ),
        profileChangeRepositoryProvider.overrideWithValue(profileChanges),
        // 编辑页顶部待审提示 watch 本 provider；空页避免触碰 Fake 的未实现方法。
        myProfileChangesProvider.overrideWith(
          (ref, key) async => const ProfileChangePage<MyProfileChangeListItem>(
            items: [],
            page: 1,
            size: 20,
            total: 0,
            totalPages: 0,
          ),
        ),
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

class _ProfileEmployeeRepository extends Fake
    implements EmployeeRepository, EmployeeSelfProfileRepository {
  _ProfileEmployeeRepository({
    this.includeEmergencyContact = true,
    this.emergencyRelationship = 'mother',
  });

  final bool includeEmergencyContact;
  final String? emergencyRelationship;
  int getMeCalls = 0;
  int getByIdCalls = 0;

  @override
  Future<EmployeeProfile?> getMe() async {
    getMeCalls += 1;
    return EmployeeProfile(
      id: 'employee-1',
      code: 'E001',
      fullName: 'Test User',
      phone: '13812345678',
      email: 'e@x.io',
      emergencyContacts: includeEmergencyContact
          ? [
              EmergencyContactView(
                id: 'contact-1',
                name: 'Emergency Contact',
                phone: '13800138000',
                relationship: emergencyRelationship,
              ),
            ]
          : const [],
    );
  }

  @override
  Future<EmployeeProfile> getById(String id) {
    getByIdCalls += 1;
    throw TestFailure('ProfileEditPage must use GET /profile/me, not getById');
  }
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
