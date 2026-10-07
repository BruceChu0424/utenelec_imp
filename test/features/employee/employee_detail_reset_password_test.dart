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
  _DetailRepository({this.accountStatus = 'active', this.status = 'active'});

  final String? accountStatus;
  final String status;
  int getByIdCalls = 0;
  final resetEmployeeIds = <String>[];

  @override
  Future<EmployeeProfile> getById(String id) async {
    getByIdCalls++;
    return EmployeeProfile(
      id: id,
      code: 'UT0009',
      fullName: '孙七',
      status: status,
      accountStatus: accountStatus,
    );
  }

  @override
  Future<String> resetPassword(String id) async {
    resetEmployeeIds.add(id);
    return 'S9!temporary-Only2';
  }
}

class _Session extends SessionNotifier {
  _Session(this.permissions);

  final List<String> permissions;

  @override
  SessionState build() => SessionState(
    user: AppUser(
      id: 'hr-user',
      code: 'HR001',
      name: '人事',
      permissions: permissions,
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  _DetailRepository repository, {
  List<String> permissions = const [Perm.employeeView, Perm.accountSupport],
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
        sessionProvider.overrideWith(() => _Session(permissions)),
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
