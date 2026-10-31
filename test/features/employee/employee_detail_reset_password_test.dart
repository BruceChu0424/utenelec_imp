import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/pages/employee_detail_page.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _action = ValueKey('employee-reset-password-action');
const _confirm = ValueKey('employee-reset-password-confirm');
const _saved = ValueKey('employee-reset-password-saved');

class _DetailRepository extends Fake implements EmployeeRepository {
  _DetailRepository({
    this.accountStatus = 'active',
    this.status = 'active',
    this.accountSupportAllowed,
    this.passwordResetSupportAllowed,
  });

  final String? accountStatus;
  final String status;
  final bool? accountSupportAllowed;
  final bool? passwordResetSupportAllowed;
  int getByIdCalls = 0;
  final resetEmployeeIds = <String>[];
  final requestedPasswords = <String?>[];

  @override
  Future<EmployeeProfile> getById(String id) async {
    getByIdCalls++;
    return EmployeeProfile(
      id: id,
      code: 'UT0009',
      fullName: '孙七',
      status: status,
      accountStatus: accountStatus,
      accountSupportAllowed: accountSupportAllowed,
      passwordResetSupportAllowed: passwordResetSupportAllowed,
    );
  }

  @override
  Future<String> resetPassword(String id, {String? temporaryPassword}) async {
    resetEmployeeIds.add(id);
    requestedPasswords.add(temporaryPassword);
    return temporaryPassword ?? 'S9!temporary-Only2';
  }
}

class _Session extends SessionNotifier {
  _Session(this.permissions, {this.superAdmin = false});

  final List<String> permissions;
  final bool superAdmin;

  @override
  SessionState build() => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'hr-user',
      code: 'HR001',
      name: '人事',
      permissions: permissions,
      superAdmin: superAdmin,
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  _DetailRepository repository, {
  List<String> permissions = const [Perm.employeeView, Perm.accountSupport],
  bool actorSuperAdmin = false,
}) async {
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues(const {});
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) =>
            const EmployeeDetailPage(employeeId: 'emp-9'),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        employeeRepositoryProvider.overrideWithValue(repository),
        sessionProvider.overrideWith(
          () => _Session(permissions, superAdmin: actorSuperAdmin),
        ),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(UtenBusyOverlay.debugResetYield);

  for (final manual in [false, true]) {
    testWidgets(
      'reset-only target keeps its dedicated authority through credential delivery manual=$manual',
      (tester) async {
        final repository = _DetailRepository(
          accountSupportAllowed: false,
          passwordResetSupportAllowed: true,
        );
        await _pump(tester, repository, actorSuperAdmin: true);
        expect(find.byKey(_action), findsOneWidget);
        for (final label in ['锁定账号', '解锁账号', '停用账号', '启用账号']) {
          expect(find.text(label), findsNothing);
        }
        await tester.tap(find.byKey(_action));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('employee-reset-password-dialog')),
          findsOneWidget,
        );
        const custom = ' 详情合成A!口令 ';
        if (manual) {
          await tester.tap(find.text('手动输入'));
          await tester.pumpAndSettle();
          for (final key in [
            'temporary-password-input',
            'temporary-password-confirmation',
          ]) {
            await tester.enterText(
              find.descendant(
                of: find.byKey(ValueKey(key)),
                matching: find.byType(TextField),
              ),
              custom,
            );
          }
        }
        await tester.tap(find.byKey(_confirm));
        await tester.pumpAndSettle();
        final issued = manual ? custom : 'S9!temporary-Only2';
        expect(repository.resetEmployeeIds, ['emp-9']);
        expect(repository.requestedPasswords, [manual ? custom : null]);
        expect(find.text(issued), findsOneWidget);
        expect(repository.getByIdCalls, 1);
        await tester.tap(find.byKey(_saved));
        await tester.pumpAndSettle();
        expect(repository.getByIdCalls, 2);
        expect(find.text(issued), findsNothing);
        expect(find.byKey(_action), findsOneWidget);
        for (final label in ['锁定账号', '解锁账号', '停用账号', '启用账号']) {
          expect(find.text(label), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final accountStatus in ['active', 'locked']) {
    testWidgets('$accountStatus 账号在锁定/解锁按钮旁提供修改密码', (tester) async {
      await _pump(tester, _DetailRepository(accountStatus: accountStatus));

      expect(find.byKey(_action), findsOneWidget);
      expect(find.text('修改密码'), findsOneWidget);
      final accountAction = find.text(
        accountStatus == 'active' ? '锁定账号' : '解锁账号',
      );
      expect(accountAction, findsOneWidget);
      expect(
        tester.getCenter(find.byKey(_action)).dx,
        greaterThan(tester.getCenter(accountAction).dx),
      );
    });
  }

  for (final accountStatus in <String?>[null, 'disabled', 'unknown']) {
    testWidgets('$accountStatus 账号没有修改密码入口', (tester) async {
      await _pump(tester, _DetailRepository(accountStatus: accountStatus));
      expect(find.byKey(_action), findsNothing);
    });
  }

  testWidgets('离职员工即使账号状态正常也没有修改密码入口', (tester) async {
    await _pump(tester, _DetailRepository(status: 'resigned'));
    expect(find.byKey(_action), findsNothing);
  });

  testWidgets('没有账号维护权限不能看到修改密码入口', (tester) async {
    await _pump(
      tester,
      _DetailRepository(),
      permissions: const [Perm.employeeView],
    );
    expect(find.byKey(_action), findsNothing);
  });

  testWidgets('修改密码传递当前员工ID，安全保存临时密码后刷新详情', (tester) async {
    final repository = _DetailRepository();
    await _pump(tester, repository);
    expect(repository.getByIdCalls, 1);

    await tester.tap(find.byKey(_action));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();
    expect(repository.resetEmployeeIds, ['emp-9']);
    expect(find.text('S9!temporary-Only2'), findsOneWidget);
    expect(repository.getByIdCalls, 1, reason: '凭据尚未安全保存时保留弹窗');

    await tester.tap(find.byKey(_saved));
    await tester.pumpAndSettle();
    expect(repository.getByIdCalls, 2);
    expect(find.text('S9!temporary-Only2'), findsNothing);
    expect(find.byKey(_action), findsOneWidget);
  });
}
