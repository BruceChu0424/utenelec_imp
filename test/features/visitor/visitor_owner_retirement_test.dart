import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/visitor_session_event_bus.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/visitor/models/visitor.dart';
import 'package:uten_imp/features/visitor/providers/visitor_session_provider.dart';
import 'package:uten_imp/features/visitor/repositories/visitor_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('visitor login rejects an incomplete or non-string credential pair', () {
    for (final json in <Map<String, dynamic>>[
      {'accessToken': 'A'},
      {'refreshToken': 'R'},
      {'accessToken': 'A', 'refreshToken': ''},
      {'accessToken': 123, 'refreshToken': 'R'},
    ]) {
      expect(() => VisitorLoginResult.fromJson(json), throwsFormatException);
    }
  });

  test(
    'retired restore refusal and queued expiry cannot clear a new visitor',
    () async {
      final storage = SecureStorage(const FlutterSecureStorage());
      await storage.saveVisitorTokens(
        accessToken: 'access-A',
        refreshToken: 'refresh-A',
      );
      final oldOwner = await storage.getVisitorTokenSnapshot();
      final repository = _Repository(storage);
      final container = ProviderContainer(
        overrides: [
          secureStorageProvider.overrideWithValue(storage),
          visitorRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(visitorSessionProvider.notifier);
      await repository.meStarted.future;
      await notifier.login('synthetic-B', 'test-only');
      expect(container.read(visitorSessionProvider).visitor!.id, 'B');
      VisitorSessionEventBus.instance.expire(
        sessionLineage: oldOwner.sessionLineage!,
        intentGeneration: oldOwner.intentGeneration,
      );
      repository.meGate.completeError(
        ApiException('UNAUTHORIZED', 'old account', httpStatus: 401),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(container.read(visitorSessionProvider).visitor!.id, 'B');
      expect(await storage.getVisitorAccessToken(), 'access-B');
      final current = await storage.getVisitorTokenSnapshot();
      VisitorSessionEventBus.instance.expire(
        sessionLineage: current.sessionLineage!,
        intentGeneration: current.intentGeneration,
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(visitorSessionProvider).isLoggedIn, false);
    },
  );

  test('an old logout response cannot clear a new login token pair', () async {
    final storage = SecureStorage(const FlutterSecureStorage());
    await storage.saveVisitorTokens(
      accessToken: 'access-A',
      refreshToken: 'refresh-A',
    );
    final adapter = _LogoutAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    final repository = DioVisitorRepository(ApiClient(dio), storage);
    final oldLogout = repository.logout();
    await adapter.started.future;
    await storage.saveVisitorTokens(
      accessToken: 'access-B',
      refreshToken: 'refresh-B',
    );
    adapter.complete.complete();
    await oldLogout;
    expect(await storage.getVisitorAccessToken(), 'access-B');
    expect(await storage.getVisitorRefreshToken(), 'refresh-B');
  });

  test('late real repository login A cannot overwrite newer login B', () async {
    final storage = SecureStorage(const FlutterSecureStorage());
    final adapter = _LoginRaceAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    final repository = DioVisitorRepository(ApiClient(dio), storage);
    final container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(storage),
        visitorRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(visitorSessionProvider.notifier);
    await Future<void>.delayed(Duration.zero);
    final lateA = notifier
        .login('synthetic-A', 'test-only')
        .then<Object?>((_) => null, onError: (Object error) => error);
    await adapter.startedA.future;
    final newerB = notifier.login('synthetic-B', 'test-only');
    await adapter.startedB.future;
    adapter.responseB.complete();
    await newerB;
    expect(container.read(visitorSessionProvider).visitor!.id, 'B');
    adapter.responseA.complete();
    final retiredOutcome = await lateA;
    expect(
      retiredOutcome,
      anyOf(
        isNull,
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'SESSION_CHANGED',
        ),
      ),
    );
    expect(await storage.getVisitorAccessToken(), 'access-B');
    expect(await storage.getVisitorRefreshToken(), 'refresh-B');
    expect(container.read(visitorSessionProvider).visitor!.id, 'B');
    expect(adapter.loginCalls, 2, reason: 'neither login may be replayed');
    expect(adapter.revokedTokens, isNot(contains('refresh-B')));
  });

  test(
    'notifier logout keeps its captured owner across a new visitor login',
    () async {
      final storage = _SwapAfterSnapshotStorage();
      await storage.saveVisitorTokens(
        accessToken: 'access-A',
        refreshToken: 'refresh-A',
      );
      final adapter = _LogoutOwnerAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      final repository = DioVisitorRepository(ApiClient(dio), storage);
      final container = ProviderContainer(
        overrides: [
          secureStorageProvider.overrideWithValue(storage),
          visitorRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(visitorSessionProvider.notifier);
      await adapter.meStarted.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(container.read(visitorSessionProvider).visitor!.id, 'A');
      storage.swapAfterNextSnapshot = true;
      await notifier.logout();
      expect(
        adapter.revokedTokens,
        ['refresh-A'],
        reason: 'an old logout must never re-read and revoke the new owner',
      );
      expect(await storage.getVisitorAccessToken(), 'access-B');
      expect(await storage.getVisitorRefreshToken(), 'refresh-B');
    },
  );
}

ResponseBody _visitorJson(Map<String, Object?> body) => ResponseBody.fromString(
  jsonEncode(body),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

class _LoginRaceAdapter implements HttpClientAdapter {
  final startedA = Completer<void>(), startedB = Completer<void>();
  final responseA = Completer<void>(), responseB = Completer<void>();
  final revokedTokens = <String>[];
  int loginCalls = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.endsWith('/logout')) {
      revokedTokens.add((options.data as Map)['refreshToken'] as String);
      return _visitorJson({});
    }
    if (!options.path.endsWith('/login')) {
      throw StateError('Unexpected fixture request');
    }
    loginCalls++;
    final a = (options.data as Map)['phone'] == 'synthetic-A';
    (a ? startedA : startedB).complete();
    await (a ? responseA : responseB).future;
    final owner = a ? 'A' : 'B';
    return _visitorJson({
      'accessToken': 'access-$owner',
      'refreshToken': 'refresh-$owner',
      'visitorId': owner,
      'visitorNo': 'TEST-$owner',
      'name': 'Synthetic $owner',
    });
  }

  @override
  void close({bool force = false}) {}
}

class _SwapAfterSnapshotStorage extends SecureStorage {
  _SwapAfterSnapshotStorage() : super(const FlutterSecureStorage());
  bool swapAfterNextSnapshot = false;
  @override
  Future<VisitorTokenSnapshot> getVisitorTokenSnapshot() async {
    final captured = await super.getVisitorTokenSnapshot();
    if (swapAfterNextSnapshot) {
      swapAfterNextSnapshot = false;
      // Another storage owner commits B after the caller captured A, before
      // the old logout's continuation dispatches its server-side revocation.
      await super.saveVisitorTokens(
        accessToken: 'access-B',
        refreshToken: 'refresh-B',
      );
    }
    return captured;
  }
}

class _LogoutOwnerAdapter implements HttpClientAdapter {
  final meStarted = Completer<void>();
  final revokedTokens = <String>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.endsWith('/me')) {
      meStarted.complete();
      return _visitorJson({
        'id': 'A',
        'visitorNo': 'TEST-A',
        'name': 'Synthetic A',
      });
    }
    if (options.path.endsWith('/logout')) {
      revokedTokens.add((options.data as Map)['refreshToken'] as String);
      return _visitorJson({});
    }
    throw StateError('Unexpected fixture request');
  }

  @override
  void close({bool force = false}) {}
}

class _Repository implements VisitorRepository {
  _Repository(this.storage);
  final SecureStorage storage;
  final meStarted = Completer<void>();
  final meGate = Completer<Visitor>();
  @override
  Future<Visitor> me() {
    meStarted.complete();
    return meGate.future;
  }

  @override
  Future<VisitorLoginResult> login(String phone, String code) async {
    await storage.saveVisitorTokens(
      accessToken: 'access-B',
      refreshToken: 'refresh-B',
    );
    return const VisitorLoginResult(
      accessToken: 'access-B',
      refreshToken: 'refresh-B',
      visitorId: 'B',
      visitorNo: 'TEST-B',
      name: 'Synthetic B',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LogoutAdapter implements HttpClientAdapter {
  final started = Completer<void>(), complete = Completer<void>();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    started.complete();
    await complete.future;
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
