import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_geometry.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/uten_page_prefs_notifier.dart';

const _prefKey = 'ui.dropdownGeometry';
const _serverA = 'https://a.invalid/api';
const _serverB = 'https://b.invalid/api';
const _ownerA = AuthenticatedScope(userId: 'a', epoch: 1);
const _ownerB = AuthenticatedScope(userId: 'b', epoch: 1);
const _field = 'goods.material';

final _scope = StateProvider<AuthenticatedScope?>((_) => _ownerA);
final _server = StateProvider<String>((_) => _serverA);
final _client = StateProvider<_Api>((_) => _Api());

class _Session extends SessionNotifier {
  @override
  SessionState build() {
    final scope = ref.watch(_scope);
    return SessionState(
      status: scope == null
          ? AuthStatus.unauthenticated
          : AuthStatus.authenticated,
      user: scope == null
          ? null
          : AppUser(id: scope.userId, code: scope.userId, name: scope.userId),
    );
  }
}

class _Api extends ApiClient {
  _Api() : super(Dio());

  Map<String, Object?> preferences = {};
  final writePaths = <String>[];
  final writes = <Object?>[];
  Completer<Map<String, dynamic>>? snapshotGate;
  Completer<void>? pushGate;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => path == ApiEndpoints.authMe
      ? snapshotGate == null
            ? {
                'session': {'preferences': preferences},
              }
            : await snapshotGate!.future
      : {};

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    writePaths.add(path);
    writes.add(body);
    await pushGate?.future;
    return {};
  }
}

class _Harness {
  _Harness(this.container);
  final ProviderContainer container;
  bool _closed = false;

  _Api get api => container.read(_client);
  DropdownGeometryPrefsNotifier get notifier =>
      container.read(dropdownGeometryPrefsProvider.notifier);
  Map<String, UtenDropdownMenuGeometry> get value =>
      container.read(dropdownGeometryPrefsProvider);

  void close() {
    if (_closed) return;
    _closed = true;
    container.dispose();
  }
}

Future<_Harness> _boot(
  SharedPreferences local, {
  _Api? api,
  AuthenticatedScope? scope = _ownerA,
  String server = _serverA,
  bool wait = true,
}) async {
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(local),
      _scope.overrideWith((_) => scope),
      _server.overrideWith((_) => server),
      if (api != null) _client.overrideWith((_) => api),
      sessionProvider.overrideWith(_Session.new),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      apiClientProvider.overrideWith((ref) => ref.watch(_client)),
    ],
  );
  final harness = _Harness(container);
  addTearDown(harness.close);
  container.listen(dropdownGeometryPrefsProvider, (_, _) {});
  if (wait) await container.read(sessionSnapshotProvider.future);
  await Future<void>.value();
  return harness;
}

UtenDropdownMenuGeometry _geometry({double width = 460}) =>
    UtenDropdownMenuGeometry(
      width: width,
      height: 520,
      offset: const Offset(-36, 24),
    );

Map<String, Object?> _encodedGeometry({double width = 460}) => {
  'w': width,
  'h': 520,
  'x': -36,
  'y': 24,
};

void _expectGeometry(UtenDropdownMenuGeometry? value, {double width = 460}) {
  expect(value, isNotNull);
  expect(value!.width, width);
  expect(value.height, 520);
  expect(value.offset, const Offset(-36, 24));
}

void main() {
  late SharedPreferences local;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    local = await SharedPreferences.getInstance();
  });

  testWidgets('a fresh ProviderContainer restores persisted geometry', (
    tester,
  ) async {
    final first = await _boot(local);
    await tester.pump();
    first.notifier.updateFor(_field, _geometry());
    first.close();

    final reopened = await _boot(local);
    await tester.pump();
    _expectGeometry(reopened.value[_field]);
    expect(reopened.api.writes, isEmpty);
  });

  testWidgets('reset removes persisted geometry across a fresh container', (
    tester,
  ) async {
    final first = await _boot(local);
    await tester.pump();
    first.notifier.updateFor(_field, _geometry());
    first.notifier.updateFor(_field, null);
    first.close();

    final reopened = await _boot(local);
    await tester.pump();
    expect(reopened.value, isEmpty);
  });

  testWidgets('account, actor and server use separate local geometry', (
    tester,
  ) async {
    final h = await _boot(local);
    await tester.pump();
    h.notifier.updateFor(_field, _geometry());

    h.container.read(_scope.notifier).state = _ownerB;
    await tester.pump();
    expect(h.value, isEmpty);
    h.notifier.updateFor(_field, _geometry(width: 620));

    h.container.read(_scope.notifier).state = _ownerA;
    await tester.pump();
    _expectGeometry(h.value[_field]);

    h.container.read(_scope.notifier).state = const AuthenticatedScope(
      userId: 'a',
      actorId: 'operator',
      epoch: 1,
    );
    await tester.pump();
    expect(h.value, isEmpty);

    h.container.read(_scope.notifier).state = _ownerA;
    h.container.read(_server.notifier).state = _serverB;
    h.container.read(_client.notifier).state = _Api();
    await tester.pump();
    expect(h.value, isEmpty);

    h.container.read(_server.notifier).state = _serverA;
    h.container.read(_client.notifier).state = _Api();
    await tester.pump();
    _expectGeometry(h.value[_field]);
    h.close();
  });

  testWidgets(
    'queued geometry is cancelled on account and login epoch changes',
    (tester) async {
      final h = await _boot(local);
      await tester.pump();
      final originalApi = h.api;
      h.notifier.updateFor(_field, _geometry());
      h.container.read(_scope.notifier).state = _ownerB;
      await tester.pump();
      h.container.read(_scope.notifier).state = const AuthenticatedScope(
        userId: 'a',
        epoch: 2,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(originalApi.writes, isEmpty);
      _expectGeometry(h.value[_field]);
      h.close();
    },
  );

  testWidgets('a late write cannot populate the replacement server snapshot', (
    tester,
  ) async {
    final original = _Api()..pushGate = Completer<void>();
    final h = await _boot(local, api: original);
    await tester.pump();
    h.notifier.updateFor(_field, _geometry());
    expect(h.container.read(sessionProvider).user?.id, _ownerA.userId);
    expect(h.container.read(authenticatedScopeProvider), _ownerA);
    expect(h.container.read(apiBaseUrlProvider), _serverA);
    expect(identical(h.container.read(apiClientProvider), original), isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(original.writePaths, [ApiEndpoints.userPreference(_prefKey)]);
    expect(original.writes, hasLength(1));

    final replacement = _Api();
    h.container.read(_client.notifier).state = replacement;
    h.container.read(_server.notifier).state = _serverB;
    await tester.pump();
    await h.container.read(sessionSnapshotProvider.future);
    original.pushGate!.complete();
    await tester.pump();

    expect(h.value, isEmpty);
    expect(replacement.writes, isEmpty);
    expect(
      h.container.read(sessionSnapshotProvider).value!.preferences[_prefKey],
      isNull,
    );
    h.close();
  });

  testWidgets('the first delayed snapshot preserves a newer local adjustment', (
    tester,
  ) async {
    final initial = Completer<Map<String, dynamic>>();
    final api = _Api()..snapshotGate = initial;
    final h = await _boot(local, api: api, wait: false);
    h.notifier.updateFor(_field, _geometry(width: 620));
    initial.complete({
      'session': {
        'preferences': {
          _prefKey: {_field: _encodedGeometry()},
        },
      },
    });
    await h.container.read(sessionSnapshotProvider.future);
    await tester.pump();
    _expectGeometry(h.value[_field], width: 620);
    expect(h.container.read(sessionProvider).user?.id, _ownerA.userId);
    expect(h.container.read(authenticatedScopeProvider), _ownerA);
    expect(h.container.read(apiBaseUrlProvider), _serverA);
    expect(identical(h.container.read(apiClientProvider), api), isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(api.writePaths, [ApiEndpoints.userPreference(_prefKey)]);
    expect(api.writes, hasLength(1));
    final submitted = api.writes.single as Map<String, Object?>;
    final field = submitted[_field] as Map<String, Object?>;
    expect(field['w'], 620);
    h.close();
  });

  for (final broken in ['{broken', '[1,2,3]', '{"field":{"w":-2}}']) {
    testWidgets('corrupt persisted geometry falls back safely: $broken', (
      tester,
    ) async {
      await local.setString(
        scopedPagePreferenceCacheKey(
          'page_prefs_cache_$_prefKey',
          _serverA,
          _ownerA,
        ),
        broken,
      );
      final h = await _boot(local);
      await tester.pump();
      expect(h.value, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a local cache with the wrong stored type falls back safely', (
    tester,
  ) async {
    await local.setInt(
      scopedPagePreferenceCacheKey(
        'page_prefs_cache_$_prefKey',
        _serverA,
        _ownerA,
      ),
      42,
    );
    final h = await _boot(local);
    await tester.pump();
    expect(h.value, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('decoding accepts JSON maps and rejects nonfinite geometry', (
    tester,
  ) async {
    final h = await _boot(local);
    await tester.pump();
    final data = {_field: _encodedGeometry()};
    _expectGeometry(h.notifier.decode(data)?[_field]);
    _expectGeometry(h.notifier.decode(jsonEncode(data))?[_field]);
    final decoded = h.notifier.decode({
      ...data,
      'nan': {..._encodedGeometry(), 'w': double.nan},
      'infinite': {..._encodedGeometry(), 'y': double.infinity},
      'negative': {..._encodedGeometry(), 'h': -1},
      'wrongType': {..._encodedGeometry(), 'w': '460'},
    });
    expect(decoded?.keys, unorderedEquals([_field]));
  });

  testWidgets('many fields retain the newest geometry within the byte budget', (
    tester,
  ) async {
    final h = await _boot(local);
    await tester.pump();
    for (var index = 0; index < 90; index++) {
      h.notifier.updateFor(
        'page.field-$index',
        _geometry(width: 460.0 + index),
      );
    }
    expect(h.value.length, lessThanOrEqualTo(64));
    expect(h.value.containsKey('page.field-0'), isFalse);
    _expectGeometry(h.value['page.field-89'], width: 549);
    expect(
      utf8.encode(jsonEncode(h.notifier.encode(h.value))).length,
      lessThanOrEqualTo(15 * 1024),
    );

    final multiByteKey = List.filled(80, '笔').join();
    for (var index = 0; index < 90; index++) {
      h.notifier.updateFor('$multiByteKey-$index', _geometry());
    }
    expect(h.value.length, lessThanOrEqualTo(64));
    expect(
      utf8.encode(jsonEncode(h.notifier.encode(h.value))).length,
      lessThanOrEqualTo(15 * 1024),
    );
    h.close();
  });
}
