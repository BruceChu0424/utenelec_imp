import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_segmented_filter.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import '../../support/audit_screenshot_support.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/pages/employee_detail_page.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _capture = bool.fromEnvironment('CAPTURE_EMPLOYEE_DETAIL');
final _captureKey = GlobalKey();

class _Api extends Fake implements ApiClient {}

class _Accounts extends Fake implements EmployeeRepository {
  _Accounts(this.values);
  final Map<String, dynamic> values;
  int reads = 0;
  int locks = 0;
  int unlocks = 0;
  int provisions = 0;
  Completer<EmployeeProfile>? pending;
  Completer<void>? lockPending;

  EmployeeProfile profile(String id) => EmployeeProfile.fromJson({
    'id': id,
    'code': 'UT0006',
    'fullName': '合成员工',
    'status': 'active',
    ...values,
  });

  @override
  Future<EmployeeProfile> getById(String id) async {
    reads++;
    return pending == null ? profile(id) : pending!.future;
  }

  @override
  Future<void> lockAccount(String id) async {
    locks++;
    if (lockPending != null) await lockPending!.future;
    values['accountStatus'] = 'locked';
  }

  @override
  Future<void> unlockAccount(String id) async {
    unlocks++;
    values['accountStatus'] = 'active';
  }

  @override
  Future<EmployeeAccountReadiness> accountReadiness(String id) async =>
      const EmployeeAccountReadiness(hasPhone: true);

  @override
  Future<EmployeeOnboardingResult> provisionAccount(String id) async {
    provisions++;
    values['accountStatus'] = 'active';
    values['accountDeleted'] = false;
    return EmployeeOnboardingResult(
      employee: profile(id),
      loginAccount: '13800138000',
      temporaryPassword: 'Synthetic-Once-Only!22',
    );
  }
}

class _Actor extends SessionNotifier {
  _Actor({this.employeeId});
  final String? employeeId;

  @override
  SessionState build() => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'hr-user',
      employeeId: employeeId,
      code: 'HR001',
      name: '人事',
      permissions: const [Perm.employeeView, Perm.accountSupport],
    ),
  );

  void switchIdentity() => state = const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'other-hr',
      code: 'HR002',
      name: '另一人事',
      permissions: [Perm.employeeView, Perm.accountSupport],
    ),
  );

  void revokeSupport() => state = const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'hr-user',
      code: 'HR001',
      name: '人事',
      permissions: [Perm.employeeView],
    ),
  );
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Accounts repository, {
  String? actorEmployeeId,
  Size size = const Size(1400, 1600),
  double textScale = 1,
  bool dark = false,
  bool settle = true,
  ValueNotifier<String>? selectedEmployee,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (_capture) await loadAuditScreenshotFonts(tester);
  SharedPreferences.setMockInitialValues(const {});
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(_Api()),
      employeeRepositoryProvider.overrideWithValue(repository),
      sessionProvider.overrideWith(() => _Actor(employeeId: actorEmployeeId)),
      sharedPreferencesProvider.overrideWithValue(preferences),
    ],
  );
  final router = GoRouter(
    routes: [
      GoRoute(
        path: RouteName.adminPermissions,
        builder: (_, state) => Scaffold(
          body: Text(
            'manage-account-${state.uri.queryParameters['employeeId']}',
          ),
        ),
      ),
      GoRoute(
        path: '/',
        builder: (_, _) => selectedEmployee == null
            ? const EmployeeDetailPage(employeeId: 'emp-6')
            : ValueListenableBuilder<String>(
                valueListenable: selectedEmployee,
                builder: (_, value, _) => EmployeeDetailPage(employeeId: value),
              ),
      ),
    ],
  );
  addTearDown(router.dispose);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: _capture
            ? auditScreenshotTheme(dark ? buildDarkTheme() : buildLightTheme())
            : (dark ? buildDarkTheme() : buildLightTheme()),
        builder: (context, child) => RepaintBoundary(
          key: _captureKey,
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return container;
}

void main() {
  setUp(UtenBusyOverlay.debugResetYield);

  testWidgets('在职停用账号有账号支持权限可按员工UUID进入管理，不自动启用', (tester) async {
    final repo = _Accounts({
      'accountStatus': 'disabled',
      'accountSupportAllowed': true,
    });
    await _pump(tester, repo);
    await tester.ensureVisible(
      find.byKey(const ValueKey('employee-manage-disabled-account')),
    );
    await tester.tap(
      find.byKey(const ValueKey('employee-manage-disabled-account')),
    );
    await tester.pumpAndSettle();
    expect(find.text('manage-account-emp-6'), findsOneWidget);
    expect(repo.provisions, 0);
    expect(repo.locks, 0);
    expect(repo.unlocks, 0);
    expect(repo.values['accountStatus'], 'disabled');
  });

  testWidgets('员工详情用统一分类栏保留六项与当前选中分类', (tester) async {
    await _pump(tester, _Accounts({'accountStatus': 'active'}));
    if (_capture) {
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'employee-detail-desktop-account',
      );
    }
    final categories = tester.widget<UtenSegmentedFilter<int>>(
      find.byType(UtenSegmentedFilter<int>),
    );
    expect(categories.segments.map((item) => item.label), [
      '概览',
      '组织与合同',
      '联系与车辆',
      '薪酬',
      '任职记录',
      '档案文件',
    ]);
    expect(find.byType(TabBar), findsNothing);
    categories.onChanged(2);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UtenSegmentedFilter<int>>(
            find.byType(UtenSegmentedFilter<int>),
          )
          .selected,
      2,
    );
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UtenSegmentedFilter<int>>(
            find.byType(UtenSegmentedFilter<int>),
          )
          .selected,
      2,
    );
  });

  testWidgets('已软删账号明确视为未开通而非停用账号', (tester) async {
    await _pump(
      tester,
      _Accounts({
        'accountStatus': 'disabled',
        'accountDeleted': true,
        'accountSupportAllowed': true,
      }),
    );
    expect(find.text('开通账号'), findsOneWidget);
    expect(find.text('锁定账号'), findsNothing);
    expect(find.text('解锁账号'), findsNothing);
  });

  testWidgets('服务端明确禁止目标账号支持时不露任何办理入口', (tester) async {
    await _pump(
      tester,
      _Accounts({'accountStatus': 'active', 'accountSupportAllowed': false}),
    );
    expect(find.text('锁定账号'), findsNothing);
    expect(find.text('修改密码'), findsNothing);
  });

  testWidgets('本人即使旧服务端未给capability也不能锁定自己', (tester) async {
    await _pump(
      tester,
      _Accounts({'accountStatus': 'active'}),
      actorEmployeeId: 'emp-6',
    );
    expect(find.text('锁定账号'), findsNothing);
    expect(find.text('修改密码'), findsNothing);
  });

  testWidgets('开通成功安全保存凭据后变成锁定入口，锁定和解锁都走仓储', (tester) async {
    final repo = _Accounts({'accountSupportAllowed': true});
    await _pump(tester, repo);
    await tester.tap(
      find.byKey(const ValueKey('employee-provision-account-action')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('provision-selected-employee-confirm')),
    );
    await tester.pumpAndSettle();
    expect(repo.provisions, 1);
    expect(find.text('Synthetic-Once-Only!22'), findsOneWidget);
    await tester.tap(find.text('我已妥善保存'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('employee-provision-account-action')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('employee-lock-account-action')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('employee-lock-account-action')),
    );
    await tester.pumpAndSettle();
    expect(repo.locks, 0, reason: '确认前不写入');
    await tester.tap(
      find.byKey(const ValueKey('employee-account-lock-confirm')),
    );
    await tester.pumpAndSettle();
    expect(repo.locks, 1);
    expect(
      find.byKey(const ValueKey('employee-unlock-account-action')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('employee-unlock-account-action')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('employee-account-lock-confirm')),
    );
    await tester.pumpAndSettle();
    expect(repo.unlocks, 1);
    expect(
      find.byKey(const ValueKey('employee-lock-account-action')),
      findsOneWidget,
    );
  });

  for (final status in ['disabled', 'unknown']) {
    testWidgets('真实$status账号不伪装未开通或借解锁重新启用', (tester) async {
      await _pump(tester, _Accounts({'accountStatus': status}));
      expect(
        find.byKey(const ValueKey('employee-provision-account-action')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('employee-lock-account-action')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('employee-unlock-account-action')),
        findsNothing,
      );
    });
  }

  testWidgets('离职员工不出现账号写操作，即使服务端旧cap未提供', (tester) async {
    await _pump(
      tester,
      _Accounts({'status': 'resigned', 'accountStatus': 'active'}),
    );
    expect(
      find.byKey(const ValueKey('employee-lock-account-action')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('employee-reset-password-action')),
      findsNothing,
    );
  });

  testWidgets('确认中撤销账号权限后旧确认回调不能调用锁定', (tester) async {
    final repo = _Accounts({'accountStatus': 'active'});
    final container = await _pump(tester, repo);
    await tester.tap(
      find.byKey(const ValueKey('employee-lock-account-action')),
    );
    await tester.pumpAndSettle();
    (container.read(sessionProvider.notifier) as _Actor).revokeSupport();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('employee-account-lock-confirm')),
    );
    await tester.pumpAndSettle();
    expect(repo.locks, 0);
    expect(
      find.byKey(const ValueKey('employee-lock-account-action')),
      findsNothing,
    );
  });

  testWidgets('刷新得到禁止目标能力后缓存的锁定按钮也不能打开确认', (tester) async {
    final repo = _Accounts({
      'accountStatus': 'active',
      'accountSupportAllowed': true,
    });
    await _pump(tester, repo);
    final callback = tester
        .widget<UtenButton>(
          find.byKey(const ValueKey('employee-lock-account-action')),
        )
        .onPressed!;
    repo.values['accountSupportAllowed'] = false;
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    callback();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('employee-account-lock-confirm')),
      findsNothing,
    );
    expect(repo.locks, 0);
  });

  testWidgets('请求期间换身份后迟到锁定响应不能刷新或改写新持有者详情', (tester) async {
    final repo = _Accounts({'accountStatus': 'active'})
      ..lockPending = Completer<void>();
    final container = await _pump(tester, repo);
    await tester.tap(
      find.byKey(const ValueKey('employee-lock-account-action')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('employee-account-lock-confirm')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(repo.locks, 1);
    (container.read(sessionProvider.notifier) as _Actor).switchIdentity();
    await tester.pumpAndSettle();
    final reads = repo.reads;
    repo.lockPending!.complete();
    await tester.pumpAndSettle();
    expect(repo.reads, reads, reason: '迟到响应不能给新身份发起旧操作后刷新');
    expect(
      find.byKey(const ValueKey('employee-unlock-account-action')),
      findsNothing,
    );
  });

  testWidgets('切换员工后旧写请求不能让新员工入口一直忙碌', (tester) async {
    final selected = ValueNotifier('emp-6');
    addTearDown(selected.dispose);
    final repo = _Accounts({'accountStatus': 'active'})
      ..lockPending = Completer<void>();
    await _pump(tester, repo, selectedEmployee: selected);
    await tester.tap(
      find.byKey(const ValueKey('employee-lock-account-action')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('employee-account-lock-confirm')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    selected.value = 'emp-7';
    await tester.pumpAndSettle();
    final action = tester.widget<UtenButton>(
      find.byKey(const ValueKey('employee-lock-account-action')),
    );
    expect(action.isLoading, isFalse);
    expect(action.onPressed, isNotNull);
    final reads = repo.reads;
    repo.lockPending!.complete();
    await tester.pumpAndSettle();
    expect(repo.reads, reads);
    expect(
      find.byKey(const ValueKey('employee-unlock-account-action')),
      findsNothing,
    );
  });

  testWidgets('旧身份未完成详情响应不能盖回新身份资料', (tester) async {
    final pending = Completer<EmployeeProfile>();
    final repo = _Accounts({'accountStatus': 'active'})..pending = pending;
    final container = await _pump(tester, repo, settle: false);
    repo.pending = null;
    repo.values['fullName'] = '新身份资料';
    (container.read(sessionProvider.notifier) as _Actor).switchIdentity();
    await tester.pumpAndSettle();
    pending.complete(
      const EmployeeProfile(
        id: 'emp-6',
        code: 'UT0006',
        fullName: '旧身份资料',
        status: 'active',
        accountStatus: 'active',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('旧身份资料'), findsNothing);
    expect(find.text('新身份资料'), findsNWidgets(2));
  });

  testWidgets('375窄屏大字深色分类完整可选且不溢出', (tester) async {
    await _pump(
      tester,
      _Accounts({'accountStatus': 'active'}),
      size: const Size(375, 900),
      textScale: 1.4,
      dark: true,
    );
    if (_capture) {
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'employee-detail-phone-dark-account',
      );
    }
    final categories = find.byKey(const ValueKey('employee-detail-categories'));
    await tester.ensureVisible(categories);
    await tester.tap(
      find.descendant(of: categories, matching: find.byType(OutlinedButton)),
    );
    await tester.pumpAndSettle();
    expect(find.text('组织与合同'), findsOneWidget);
    expect(find.text('联系与车辆'), findsOneWidget);
    await tester.tap(find.text('档案文件'));
    await tester.pumpAndSettle();
    expect(tester.widget<UtenSegmentedFilter<int>>(categories).selected, 5);
    expect(find.text('无档案文件查看权限'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('账号新字段保留服务端false与旧server缺省null区别', () {
    final legacy = EmployeeProfile.fromJson({'id': 'e', 'code': 'UT1'});
    expect(legacy.accountDeleted, isFalse);
    expect(legacy.accountSupportAllowed, isNull);
    final denied = EmployeeProfile.fromJson({
      'id': 'e',
      'code': 'UT1',
      'accountDeleted': true,
      'accountSupportAllowed': false,
    });
    expect(denied.accountDeleted, isTrue);
    expect(denied.accountSupportAllowed, isFalse);
  });
}
