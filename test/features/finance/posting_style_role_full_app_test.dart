import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/app.dart';
import 'package:uten_imp/core/router/app_router.dart';
import 'package:uten_imp/core/router/business_window_host.dart';
import 'package:uten_imp/features/shell/pages/main_shell_page.dart';
import 'package:uten_imp/features/basic_data/pages/payment_style_page.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/maintenance/server_maintenance.dart';
import 'package:uten_imp/core/platform/platform_window_title.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import '../../support/pump_until.dart';
import '../../support/uten_test_actions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/repositories/payment_style_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/posting_style_role_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/posting_style_role_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

const _stamp = '2026-10-11T10:00:00.123456Z';
const _missing = PostingStyleRole(
  roleKey: 'INVENTORY_ASSET',
  description: '库存商品科目',
  requiredCategory: 'ACCOUNT',
  updatedAt: _stamp,
  usable: false,
);
const _configured = PostingStyleRole(
  roleKey: 'SALES_REVENUE',
  description: '销售收入科目',
  requiredCategory: 'INCOME',
  updatedAt: _stamp,
  usable: true,
  styleId: 'income',
  styleName: '原销售收入',
);

class _Roles implements PostingStyleRoleRepository {
  List<PostingStyleRole> roles = [_missing, _configured];
  int writes = 0;
  bool stale = false;
  bool canConfigure = true;
  int reads = 0;
  @override
  Future<AuthenticatedRequestScope> captureScope({
    required bool Function() isCurrent,
  }) => AuthenticatedRequestScope.capture(
    baseUrl: 'http://fixture/api',
    storage: null,
    isCurrent: isCurrent,
  );
  @override
  Future<List<PostingStyleRole>> list(AuthenticatedRequestScope scope) async {
    reads++;
    return roles
        .map(
          (role) => PostingStyleRole(
            roleKey: role.roleKey,
            description: role.description,
            requiredCategory: role.requiredCategory,
            updatedAt: role.updatedAt,
            usable: role.usable,
            styleId: role.styleId,
            styleName: role.styleName,
            canConfigure: canConfigure && !role.usable,
          ),
        )
        .toList();
  }

  @override
  Future<PostingStyleRole> configure(
    PostingStyleRole role,
    String styleId,
    AuthenticatedRequestScope scope,
  ) async {
    await scope.verify();
    writes++;
    expect(role.updatedAt, _stamp);
    expect(styleId, 'account');
    if (stale) throw ApiException('CONFLICT', '科目用途已变化，请刷新核对后保存');
    final next = PostingStyleRole(
      roleKey: role.roleKey,
      description: role.description,
      requiredCategory: role.requiredCategory,
      updatedAt: _stamp,
      usable: true,
      styleId: styleId,
      styleName: '测试库存资产',
    );
    roles = [next, _configured];
    return next;
  }
}

class _Styles implements PaymentStyleRepository {
  _Styles(this.count);
  final int count;
  @override
  Future<List<PaymentStyleNode>> tree({String? category}) async => [
    for (var i = 1; i <= count; i++)
      PaymentStyleNode(
        id: 'account$i',
        code: 'SK${i.toString().padLeft(6, '0')}',
        name: '独立科目$i',
        category: 'ACCOUNT',
        status: '使用',
        children: [],
      ),
  ];
  @override
  Future<List<PaymentStyleNode>> subtree(String id) async =>
      (await tree()).where((row) => row.id == id).toList();
  @override
  Future<PaymentStyleDetail> detail(String id) async => PaymentStyleDetail(
    id: id,
    code: 'SK000001',
    name: '独立科目',
    category: 'ACCOUNT',
    level: 0,
    path: '/$id',
    childCount: 0,
    status: '使用',
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'ordinary-posting-fixture',
      code: 'SYNTHETIC',
      name: '合成财务查看员',
      permissions: [
        Perm.paymentStyleView,
        Perm.paymentStyleEdit,
        Perm.financePostExecute,
      ],
    ),
  );
}

class _ConfirmedSession extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _QuietMaintenance extends ServerMaintenanceController {
  _QuietMaintenance({required super.read, required super.ready});
  @override
  Future<void> checkNow() async {}
}

Future<_Roles> _mountApp(WidgetTester tester, int count) async {
  await setUtenTestSurfaceSize(tester, const Size(1280, 900));
  addTearDown(() => setUtenTestSurfaceSize(tester, null));
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final roles = _Roles();
  final dio = Dio(BaseOptions(baseUrl: 'https://posting.invalid/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: <String, dynamic>{},
        ),
      ),
    ),
  );
  final router = GoRouter(
    navigatorKey: appNavigatorKey,
    initialLocation: '/basicinfo/payment-style',
    routes: [
      ShellRoute(
        builder: (_, _, child) =>
            BusinessWindowHost(child: MainShellPage(child: child)),
        routes: [
          GoRoute(
            path: '/basicinfo/payment-style',
            builder: (_, _) => const PaymentStylePage(),
          ),
        ],
      ),
    ],
  );
  final recovery = ConnectionRecoveryController(probe: () async => true);
  final maintenance = _QuietMaintenance(
    read: () async => ServerMaintenanceSnapshot(
      phase: ServerMaintenancePhase.available,
      serverTime: DateTime.utc(2026, 11, 11),
    ),
    ready: () async => true,
  );
  addTearDown(() => router.dispose());
  addTearDown(maintenance.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appRouterProvider.overrideWithValue(router),
        sessionProvider.overrideWith(_Session.new),
        sessionSnapshotProvider.overrideWith(_ConfirmedSession.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'ordinary-posting-fixture'),
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.paymentStyleView,
          Perm.paymentStyleEdit,
          Perm.financePostExecute,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        apiClientProvider.overrideWithValue(ApiClient(dio)),
        apiBaseUrlProvider.overrideWithValue('https://posting.invalid/api'),
        connectionRecoveryProvider.overrideWith((_) => recovery),
        serverMaintenanceControllerProvider.overrideWithValue(maintenance),
        platformWindowTitleSyncProvider.overrideWith((_) {}),
        platformBrandingSnapshotProvider.overrideWithValue(
          PlatformBranding.defaults,
        ),
        sharedPreferencesProvider.overrideWithValue(prefs),
        postingStyleRoleRepositoryProvider.overrideWithValue(roles),
        paymentStyleRepositoryProvider.overrideWithValue(_Styles(count)),
      ],
      child: const UtenApp(),
    ),
  );
  await pumpAndSettleWithIo(tester);
  await tester.tap(find.byTooltip('系统科目用途').hitTestable());
  await pumpUntil(
    tester,
    () {
      final panel = find.byType(PostingStyleRolePanel);
      return panel.evaluate().isNotEmpty &&
          ModalRoute.of(tester.element(panel))?.animation?.status ==
              AnimationStatus.completed &&
          find.byType(UtenDropdownField).hitTestable().evaluate().isNotEmpty;
    },
    realIo: true,
    reason:
        'The complete ordinary role read and drawer presentation must be available',
  );
  expect(find.byType(PostingStyleRolePanel), findsOneWidget);
  return roles;
}

void main() {
  for (final count in [3, 5]) {
    for (final input in ['mouse', 'platform-submit']) {
      if (input == 'platform-submit' && count < 4) continue;
      testWidgets('real App posting drawer $input options=$count semantics', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        expect(SemanticsBinding.instance.semanticsEnabled, isTrue);
        final priorPlatform = debugDefaultTargetPlatformOverride;
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          final roles = await _mountApp(tester, count);
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: const Offset(2, 2));
          try {
            final field = find.byType(UtenDropdownField).hitTestable();
            expect(field, findsOneWidget);
            final fieldPoint = tester.getCenter(field);
            await mouse.moveTo(fieldPoint);
            await mouse.down(fieldPoint);
            await mouse.up();
            await pumpUntil(
              tester,
              () => find
                  .text('SK000001 · 独立科目1')
                  .hitTestable()
                  .evaluate()
                  .isNotEmpty,
              realIo: true,
              reason: 'The real dropdown must expose its pointer target',
            );
            final option = find.text('SK000001 · 独立科目1').hitTestable();
            expect(option, findsOneWidget);
            if (input == 'mouse') {
              final p = tester.getCenter(option);
              await mouse.moveTo(p);
              await mouse.down(p);
              await mouse.up();
            } else if (count >= 4) {
              await tester.enterText(
                find.byKey(const Key('uten-dropdown-search-input')),
                'SK000001',
              );
              await pumpWithIo(tester, const Duration(milliseconds: 100));
              await tester.testTextInput.receiveAction(TextInputAction.done);
            } else {
              await tester.sendKeyEvent(LogicalKeyboardKey.tab);
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            }
            await pumpWithIo(tester, const Duration(milliseconds: 300));
            await pumpWithIo(tester);
            debugPrint(
              'POSTING-POINTER input=$input options=$count reads=${roles.reads} writes=${roles.writes} value=${tester.widget<UtenDropdownField>(find.byType(UtenDropdownField).first).value}',
            );
            expect(
              tester
                  .widget<UtenDropdownField>(
                    find.byType(UtenDropdownField).first,
                  )
                  .value,
              'account1',
            );
            expect(
              tester
                  .widget<FilledButton>(
                    find.widgetWithText(FilledButton, '保存用途'),
                  )
                  .onPressed,
              isNotNull,
            );
            expect(roles.reads, 2);
            expect(roles.writes, 0);
            expect(tester.takeException(), isNull);
          } finally {
            await mouse.removePointer();
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          await pumpAndSettleWithIo(tester);
          debugDefaultTargetPlatformOverride = priorPlatform;
          handle.dispose();
        }
      });
    }
  }
}
