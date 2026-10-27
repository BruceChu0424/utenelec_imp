@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/core/platform/desktop_window.dart';
import 'package:uten_imp/core/security/auth_logout_fence.dart';
import 'package:uten_imp/core/security/auth_refresh_lock.dart';
import 'package:uten_imp/core/security/auth_token_issuer.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/auth/models/auth_session.dart';
import 'package:uten_imp/features/auth/pages/login_page.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/features/auth/widgets/account_field.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/repositories/account_history_store.dart';

import '../../support/fake_auth_logout_fence.dart';

const _cloud = 'https://preflight-cloud.example.test/api';
const _otherCloud = 'https://other-preflight-cloud.example.test/api';
const _pendingAccount = 'preflight-worker';
const _winnerAccount = 'competing-worker';
const _password = ' exact fixture password ';
const _dataset = '33333333-3333-4333-8333-333333333333';
const _completed = Key('preflight-login-complete');
var _fixtureSequence = 0;

Finder get _account => find.descendant(
  of: find.byType(AccountField),
  matching: find.byType(TextField),
);
Finder get _passwordField => find.byType(TextField).at(1);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'fresh cloud-to-local preparation logs in on the first click with the local issuer',
    (tester) => _withFixture(tester, (fixture) async {
      await fixture.beginLogin(tester);
      expect(fixture.attempts, isEmpty);
      expect(fixture.container.read(apiBaseUrlProvider), _cloud);

      await fixture.finishProbe(tester);

      expect(fixture.probeCalls, 1);
      expect(fixture.attempts, [
        (
          endpoint: localApiBaseUrl,
          account: _pendingAccount,
          password: _password,
        ),
      ]);
      final tokens = await fixture.storage.getAuthTokenSnapshot();
      expect(tokens.accessToken, '$_pendingAccount-access');
      expect(tokens.refreshToken, '$_pendingAccount-refresh');
      expect(
        tokens.issuer,
        fixture.policy.issuerFor(localApiBaseUrl).withDataset(_dataset),
      );
      expect(fixture.container.read(sessionProvider).isLoggedIn, isTrue);
      expect(find.byKey(_completed), findsOneWidget);
      expect(await fixture.container.read(accountHistoryProvider).getAll(), [
        _pendingAccount,
      ]);
      expect(tester.takeException(), isNull);
    }),
    timeout: const Timeout(Duration(seconds: 30)),
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'logout during real preparation retires the pending login before credentials are sent',
    (tester) => _withFixture(tester, (fixture) async {
      final before = fixture.session.userIntentEpoch;
      await fixture.beginLogin(tester);

      await fixture.session.logout();
      expect(fixture.session.userIntentEpoch, greaterThan(before));
      await fixture.finishProbe(tester);

      expect(fixture.attempts, isEmpty);
      final tokens = await fixture.storage.getAuthTokenSnapshot();
      expect(tokens.hasTokens, isFalse);
      expect(
        fixture.container.read(sessionProvider).status,
        AuthStatus.unauthenticated,
      );
      await fixture.expectPendingLoginCancelled(tester);
    }),
    timeout: const Timeout(Duration(seconds: 30)),
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'a competing real login during preparation wins without sending the old form credentials',
    (tester) => _withFixture(tester, (fixture) async {
      final before = fixture.session.userIntentEpoch;
      await fixture.beginLogin(tester);

      await fixture.session.login(
        account: _winnerAccount,
        password: 'winner fixture password',
      );
      expect(fixture.session.userIntentEpoch, greaterThan(before));
      final winner = await fixture.storage.getAuthTokenSnapshot();
      expect(winner.accessToken, '$_winnerAccount-access');
      expect(
        winner.issuer,
        fixture.policy.issuerFor(_cloud).withDataset(_dataset),
      );

      await fixture.finishProbe(tester);

      expect(fixture.attempts, [
        (
          endpoint: _cloud,
          account: _winnerAccount,
          password: 'winner fixture password',
        ),
      ]);
      expect(
        await fixture.storage.getAuthTokenSnapshot(),
        isA<AuthTokenSnapshot>().having(
          (tokens) => tokens.isSameSession(winner),
          'the competing login record is preserved',
          isTrue,
        ),
      );
      await fixture.expectPendingLoginCancelled(tester);
    }),
    timeout: const Timeout(Duration(seconds: 30)),
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  for (final change in ['mode', 'custom URL']) {
    testWidgets(
      'an explicit server $change A-B-A during preparation retires the old request despite identical final settings',
      (tester) => _withFixture(tester, (fixture) async {
        final revision = serverSelectionRevision(fixture.preferences);
        await fixture.beginLogin(tester);

        if (change == 'mode') {
          await writeServerMode(fixture.preferences, ServerMode.cloud);
          await writeServerMode(fixture.preferences, ServerMode.auto);
        } else {
          await writeCloudUrl(fixture.preferences, _otherCloud);
          await writeCloudUrl(fixture.preferences, _cloud);
        }
        // Deliberately do not flush the intermediate endpoint. The public
        // selection revision must retain the user's A-B-A intent by itself.
        fixture.container.invalidate(apiBaseUrlProvider);
        expect(readServerMode(fixture.preferences), ServerMode.auto);
        expect(readCloudUrl(fixture.preferences), _cloud);
        expect(fixture.container.read(apiBaseUrlProvider), _cloud);
        expect(
          serverSelectionRevision(fixture.preferences),
          greaterThan(revision),
        );

        await fixture.finishProbe(tester);

        expect(fixture.attempts, isEmpty);
        expect(
          (await fixture.storage.getAuthTokenSnapshot()).hasTokens,
          isFalse,
        );
        await fixture.expectPendingLoginCancelled(tester);
      }),
      timeout: const Timeout(Duration(seconds: 30)),
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}

typedef _Attempt = ({String endpoint, String account, String password});

Future<void> _withFixture(
  WidgetTester tester,
  Future<void> Function(_Fixture fixture) body,
) async {
  final fixture = await _open(tester);
  try {
    await body(fixture);
  } finally {
    // Widget binding verifies pending timers before external tearDown callbacks.
    // Dispose inside the test body so the real probe's periodic timer is gone.
    await fixture.dispose(tester);
  }
}

Future<_Fixture> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1000, 680);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({
    'uten.local_server_reachable': false,
    'uten.server_url_override': _cloud,
  });
  final fixtureId = ++_fixtureSequence;
  final tombstone = AuthTokenSnapshot(
    accessToken: null,
    refreshToken: null,
    generation: 1,
    intentGeneration: 1,
    sessionLineage: 'login-preparation-fixture-$fixtureId',
  );
  FlutterSecureStorage.setMockInitialValues({
    'auth.token_record.v1': jsonEncode(tombstone.toJson()),
  });
  final preferences = await SharedPreferences.getInstance();
  final health = Completer<bool>();
  final attempts = <_Attempt>[];
  // Each test owns an independent mock platform store. Give its real token
  // record queue the same isolation instead of retaining another FakeAsync
  // case's process-global lock scope or exercising unrelated legacy adoption.
  final storage = SecureStorage(
    const FlutterSecureStorage(),
    staffTokenRecordLock: AuthRefreshLock(
      'login-preparation-session-owner-fixture-$fixtureId',
    ),
  );
  final policy = AuthBackendRealmPolicy(
    trustedCompanyEndpoints: [localApiBaseUrl, _cloud],
  );
  final controller = DesktopWindowController(enabled: false);
  var probeCalls = 0;
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      secureStorageProvider.overrideWithValue(storage),
      authLogoutFenceProvider.overrideWithValue(FakeAuthLogoutFence()),
      authBackendRealmPolicyProvider.overrideWithValue(policy),
      localServerReachableProvider.overrideWith(
        (ref) => LocalServerReachabilityNotifier(
          preferences,
          web: false,
          healthProbe: () {
            probeCalls++;
            return health.future;
          },
        ),
      ),
      authRepositoryProvider.overrideWith(
        (ref) => _EndpointRepository(ref.watch(apiBaseUrlProvider), attempts),
      ),
      connectionRecoveryProvider.overrideWith(
        (ref) => ConnectionRecoveryController(
          probe: () async => false,
          probeDelays: const [Duration(hours: 1)],
        ),
      ),
      desktopWindowControllerProvider.overrideWithValue(controller),
      platformBrandingSnapshotProvider.overrideWithValue(
        PlatformBranding.defaults,
      ),
    ],
  );
  final session = container.read(sessionProvider.notifier);
  final router = GoRouter(
    initialLocation: '/login',
    routes: [
      GoRoute(
        path: '/login',
        builder: (_, _) => const LoginPage(returnTo: '/complete'),
      ),
      GoRoute(
        path: '/complete',
        builder: (_, _) => const Scaffold(body: SizedBox(key: _completed)),
      ),
    ],
  );
  final fixture = _Fixture(
    preferences: preferences,
    health: health,
    attempts: attempts,
    storage: storage,
    policy: policy,
    container: container,
    session: session,
    router: router,
    controller: controller,
    readProbeCalls: () => probeCalls,
  );
  addTearDown(() => fixture.dispose(tester));
  try {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: buildLightTheme(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(apiBaseUrlProvider), _cloud);
    expect(probeCalls, 1);
    expect(attempts, isEmpty);
    expect(tester.takeException(), isNull);
    return fixture;
  } catch (_) {
    await fixture.dispose(tester);
    rethrow;
  }
}

class _Fixture {
  _Fixture({
    required this.preferences,
    required this.health,
    required this.attempts,
    required this.storage,
    required this.policy,
    required this.container,
    required this.session,
    required this.router,
    required this.controller,
    required this.readProbeCalls,
  });

  final SharedPreferences preferences;
  final Completer<bool> health;
  final List<_Attempt> attempts;
  final SecureStorage storage;
  final AuthBackendRealmPolicy policy;
  final ProviderContainer container;
  final SessionNotifier session;
  final GoRouter router;
  final DesktopWindowController controller;
  final int Function() readProbeCalls;
  bool _disposed = false;
  int get probeCalls => readProbeCalls();

  Future<void> dispose(WidgetTester tester) async {
    if (_disposed) return;
    _disposed = true;
    try {
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      router.dispose();
      container.dispose();
      controller.dispose();
      await tester.pump();
    }
  }

  Future<void> beginLogin(WidgetTester tester) async {
    await tester.ensureVisible(_account);
    await tester.enterText(_account, _pendingAccount);
    await tester.ensureVisible(_passwordField);
    await tester.enterText(_passwordField, _password);
    await tester.ensureVisible(find.byType(UtenButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(UtenButton));
    await tester.pump();
    expect(attempts, isEmpty);
    expect(health.isCompleted, isFalse);
  }

  Future<void> finishProbe(WidgetTester tester) async {
    health.complete(true);
    await tester.pumpAndSettle();
    expect(probeCalls, 1);
  }

  Future<void> expectPendingLoginCancelled(WidgetTester tester) async {
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byKey(_completed), findsNothing);
    expect(await container.read(accountHistoryProvider).getAll(), isEmpty);
    expect(tester.takeException(), isNull);
  }
}

class _EndpointRepository implements AuthRepository {
  _EndpointRepository(this.endpoint, this.attempts);
  final String endpoint;
  final List<_Attempt> attempts;

  @override
  Future<AuthResult> login(String loginAccount, String password) async {
    attempts.add((
      endpoint: endpoint,
      account: loginAccount,
      password: password,
    ));
    return _result(loginAccount);
  }

  @override
  Future<void> logout(String? refreshToken) async {}

  @override
  Future<UserProfile> me() async => _result(_winnerAccount).user;

  @override
  Future<AuthResult> refresh(String refreshToken) async =>
      throw StateError('This fixture starts without a refreshable session');

  @override
  Future<AuthResult> changePassword(
    String oldPassword,
    String newPassword,
  ) async =>
      throw StateError('Password changes are not part of login preparation');
}

AuthResult _result(String account) => AuthResult(
  accessToken: '$account-access',
  refreshToken: '$account-refresh',
  expiresIn: 900,
  mustChangePassword: false,
  user: UserProfile(
    id: '11111111-1111-4111-8111-111111111111',
    employeeId: '22222222-2222-4222-8222-222222222222',
    loginAccount: account,
    code: account,
    businessDatasetId: _dataset,
    permissions: const [],
    superAdmin: false,
  ),
);
