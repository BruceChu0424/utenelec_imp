import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/network/interceptors/auth_interceptor.dart';
import 'package:uten_imp/core/network/interceptors/automatic_request_interceptor.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/network/session_event_bus.dart';
import 'package:uten_imp/core/network/user_activity.dart';
import 'package:uten_imp/core/security/auth_logout_fence.dart';
import 'package:uten_imp/core/security/auth_token_issuer.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/core/security/tab_scoped_store.dart';
import 'package:uten_imp/features/auth/models/auth_session.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/shared/providers/session_keepalive_host.dart';
import 'package:uten_imp/shared/providers/session_kick_notice_host.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import 'support/fake_auth_logout_fence.dart';

const _base = 'https://session-watch.example.test/api';
const _message = '账号已在「Android 客户端」登录，本设备已自动下线';
final _issuer = AuthBackendRealmPolicy().issuerFor(_base);

void main() {
  testWidgets('刚打开登录页收到旧凭据被替换事件不弹窗', (tester) async {
    await _withFixture(tester, (f) async {
      SessionEventBus.instance.expire(
        const SessionExpiryNotice.replaced(_message),
      );
      await tester.pumpAndSettle();
      expect(find.text('当前设备已下线'), findsNothing);
      expect(f.container.read(sessionProvider).isLoggedIn, isFalse);
    });
  });

  testWidgets('启动恢复被拒绝只清旧凭据，不展示使用中下线弹窗', (tester) async {
    await _withFixture(tester, (f) async {
      expect(f.repository.meCalls, 1);
      expect((await f.storage.getAuthTokenSnapshot()).hasTokens, isFalse);
      expect(find.text('当前设备已下线'), findsNothing);
    }, staleStartup: true);
  });

  testWidgets('本次可见会话被替换只弹一次，规则说明收在标题提示icon', (tester) async {
    await _withFixture(tester, (f) async {
      await f.login();
      await f.replace();
      await tester.pumpAndSettle();
      expect(find.text('当前设备已下线'), findsOneWidget);
      expect(find.text(_message), findsOneWidget);
      expect(find.byType(UtenFieldHintIcon), findsOneWidget);
      expect(find.textContaining('同一账号同时只能'), findsNothing);
      for (var i = 0; i < 100; i++) {
        SessionEventBus.instance.expire(
          const SessionExpiryNotice.replaced(_message),
        );
      }
      await tester.pumpAndSettle();
      expect(find.text('当前设备已下线'), findsOneWidget);
      await tester.tap(find.byType(UtenCloseButton));
      await tester.pumpAndSettle();
      expect(find.text('当前设备已下线'), findsNothing);
    });
  });

  testWidgets('普通会话到期退出但不误报其他设备登录', (tester) async {
    await _withFixture(tester, (f) async {
      await f.login();
      await f.replace(status: 'expired');
      await tester.pumpAndSettle();
      expect(f.container.read(sessionProvider).isLoggedIn, isFalse);
      expect(find.text('当前设备已下线'), findsNothing);
    });
  });

  testWidgets('同账号重登后迟到的旧watch不得清新会话或弹窗', (tester) async {
    await _withFixture(tester, (f) async {
      await f.login();
      final previous = await f.storage.getAuthTokenSnapshot();
      final epoch = f.session.requestIntentEpoch;
      await f.login();
      await f.session.acceptSessionWatchResult(
        observed: previous,
        observedIntentEpoch: epoch,
        status: 'replaced',
        message: _message,
      );
      await tester.pumpAndSettle();
      expect(f.container.read(sessionProvider).isLoggedIn, isTrue);
      expect(await f.storage.getAccessToken(), 'access-2');
      expect(find.text('当前设备已下线'), findsNothing);
    });
  });

  testWidgets('同会话刷新轮换后仍能接收旧watch的权威替换结果', (tester) async {
    await _withFixture(tester, (f) async {
      await f.login();
      final previous = await f.storage.getAuthTokenSnapshot();
      final epoch = f.session.requestIntentEpoch;
      await f.storage.saveTokensIfUnchanged(
        expected: previous,
        accessToken: 'rotated',
        refreshToken: 'rotated-refresh',
        issuer: previous.issuer!,
      );
      await f.session.acceptSessionWatchResult(
        observed: previous,
        observedIntentEpoch: epoch,
        status: 'replaced',
        message: _message,
      );
      await tester.pumpAndSettle();
      expect((await f.storage.getAuthTokenSnapshot()).hasTokens, isFalse);
      expect(find.text('当前设备已下线'), findsOneWidget);
    });
  });

  testWidgets('下线到下一帧之间重登，不在新登录上展示旧弹窗', (tester) async {
    await _withFixture(tester, (f) async {
      await f.login();
      await f.replace();
      await f.login();
      await tester.pumpAndSettle();
      expect(f.container.read(sessionProvider).isLoggedIn, isTrue);
      expect(find.text('当前设备已下线'), findsNothing);
    });
  });

  testWidgets('弹窗已显示时重登会撤下旧提示', (tester) async {
    await _withFixture(tester, (f) async {
      await f.login();
      await f.replace();
      await tester.pumpAndSettle();
      expect(find.text('当前设备已下线'), findsOneWidget);
      await f.login();
      await tester.pumpAndSettle();
      expect(find.text('当前设备已下线'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('登录后立即建立watch，收到替换即退出弹窗，无需刷新或等心跳', (tester) async {
    await _withFixture(tester, (f) async {
      expect(f.adapter.pending, isEmpty);
      await f.login();
      await tester.pumpAndSettle();
      expect(f.adapter.pending, hasLength(1));
      expect(f.adapter.pending.single.options.headers['X-Uten-Automatic'], '1');
      expect(
        f.adapter.pending.single.options.headers['Authorization'],
        'Bearer access-1',
      );
      f.adapter.pending.single.complete({
        'status': 'replaced',
        'code': 'SESSION_REPLACED',
        'message': _message,
      });
      await tester.pumpAndSettle();
      expect(f.container.read(sessionProvider).isLoggedIn, isFalse);
      expect(find.text('当前设备已下线'), findsOneWidget);
      expect(f.adapter.pending, hasLength(1));
    }, watch: true);
  });

  testWidgets('快速重登取消旧监听，迟到的旧设备推送不影响新登录', (tester) async {
    await _withFixture(tester, (f) async {
      await f.login();
      await tester.pumpAndSettle();
      final old = f.adapter.pending.single;
      await f.login();
      await tester.pumpAndSettle();
      expect(old.cancelled, isTrue);
      expect(f.adapter.pending, hasLength(2));
      old.complete({'status': 'replaced', 'message': _message});
      await tester.pumpAndSettle();
      expect(f.container.read(sessionProvider).isLoggedIn, isTrue);
      expect(await f.storage.getAccessToken(), 'access-2');
      expect(find.text('当前设备已下线'), findsNothing);
    }, watch: true);
  });

  testWidgets('watch断网保留会话并退避重连，等待中不重复发请求', (tester) async {
    await _withFixture(tester, (f) async {
      await f.login();
      await tester.pumpAndSettle();
      final first = f.adapter.pending.single;
      first.fail();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(f.adapter.pending, hasLength(1));
      expect(f.container.read(sessionProvider).isLoggedIn, isTrue);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(f.adapter.pending, hasLength(2));
      await tester.pump(const Duration(seconds: 20));
      expect(f.adapter.pending, hasLength(2));
      expect(find.text('当前设备已下线'), findsNothing);
    }, watch: true);
  });

  testWidgets('旧服务端没有watch时短轮询兜底，401仍显示来源设备', (tester) async {
    await _withFixture(tester, (f) async {
      await f.login();
      await tester.pumpAndSettle();
      f.adapter.pending.single.complete({'code': 'NOT_FOUND'}, status: 404);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(f.adapter.probes, 1);
      expect(f.container.read(sessionProvider).isLoggedIn, isTrue);
      f.adapter.rejectProbes = true;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(f.container.read(sessionProvider).isLoggedIn, isFalse);
      expect(find.text('当前设备已下线'), findsOneWidget);
    }, watch: true);
  });

  testWidgets('窗口恢复立即重连，最小化不注销；卸载取消watch', (tester) async {
    await _withFixture(tester, (f) async {
      await f.login();
      await tester.pumpAndSettle();
      final first = f.adapter.pending.single;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(f.container.read(sessionProvider).isLoggedIn, isTrue);
      expect(first.cancelled, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(first.cancelled, isTrue);
      expect(f.adapter.pending, hasLength(2));
      final second = f.adapter.pending.last;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(second.cancelled, isTrue);
    }, watch: true);
  });

  testWidgets('本地填写继续续期，没人操作的watch不会续期', (tester) async {
    await _withFixture(tester, (f) async {
      var now = DateTime(2026, 11, 3);
      UserActivity.clock = () => now;
      await f.login();
      await tester.pumpAndSettle();
      UserActivity.record();
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(f.adapter.probes, 1);
      now = now.add(const Duration(minutes: 1));
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(f.adapter.probes, 1);
      expect(f.container.read(sessionProvider).isLoggedIn, isTrue);
    }, watch: true);
  });

  testWidgets('改密失败未改变可见身份，旧watch退休后仍建立新监听', (tester) async {
    await _withFixture(tester, (f) async {
      await f.login();
      await tester.pumpAndSettle();
      final first = f.adapter.pending.single;
      await expectLater(
        f.session.changePassword(oldPassword: 'old', newPassword: 'new'),
        throwsA(isA<ApiException>()),
      );
      first.complete({'status': 'active'});
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 250));
      expect(f.adapter.pending, hasLength(2));
      f.adapter.pending.last.complete({
        'status': 'replaced',
        'code': 'SESSION_REPLACED',
        'message': _message,
      });
      await tester.pumpAndSettle();
      expect(find.text('当前设备已下线'), findsOneWidget);
    }, watch: true);
  });

  testWidgets('损坏的watch响应不等于凭据失效，保留会话并重试', (tester) async {
    await _withFixture(tester, (f) async {
      await f.login();
      await tester.pumpAndSettle();
      f.adapter.pending.single.complete({
        'status': 'replaced',
        'code': 'INTERNAL',
      });
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(f.adapter.pending, hasLength(2));
      expect(f.container.read(sessionProvider).isLoggedIn, isTrue);
      expect(find.text('当前设备已下线'), findsNothing);
    }, watch: true);
  });
}

Future<void> _withFixture(
  WidgetTester tester,
  Future<void> Function(_Fixture) body, {
  bool watch = false,
  bool staleStartup = false,
}) async {
  FlutterSecureStorage.setMockInitialValues({});
  UserActivity.reset();
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final storage = SecureStorage(
    const FlutterSecureStorage(),
    sessionScope: _MemoryScope(),
  );
  final repository = _Repository();
  if (staleStartup) {
    await storage.saveTokens(
      accessToken: 'stale',
      refreshToken: 'stale-refresh',
      issuer: _issuer,
    );
    repository.restoreError = ApiException('SESSION_REPLACED', _message);
  }
  final adapter = _WatchAdapter();
  Dio makeDio() =>
      Dio(BaseOptions(baseUrl: _base))..httpClientAdapter = adapter;
  final dio = makeDio();
  dio.interceptors.addAll([
    const AutomaticRequestInterceptor(),
    AuthInterceptor(
      replay: dio.fetch<dynamic>,
      storage: storage,
      baseUrl: _base,
      dioFactory: makeDio,
    ),
  ]);
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      secureStorageProvider.overrideWithValue(storage),
      apiBaseUrlProvider.overrideWithValue(_base),
      authLogoutFenceProvider.overrideWithValue(FakeAuthLogoutFence()),
      authRepositoryProvider.overrideWithValue(repository),
      apiClientProvider.overrideWithValue(ApiClient(dio)),
      connectionRecoveryProvider.overrideWith(
        (ref) => ConnectionRecoveryController(
          probe: () async => false,
          probeDelays: const [Duration(hours: 1)],
        ),
      ),
    ],
  );
  try {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                const Text('登录页'),
                const SessionKickNoticeHost(),
                if (watch) const SessionKeepaliveHost(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await body(_Fixture(container, storage, repository, adapter));
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    dio.close(force: true);
    UserActivity.reset();
  }
}

class _Fixture {
  _Fixture(this.container, this.storage, this.repository, this.adapter);
  final ProviderContainer container;
  final SecureStorage storage;
  final _Repository repository;
  final _WatchAdapter adapter;
  SessionNotifier get session => container.read(sessionProvider.notifier);
  Future<void> login() =>
      session.login(account: 'worker', password: 'fixture-password');
  Future<void> replace({String status = 'replaced'}) async {
    await session.acceptSessionWatchResult(
      observed: await storage.getAuthTokenSnapshot(),
      observedIntentEpoch: session.requestIntentEpoch,
      status: status,
      message: _message,
    );
  }
}

class _MemoryScope implements TabScopedStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Repository implements AuthRepository {
  var logins = 0;
  var meCalls = 0;
  Object? restoreError;
  final revoked = <String?>[];
  @override
  Future<AuthResult> login(String account, String password) async {
    logins++;
    return AuthResult(
      accessToken: 'access-$logins',
      refreshToken: 'refresh-$logins',
      expiresIn: 900,
      mustChangePassword: false,
      user: _profile,
    );
  }

  @override
  Future<UserProfile> me() async {
    meCalls++;
    if (restoreError != null) throw restoreError!;
    return _profile;
  }

  @override
  Future<void> logout(String? refreshToken) async => revoked.add(refreshToken);
  @override
  Future<AuthResult> refresh(String token) => throw UnimplementedError();
  @override
  Future<AuthResult> changePassword(String oldPassword, String newPassword) =>
      Future.error(
        ApiException('VALIDATION_FAILED', 'fixture password rejected'),
      );
}

const _profile = UserProfile(
  id: 'worker-id',
  loginAccount: 'worker',
  permissions: [],
  superAdmin: false,
);

class _WatchAdapter implements HttpClientAdapter {
  final pending = <_PendingWatch>[];
  var probes = 0;
  var rejectProbes = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    if (options.path == '/auth/session/watch') {
      final watch = _PendingWatch(options);
      pending.add(watch);
      cancelFuture?.then((_) => watch.cancelled = true);
      return watch.reply.future;
    }
    if (options.path == '/auth/me') {
      probes++;
      return Future.value(
        _json(
          rejectProbes ? 401 : 200,
          rejectProbes ? {'code': 'UNAUTHORIZED'} : {'id': 'worker-id'},
        ),
      );
    }
    if (options.path == '/auth/refresh') {
      return Future.value(
        _json(401, {'code': 'SESSION_REPLACED', 'message': _message}),
      );
    }
    throw StateError('Unexpected fixture request ${options.path}');
  }

  @override
  void close({bool force = false}) {}
}

class _PendingWatch {
  _PendingWatch(this.options);
  final RequestOptions options;
  final reply = Completer<ResponseBody>();
  bool cancelled = false;
  void complete(Map<String, dynamic> body, {int status = 200}) {
    if (!reply.isCompleted) reply.complete(_json(status, body));
  }

  void fail() => reply.completeError(
    DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
    ),
  );
}

ResponseBody _json(int status, Map<String, dynamic> body) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
