import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/security/auth_logout_fence.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/auth/models/auth_session.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../../support/fake_auth_logout_fence.dart';

const _original = AppUser(
  id: 'user-1',
  code: 'U1',
  name: '员工一',
  employeeId: 'employee-1',
  department: '生产部',
  permissions: ['sales_order_finance:view', 'sales_order_finance:confirm'],
);
final _backend = StateProvider<String>((_) => 'https://first.invalid/api');

Map<String, dynamic> _me({
  AppUser user = _original,
  List<String>? permissions,
  bool includeSession = true,
}) => {
  'id': user.id,
  'loginAccount': user.code,
  'code': user.code,
  'name': user.name,
  'employeeId': user.employeeId,
  'department': user.department,
  'position': user.position,
  'superAdmin': user.superAdmin,
  'permissions': permissions ?? user.permissions,
  'businessResetGeneration': user.businessResetGeneration,
  if (user.businessDatasetId != null)
    'businessDatasetId': user.businessDatasetId,
  if (includeSession)
    'session': {
      'delegableSurfaceKeys': ['sales.orders'],
      'documentScopes': <String, dynamic>{},
      'preferences': <String, dynamic>{},
    },
};

class _Session extends SessionNotifier {
  _Session(this.initial);
  final SessionState initial;
  @override
  SessionState build() => initial;
  void replace(SessionState value) => state = value;
}

class _MeApi extends ApiClient {
  _MeApi() : super(Dio());
  final replies = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) {
    expect(path, ApiEndpoints.authMe);
    final reply = Completer<Map<String, dynamic>>();
    replies.add(reply);
    return reply.future;
  }

  Future<void> calls(int count) async {
    for (
      var attempts = 0;
      replies.length < count && attempts < 100;
      attempts++
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(replies.length, count);
  }
}

class _Auth extends Fake implements AuthRepository {
  @override
  Future<AuthResult> login(String loginAccount, String password) async =>
      const AuthResult(
        accessToken: 'replacement-access',
        refreshToken: 'replacement-refresh',
        expiresIn: 900,
        mustChangePassword: false,
        user: UserProfile(
          id: 'user-1',
          loginAccount: 'U1',
          code: 'U1',
          name: '重新登录',
          permissions: ['sales_order_finance:view'],
          superAdmin: false,
          employeeId: 'employee-1',
          department: '生产部',
        ),
      );
  @override
  Future<void> logout(String? refreshToken) async {}
}

class _Fixture {
  _Fixture(this.container, this.api, this.otherApi, this.storage);
  final ProviderContainer container;
  final _MeApi api, otherApi;
  final SecureStorage storage;
  _Session get owner => container.read(sessionProvider.notifier) as _Session;
  SessionSnapshotNotifier get snapshots =>
      container.read(sessionSnapshotProvider.notifier);
  SessionState get session => container.read(sessionProvider);
  static Future<_Fixture> create({SessionState? initial}) async {
    final api = _MeApi(), other = _MeApi();
    final storage = SecureStorage(const FlutterSecureStorage());
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(
          () => _Session(
            initial ??
                const SessionState(
                  status: AuthStatus.authenticated,
                  user: _original,
                ),
          ),
        ),
        secureStorageProvider.overrideWithValue(storage),
        authLogoutFenceProvider.overrideWithValue(FakeAuthLogoutFence()),
        authRepositoryProvider.overrideWithValue(_Auth()),
        apiBaseUrlProvider.overrideWith((ref) => ref.watch(_backend)),
        apiClientProvider.overrideWith(
          (ref) =>
              ref.watch(_backend) == 'https://first.invalid/api' ? api : other,
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(sessionSnapshotProvider, (_, _) {});
    await api.calls(1);
    return _Fixture(container, api, other, storage);
  }

  Future<void> completeInitial() async {
    api.replies.first.complete(_me());
    await container.read(sessionSnapshotProvider.future);
    await pumpEventQueue();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    RecentMeSnapshot.clear();
  });
  tearDown(RecentMeSnapshot.clear);

  test(
    'current /me binds the dataset identity through session and scope',
    () async {
      const dataset = 'bd6a3b4a-474e-48d6-8c42-c8ed99030bcd';
      final f = await _Fixture.create();
      await f.completeInitial();
      final before = f.session;
      final request = f.owner.captureProfileRead()!;
      expect(
        f.owner.applyMeProfileIfCurrent(
          _me()..['businessDatasetId'] = dataset,
          request: request,
        ),
        isTrue,
      );
      expect(f.session.user?.businessDatasetId, dataset);
      expect(f.session.isSameIdentity(before), isFalse);
      expect(
        f.container.read(authenticatedScopeProvider)?.businessDatasetId,
        dataset,
      );
      await pumpEventQueue();
      await f.api.calls(2);
      f.api.replies[1].complete(_me()..['businessDatasetId'] = dataset);
      await f.container.read(sessionSnapshotProvider.future);
    },
  );

  test(
    'a legacy /me cannot downgrade a bound dataset or change permissions',
    () async {
      const user = AppUser(
        id: 'user-1',
        code: 'U1',
        name: '员工一',
        permissions: ['sales_order_finance:view'],
        businessDatasetId: 'bd6a3b4a-474e-48d6-8c42-c8ed99030bcd',
      );
      final f = await _Fixture.create(
        initial: const SessionState(
          status: AuthStatus.authenticated,
          user: user,
        ),
      );
      f.api.replies.first.complete(_me(user: user));
      await f.container.read(sessionSnapshotProvider.future);
      final before = f.session;
      final request = f.owner.captureProfileRead()!;
      expect(
        f.owner.applyMeProfileIfCurrent(
          _me(user: user, permissions: ['authorization:manage'])
            ..remove('businessDatasetId'),
          request: request,
        ),
        isFalse,
      );
      expect(identical(f.session, before), isTrue);
      expect(
        f.container.read(authenticatedScopeProvider)?.businessDatasetId,
        user.businessDatasetId,
      );
    },
  );

  test(
    'a delayed /me from the old dataset cannot overwrite its replacement',
    () async {
      const original = AppUser(
        id: 'user-1',
        code: 'U1',
        name: '员工一',
        businessDatasetId: 'bd6a3b4a-474e-48d6-8c42-c8ed99030bcd',
      );
      const replacement = AppUser(
        id: 'user-1',
        code: 'U1',
        name: '员工一',
        businessDatasetId: 'ae4221bb-e660-4b30-a745-44bc62c4f14c',
      );
      final f = await _Fixture.create(
        initial: const SessionState(
          status: AuthStatus.authenticated,
          user: original,
        ),
      );
      f.api.replies.first.complete(_me(user: original));
      await f.container.read(sessionSnapshotProvider.future);
      final oldRead = f.owner.captureProfileRead()!;
      f.owner.replace(
        const SessionState(status: AuthStatus.authenticated, user: replacement),
      );
      expect(
        f.owner.applyMeProfileIfCurrent(
          _me(user: original, permissions: ['authorization:manage']),
          request: oldRead,
        ),
        isFalse,
      );
      expect(f.session.user, replacement);
      await pumpEventQueue();
      await f.api.calls(2);
      f.api.replies[1].complete(_me(user: replacement));
      await f.container.read(sessionSnapshotProvider.future);
      expect(
        f.container.read(authenticatedScopeProvider)?.businessDatasetId,
        replacement.businessDatasetId,
      );
    },
  );

  test(
    'same /me synchronizes permissions and profile without a duplicate GET or changing lease identity',
    () async {
      final f = await _Fixture.create();
      final before = f.session;
      final body = _me(permissions: ['sales_order_finance:view'])
        ..['name'] = '最新姓名';
      f.api.replies.first.complete(body);
      await f.container.read(sessionSnapshotProvider.future);
      await pumpEventQueue();
      expect(f.session.user?.permissions, ['sales_order_finance:view']);
      expect(f.session.user?.name, '最新姓名');
      expect(f.session.isSameIdentity(before), isTrue);
      expect(f.api.replies, hasLength(1));
      expect(
        confirmedSessionSnapshot(f.container.read(sessionSnapshotProvider)),
        isNotNull,
      );
    },
  );

  test(
    'unchanged or differently ordered permissions preserve the session instance and notify nobody',
    () async {
      final f = await _Fixture.create();
      final before = f.session;
      var notifications = 0;
      f.container.listen(sessionProvider, (_, _) => notifications++);
      f.api.replies.first.complete(
        _me(permissions: _original.permissions.reversed.toList()),
      );
      await f.container.read(sessionSnapshotProvider.future);
      await pumpEventQueue();
      expect(identical(f.session, before), isTrue);
      expect(notifications, 0);
      expect(f.api.replies, hasLength(1));
    },
  );

  test(
    'latest manual refresh wins both permissions and snapshot when responses arrive out of order',
    () async {
      final f = await _Fixture.create();
      await f.completeInitial();
      final older = f.snapshots.refresh();
      await f.api.calls(2);
      final newer = f.snapshots.refresh();
      await f.api.calls(3);
      f.api.replies[2].complete(_me(permissions: []));
      await newer;
      final winner = f.container.read(sessionSnapshotProvider).requireValue;
      f.api.replies[1].complete(
        _me(permissions: ['sales_order_finance:confirm']),
      );
      await older;
      await pumpEventQueue();
      expect(f.session.user?.permissions, isEmpty);
      expect(
        identical(
          f.container.read(sessionSnapshotProvider).requireValue,
          winner,
        ),
        isTrue,
      );
      expect(f.api.replies, hasLength(3));
    },
  );

  test(
    'manual refresh superseding initial build cannot reapply initial permissions later',
    () async {
      final f = await _Fixture.create();
      final refreshed = f.snapshots.refresh();
      await f.api.calls(2);
      f.api.replies[1].complete(_me(permissions: []));
      await refreshed;
      f.api.replies[0].complete(_me());
      await f.container.read(sessionSnapshotProvider.future);
      await pumpEventQueue();
      expect(f.session.user?.permissions, isEmpty);
      expect(f.api.replies, hasLength(2));
    },
  );

  test(
    'effective revocation applies even if session snapshot is missing, while scopes remain fail closed',
    () async {
      final f = await _Fixture.create();
      await f.completeInitial();
      final refreshed = f.snapshots.refresh();
      await f.api.calls(2);
      f.api.replies[1].complete(_me(permissions: [], includeSession: false));
      await refreshed;
      await pumpEventQueue();
      expect(f.session.user?.permissions, isEmpty);
      expect(f.container.read(sessionSnapshotProvider).hasError, isTrue);
      expect(
        confirmedSessionSnapshot(f.container.read(sessionSnapshotProvider)),
        isNull,
      );
      expect(f.api.replies, hasLength(2));
    },
  );

  test(
    'legacy profile without permissions cannot clear the visible grants',
    () async {
      final f = await _Fixture.create();
      f.api.replies.first.complete(_me()..remove('permissions'));
      await f.container.read(sessionSnapshotProvider.future);
      expect(f.session.user?.permissions, _original.permissions);
    },
  );

  test(
    'late response from another account cannot change the new visible profile',
    () async {
      final f = await _Fixture.create();
      const other = AppUser(
        id: 'user-2',
        code: 'U2',
        name: '员工二',
        permissions: ['profile:review'],
      );
      f.owner.replace(
        const SessionState(status: AuthStatus.authenticated, user: other),
      );
      await pumpEventQueue();
      await f.api.calls(2);
      f.api.replies[1].complete(_me(user: other));
      await f.container.read(sessionSnapshotProvider.future);
      f.api.replies[0].complete(_me(permissions: ['authorization:manage']));
      await pumpEventQueue();
      expect(f.session.user, other);
      expect(f.api.replies, hasLength(2));
    },
  );

  test(
    'same-account relogin rejects a delayed old profile even when the user id is unchanged',
    () async {
      final f = await _Fixture.create();
      await f.completeInitial();
      final oldRead = f.snapshots.refresh();
      await f.api.calls(2);
      await f.owner.login(account: 'U1', password: 'fixture');
      await pumpEventQueue();
      await f.api.calls(3);
      final latest = _me(permissions: ['sales_order_finance:view'])
        ..['name'] = '重新登录';
      f.api.replies[2].complete(latest);
      await f.container.read(sessionSnapshotProvider.future);
      f.api.replies[1].complete(_me(permissions: ['authorization:manage']));
      await oldRead;
      expect(f.session.user?.name, '重新登录');
      expect(f.session.user?.permissions, ['sales_order_finance:view']);
      expect(f.api.replies, hasLength(3));
    },
  );

  test(
    'backend switch rejects the old client response without changing the current permissions',
    () async {
      final f = await _Fixture.create();
      f.container.read(_backend.notifier).state = 'https://second.invalid/api';
      await pumpEventQueue();
      await f.otherApi.calls(1);
      f.otherApi.replies.first.complete(_me(permissions: []));
      await f.container.read(sessionSnapshotProvider.future);
      f.api.replies.first.complete(_me(permissions: ['authorization:manage']));
      await pumpEventQueue();
      expect(f.session.user?.permissions, isEmpty);
      expect(f.api.replies, hasLength(1));
      expect(f.otherApi.replies, hasLength(1));
    },
  );

  test(
    'impersonation applies only a matching target profile and preserves all actor and mode fields',
    () async {
      const actor = AppUser(
        id: 'admin',
        code: 'admin',
        name: '管理员',
        superAdmin: true,
      );
      final expiration = DateTime.now().add(const Duration(minutes: 3));
      final initial = SessionState(
        status: AuthStatus.authenticated,
        user: _original,
        actor: actor,
        impersonationReadOnly: true,
        impersonationModeExpiresAt: expiration,
        recentImpersonatedEmployeeIds: const ['one', 'two'],
      );
      final f = await _Fixture.create(initial: initial);
      f.api.replies.first.complete(_me(user: actor));
      await expectLater(
        f.container.read(sessionSnapshotProvider.future),
        throwsStateError,
      );
      expect(identical(f.session, initial), isTrue);
      final refresh = f.snapshots.refresh();
      await f.api.calls(2);
      f.api.replies[1].complete(_me(permissions: []));
      await refresh;
      expect(f.session.user?.id, _original.id);
      expect(f.session.user?.permissions, isEmpty);
      expect(identical(f.session.actor, actor), isTrue);
      expect(f.session.impersonationReadOnly, isTrue);
      expect(f.session.impersonationModeExpiresAt, expiration);
      expect(f.session.recentImpersonatedEmployeeIds, ['one', 'two']);
      expect(f.session.isSameIdentity(initial), isTrue);
    },
  );

  test(
    'recent initial-login /me snapshot is reused without any extra GET',
    () async {
      final storage = SecureStorage(const FlutterSecureStorage());
      await storage.saveTokens(
        accessToken: 'initial-access',
        refreshToken: 'initial-refresh',
      );
      final api = _MeApi();
      RecentMeSnapshot.remember(
        _original.id,
        _me()['session'] as Map<String, dynamic>,
        api,
        await storage.getAuthTokenSnapshot(),
      );
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWith(
            () => _Session(
              const SessionState(
                status: AuthStatus.authenticated,
                user: _original,
              ),
            ),
          ),
          apiClientProvider.overrideWithValue(api),
          secureStorageProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(container.dispose);
      expect(await container.read(sessionSnapshotProvider.future), isNotNull);
      expect(container.read(sessionProvider).user, _original);
      expect(api.replies, isEmpty);
    },
  );
}
