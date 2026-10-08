import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/network/session_event_bus.dart';
import 'package:uten_imp/core/security/auth_logout_fence.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/admin/models/impersonation.dart';
import 'package:uten_imp/features/admin/repositories/impersonation_repository.dart';
import 'package:uten_imp/features/auth/models/auth_session.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import 'support/fake_auth_logout_fence.dart';

const _base = 'https://impersonation-race.example.test/api';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'entering mode fences an old operation before target selection or storage changes',
    () async {
      final fixture = await _Fixture.create();
      final epoch = fixture.notifier.requestIntentEpoch;
      final scope = await ApiClient(Dio()).captureRequestScope(
        isCurrent: () => fixture.notifier.requestIntentEpoch == epoch,
      );
      fixture.repository.modeReply = Completer<ImpersonationModeResult>();
      final entering = fixture.notifier.enterImpersonationMode();
      await fixture.repository.modeStarted.future;
      await expectLater(
        scope.verify(),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'SESSION_CHANGED'),
        ),
      );
      expect(await fixture.storage.getImpersonationRecord(), isNull);
      fixture.repository.modeReply!.complete(
        const ImpersonationModeResult(
          modeToken: 'entered-mode',
          expiresIn: 300,
        ),
      );
      await entering;
      expect(
        fixture.container.read(sessionProvider).isImpersonationModeActive,
        isTrue,
      );
    },
  );

  test(
    'late enter cannot save its mode into a replaced staff intent',
    () async {
      final fixture = await _Fixture.create();
      fixture.repository.modeReply = Completer<ImpersonationModeResult>();
      final entering = fixture.notifier.enterImpersonationMode();
      final assertion = expectLater(
        entering,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'SESSION_CHANGED'),
        ),
      );
      await fixture.repository.modeStarted.future;
      await fixture.storage.beginSessionIntent(clearTokens: false);
      fixture.repository.modeReply!.complete(
        const ImpersonationModeResult(modeToken: 'stale-mode', expiresIn: 300),
      );
      await assertion;
      expect(await fixture.storage.getImpersonationModeToken(), 'mode-fixture');
      expect(
        fixture.container.read(sessionProvider).isImpersonationModeActive,
        isFalse,
      );
    },
  );

  test(
    'same-session profile refresh preserves mode-only state and does not create an intent',
    () async {
      final fixture = await _Fixture.create();
      await fixture.notifier.enterImpersonationMode();
      final expiration = fixture.container
          .read(sessionProvider)
          .impersonationModeExpiresAt;
      final epoch = fixture.notifier.requestIntentEpoch;
      final auth = await fixture.storage.getAuthTokenSnapshot();
      SessionEventBus.instance.publishProfile({
        'id': 'admin',
        'loginAccount': 'admin',
        'name': 'updated-profile',
        'permissions': <String>[],
        'superAdmin': true,
        '_utenAuthTokenGeneration': auth.generation,
        '_utenAuthIntentGeneration': auth.intentGeneration,
        '_utenAuthSessionLineage': auth.sessionLineage,
      });
      await pumpEventQueue();
      expect(fixture.notifier.requestIntentEpoch, epoch);
      expect(
        fixture.container.read(sessionProvider).user?.name,
        'updated-profile',
      );
      expect(
        fixture.container.read(sessionProvider).impersonationModeExpiresAt,
        expiration,
      );
      expect(await fixture.storage.getImpersonationModeToken(), 'entered-mode');
    },
  );

  test('late switch A cannot overwrite a completed switch B', () async {
    final fixture = await _Fixture.create();
    final delayed = fixture.repository.delay('A');
    final first = fixture.notifier.startImpersonation(targetEmployeeId: 'A');
    await fixture.repository.started('A');
    await fixture.notifier.startImpersonation(targetEmployeeId: 'B');
    delayed.complete(_result('A'));
    await first;
    expect(fixture.container.read(sessionProvider).user?.id, 'B');
    expect(
      (await fixture.storage.getImpersonationRecord())?.accessToken,
      'target-B',
    );
  });

  test('late end of A cannot clear a newer B or its mode', () async {
    final fixture = await _Fixture.create();
    await fixture.notifier.startImpersonation(targetEmployeeId: 'A');
    final endReply = fixture.repository.endReply = Completer<void>();
    final ending = fixture.notifier.endImpersonation();
    await fixture.repository.endStarted.future;
    await fixture.notifier.startImpersonation(targetEmployeeId: 'B');
    endReply.complete();
    await ending;
    expect(fixture.container.read(sessionProvider).user?.id, 'B');
    expect(
      (await fixture.storage.getImpersonationRecord())?.accessToken,
      'target-B',
    );
    expect(await fixture.storage.getImpersonationModeToken(), 'mode-fixture');
  });

  test(
    'explicit exit still clears mode after expiry already removed its target record',
    () async {
      final fixture = await _Fixture.create();
      await fixture.notifier.startImpersonation(targetEmployeeId: 'A');
      await fixture.storage.clearImpersonationRecord();
      expect(fixture.container.read(sessionProvider).isImpersonating, isTrue);
      await fixture.notifier.endImpersonation();
      expect(await fixture.storage.getImpersonationModeToken(), isNull);
      expect(fixture.container.read(sessionProvider).user?.id, 'admin');
    },
  );

  test(
    'old expiry notice and a stale banner cannot clear a completed B',
    () async {
      final fixture = await _Fixture.create();
      await fixture.notifier.startImpersonation(targetEmployeeId: 'A');
      final old = await fixture.notice();
      await fixture.notifier.startImpersonation(targetEmployeeId: 'B');
      final epoch = fixture.notifier.requestIntentEpoch;
      SessionEventBus.instance.impersonationExpired(old);
      SessionEventBus.instance.impersonationExpired();
      await pumpEventQueue();
      expect(fixture.notifier.requestIntentEpoch, epoch);
      expect(fixture.container.read(sessionProvider).user?.id, 'B');
      expect(
        (await fixture.storage.getImpersonationRecord())?.accessToken,
        'target-B',
      );
    },
  );

  test(
    'an old 401 arriving before B reads its mode cannot cancel the new switch',
    () async {
      final storage = _ModeReadGateStorage();
      final fixture = await _Fixture.create(configuredStorage: storage);
      await fixture.notifier.startImpersonation(targetEmployeeId: 'A');
      final old = await fixture.notice();
      storage.blockModeRead = true;
      final next = fixture.notifier.startImpersonation(targetEmployeeId: 'B');
      await storage.modeReadStarted.future;
      SessionEventBus.instance.impersonationExpired(old);
      await pumpEventQueue();
      storage.releaseModeRead.complete();
      await next;
      expect(fixture.container.read(sessionProvider).user?.id, 'B');
      expect((await storage.getImpersonationRecord())?.accessToken, 'target-B');
      expect(await storage.getImpersonationModeToken(), 'mode-fixture');
    },
  );

  test(
    'expiry of A cannot cancel the already pending user intent for B',
    () async {
      final fixture = await _Fixture.create();
      await fixture.notifier.startImpersonation(targetEmployeeId: 'A');
      final old = await fixture.notice();
      final delayed = fixture.repository.delay('B');
      final second = fixture.notifier.startImpersonation(targetEmployeeId: 'B');
      await fixture.repository.started('B');
      final epoch = fixture.notifier.requestIntentEpoch;
      SessionEventBus.instance.impersonationExpired(old);
      await pumpEventQueue();
      expect(fixture.notifier.requestIntentEpoch, epoch);
      delayed.complete(_result('B'));
      await second;
      expect(fixture.container.read(sessionProvider).user?.id, 'B');
      expect(
        (await fixture.storage.getImpersonationRecord())?.accessToken,
        'target-B',
      );
    },
  );

  test(
    'same staff-session refresh keeps a pending switch valid without advancing intent',
    () async {
      final fixture = await _Fixture.create();
      final delayed = fixture.repository.delay('A');
      final switching = fixture.notifier.startImpersonation(
        targetEmployeeId: 'A',
      );
      await fixture.repository.started('A');
      final epoch = fixture.notifier.requestIntentEpoch;
      final staff = await fixture.storage.getAuthTokenSnapshot();
      expect(
        await fixture.storage.saveTokensIfUnchanged(
          expected: staff,
          accessToken: 'staff-refreshed',
        ),
        isTrue,
      );
      delayed.complete(_result('A'));
      await switching;
      expect(fixture.notifier.requestIntentEpoch, epoch);
      expect(fixture.container.read(sessionProvider).user?.id, 'A');
    },
  );

  test(
    'changed staff intent prevents an old switch from being saved',
    () async {
      final fixture = await _Fixture.create();
      final delayed = fixture.repository.delay('A');
      final switching = fixture.notifier.startImpersonation(
        targetEmployeeId: 'A',
      );
      await fixture.repository.started('A');
      await fixture.storage.beginSessionIntent(clearTokens: false);
      delayed.complete(_result('A'));
      await switching;
      expect(fixture.container.read(sessionProvider).user?.id, 'admin');
      expect(await fixture.storage.getImpersonationRecord(), isNull);
    },
  );

  test(
    'a current scoped expiry restores admin while retaining its staff tokens',
    () async {
      final fixture = await _Fixture.create();
      await fixture.notifier.startImpersonation(targetEmployeeId: 'A');
      final staff = await fixture.storage.getAuthTokenSnapshot();
      SessionEventBus.instance.impersonationExpired(await fixture.notice());
      await pumpEventQueue();
      expect(fixture.container.read(sessionProvider).user?.id, 'admin');
      expect(fixture.container.read(sessionProvider).actor, isNull);
      expect(await fixture.storage.getImpersonationRecord(), isNull);
      expect(
        (await fixture.storage.getAuthTokenSnapshot()).isSameSession(staff),
        isTrue,
      );
    },
  );

  test(
    'an old target 401 cannot revoke a subsequently entered admin mode',
    () async {
      final fixture = await _Fixture.create();
      await fixture.notifier.startImpersonation(targetEmployeeId: 'A');
      final old = await fixture.notice();
      await fixture.notifier.enterImpersonationMode();
      final expiration = fixture.container
          .read(sessionProvider)
          .impersonationModeExpiresAt;
      SessionEventBus.instance.impersonationExpired(old);
      await pumpEventQueue();
      expect(fixture.container.read(sessionProvider).user?.id, 'admin');
      expect(
        fixture.container.read(sessionProvider).impersonationModeExpiresAt,
        expiration,
      );
      expect(
        fixture.container.read(sessionProvider).isImpersonationModeActive,
        isTrue,
      );
      expect(await fixture.storage.getImpersonationModeToken(), 'entered-mode');
    },
  );
}

class _Fixture {
  _Fixture(this.storage, this.repository, this.container, this.notifier);
  final SecureStorage storage;
  final _ImpersonationRepository repository;
  final ProviderContainer container;
  final SessionNotifier notifier;

  static Future<_Fixture> create({SecureStorage? configuredStorage}) async {
    final storage =
        configuredStorage ?? SecureStorage(const FlutterSecureStorage());
    await storage.saveTokens(
      accessToken: 'staff-access',
      refreshToken: 'staff-refresh',
    );
    final repository = _ImpersonationRepository();
    final container = ProviderContainer(
      overrides: [
        apiBaseUrlProvider.overrideWithValue(_base),
        secureStorageProvider.overrideWithValue(storage),
        authLogoutFenceProvider.overrideWithValue(FakeAuthLogoutFence()),
        authRepositoryProvider.overrideWithValue(_AuthRepository()),
        impersonationRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(sessionProvider.notifier);
    await pumpEventQueue();
    expect(container.read(sessionProvider).user?.id, 'admin');
    await storage.saveImpersonationModeToken('mode-fixture');
    return _Fixture(storage, repository, container, notifier);
  }

  Future<ImpersonationExpiryNotice> notice() async {
    final impersonation = (await storage.getImpersonationRecord())!;
    final staff = await storage.getAuthTokenSnapshot();
    return ImpersonationExpiryNotice(
      lineage: impersonation.lineage,
      staffLineage: staff.sessionLineage!,
      staffIntent: staff.intentGeneration,
      baseUrl: _base,
    );
  }
}

UserProfile _profile(String id) => UserProfile(
  id: id,
  loginAccount: id,
  name: id,
  employeeId: 'employee-$id',
  permissions: const [],
  superAdmin: id == 'admin',
);

ImpersonationStartResult _result(String id) => ImpersonationStartResult(
  accessToken: 'target-$id',
  expiresIn: 300,
  user: _profile(id),
  meta: ImpersonationMeta(
    readOnly: true,
    windowExpiresAtEpochMs: DateTime.now()
        .add(const Duration(minutes: 5))
        .millisecondsSinceEpoch,
  ),
);

class _ImpersonationRepository extends ImpersonationRepository {
  _ImpersonationRepository() : super(ApiClient(Dio()));
  final replies = <String, Completer<ImpersonationStartResult>>{};
  final starts = <String, Completer<void>>{};
  final endStarted = Completer<void>();
  Completer<void>? endReply;
  final modeStarted = Completer<void>();
  Completer<ImpersonationModeResult>? modeReply;
  @override
  Future<ImpersonationModeResult> enter() async {
    modeStarted.complete();
    return modeReply?.future ??
        const ImpersonationModeResult(
          modeToken: 'entered-mode',
          expiresIn: 300,
        );
  }

  Completer<ImpersonationStartResult> delay(String target) =>
      replies[target] = Completer<ImpersonationStartResult>();
  Future<void> started(String target) =>
      starts.putIfAbsent(target, Completer<void>.new).future;
  @override
  Future<ImpersonationStartResult> start({
    required String targetEmployeeId,
    required String modeToken,
  }) async {
    starts.putIfAbsent(targetEmployeeId, Completer<void>.new).complete();
    return replies[targetEmployeeId]?.future ?? _result(targetEmployeeId);
  }

  @override
  Future<void> end() async {
    endStarted.complete();
    await endReply?.future;
  }
}

class _AuthRepository extends Fake implements AuthRepository {
  @override
  Future<UserProfile> me() async => _profile('admin');
}

class _ModeReadGateStorage extends SecureStorage {
  _ModeReadGateStorage() : super(const FlutterSecureStorage());
  bool blockModeRead = false;
  final modeReadStarted = Completer<void>();
  final releaseModeRead = Completer<void>();
  @override
  Future<String?> getImpersonationModeToken() async {
    if (blockModeRead) {
      modeReadStarted.complete();
      await releaseModeRead.future;
      blockModeRead = false;
    }
    return super.getImpersonationModeToken();
  }
}
