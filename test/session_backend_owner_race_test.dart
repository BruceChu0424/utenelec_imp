import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/security/auth_logout_fence.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/auth/models/auth_session.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import 'support/fake_auth_logout_fence.dart';

const _a = 'https://independent-a.invalid/api';
const _b = 'https://independent-b.invalid/api';
final _backend = StateProvider<String>((ref) => _a);
final _superseded = predicate<Object?>(
  (error) => error.runtimeType.toString() == 'SessionMutationSuperseded',
  'the public superseded-operation outcome',
);

Future<Object?> _outcome(Future<void> value) => value.then<Object?>(
  (_) => null,
  onError: (Object error, StackTrace stack) => error,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  test(
    'late login cannot install A credentials after selecting independent B',
    () async {
      final f = _Fixture(holdLogin: true);
      addTearDown(f.container.dispose);
      await pumpEventQueue();
      final pending = _outcome(
        f.session.login(account: 'a', password: 'fixture'),
      );
      await f.a.loginStarted.future;
      f.select(_b);
      f.a.loginReply.complete(_result('a'));
      final result = await pending;
      expect(await f.storage.getAccessToken(), isNull);
      expect(
        f.container.read(sessionProvider).status,
        AuthStatus.unauthenticated,
      );
      expect(result, _superseded);
    },
  );

  test(
    'same uid and dataset do not authorize cleanup through independent B',
    () async {
      final f = _Fixture(holdLogin: true);
      addTearDown(f.container.dispose);
      await pumpEventQueue();
      final pending = _outcome(
        f.session.login(account: 'a', password: 'fixture'),
      );
      await f.a.loginStarted.future;
      f.select(_b);
      await f.session.login(account: 'b', password: 'fixture');
      f.a.loginReply.complete(_result('a'));
      final result = await pending;
      expect(await f.storage.getAccessToken(), 'b-access');
      expect(f.container.read(sessionProvider).user?.code, 'b');
      expect(f.b.revoked, isNot(contains('a-refresh')));
      expect(f.a.revoked, contains('a-refresh'));
      expect(result, _superseded);
    },
  );

  test(
    'a backend A-B-A round trip does not revive the first login intent',
    () async {
      final f = _Fixture(holdLogin: true);
      addTearDown(f.container.dispose);
      await pumpEventQueue();
      final pending = _outcome(
        f.session.login(account: 'a', password: 'fixture'),
      );
      await f.a.loginStarted.future;
      f.select(_b);
      await pumpEventQueue();
      f.select(_a);
      f.a.loginReply.complete(_result('a'));
      final result = await pending;
      expect(await f.storage.getAccessToken(), isNull);
      expect(result, _superseded);
    },
  );

  test(
    'late password result uses A cleanup and cannot replace the B winner',
    () async {
      final f = _Fixture();
      addTearDown(f.container.dispose);
      await pumpEventQueue();
      await f.session.login(account: 'a', password: 'fixture');
      final pending = _outcome(
        f.session.changePassword(oldPassword: 'old', newPassword: 'new'),
      );
      await f.a.passwordStarted.future;
      f.select(_b);
      await f.session.login(account: 'b', password: 'fixture');
      f.a.passwordReply.complete(_result('a-changed'));
      final result = await pending;
      expect(await f.storage.getAccessToken(), 'b-access');
      expect(
        f.b.revoked.whereType<String>().where(
          (token) => token.startsWith('a-'),
        ),
        isEmpty,
      );
      expect(f.a.revoked, contains('a-changed-refresh'));
      expect(result, _superseded);
    },
  );

  test(
    'an error from superseded A cannot surface as the B login result',
    () async {
      final f = _Fixture(holdLogin: true);
      addTearDown(f.container.dispose);
      await pumpEventQueue();
      final pending = _outcome(
        f.session.login(account: 'a', password: 'fixture'),
      );
      await f.a.loginStarted.future;
      f.select(_b);
      await f.session.login(account: 'b', password: 'fixture');
      f.a.loginReply.completeError(StateError('old endpoint failed'));
      expect(await pending, _superseded);
      expect(await f.storage.getAccessToken(), 'b-access');
      expect(f.container.read(sessionProvider).user?.code, 'b');
    },
  );
}

class _Fixture {
  _Fixture({bool holdLogin = false}) {
    a = _Endpoint('a', holdLogin: holdLogin);
    b = _Endpoint('b');
    container = ProviderContainer(
      overrides: <Override>[
        secureStorageProvider.overrideWithValue(storage),
        authLogoutFenceProvider.overrideWithValue(FakeAuthLogoutFence()),
        apiBaseUrlProvider.overrideWith((ref) => ref.watch(_backend)),
        authRepositoryProvider.overrideWith(
          (ref) => ref.watch(_backend) == _a ? a : b,
        ),
        connectionRecoveryProvider.overrideWith(
          (ref) => ConnectionRecoveryController(
            probe: () async => false,
            probeDelays: const <Duration>[Duration(hours: 1)],
          ),
        ),
      ],
    );
    session = container.read(sessionProvider.notifier);
  }
  final storage = SecureStorage(const FlutterSecureStorage());
  late final _Endpoint a, b;
  late final ProviderContainer container;
  late final SessionNotifier session;
  void select(String url) => container.read(_backend.notifier).state = url;
}

class _Endpoint implements AuthRepository {
  _Endpoint(this.name, {this.holdLogin = false});
  final String name;
  final bool holdLogin;
  final loginStarted = Completer<void>();
  final loginReply = Completer<AuthResult>();
  final passwordStarted = Completer<void>();
  final passwordReply = Completer<AuthResult>();
  final revoked = <String?>[];
  @override
  Future<AuthResult> login(String account, String password) async {
    if (!loginStarted.isCompleted) loginStarted.complete();
    if (holdLogin) return loginReply.future;
    return _result(name);
  }

  @override
  Future<AuthResult> changePassword(
    String oldPassword,
    String newPassword,
  ) async {
    passwordStarted.complete();
    return passwordReply.future;
  }

  @override
  Future<void> logout(String? token) async => revoked.add(token);
  @override
  Future<UserProfile> me() async => _result(name).user;
  @override
  Future<AuthResult> refresh(String token) async => throw UnimplementedError();
}

AuthResult _result(String label) => AuthResult(
  accessToken: '$label-access',
  refreshToken: '$label-refresh',
  expiresIn: 900,
  mustChangePassword: false,
  user: UserProfile(
    id: 'same-user',
    employeeId: 'same-employee',
    loginAccount: label,
    code: label,
    businessDatasetId: '11111111-1111-4111-8111-111111111111',
    permissions: const <String>[],
    superAdmin: false,
  ),
);
