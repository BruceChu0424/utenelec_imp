import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/uten_page_prefs_notifier.dart';

final _scope = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'a'),
);
final _server = StateProvider<String>((_) => 'https://a.invalid/api');
final _permissions = StateProvider<Set<String>>((_) => {Perm.stockView});
final _api = StateProvider<_Api>((_) => _Api());
final _prefs = NotifierProvider<_Prefs, bool>(_Prefs.new);
final _closed = Expando<bool>();
void _dispose(ProviderContainer container) {
  if (_closed[container] == true) return;
  _closed[container] = true;
  container.dispose();
}

class _Prefs extends UtenPagePrefsNotifier<bool> {
  @override
  String get prefKey => 'read.scope';
  @override
  bool get defaultValue => false;
  @override
  bool? decode(Object? value) => value is bool ? value : null;
  @override
  Object? encode(bool value) => value;
  @override
  Duration get saveDebounce => const Duration(milliseconds: 20);
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'a', code: 'a', name: 'A'),
  );
}

Map<String, dynamic> _badges(int count) => {
  'entries': {
    'purchaseTaskCenter': {'todo': count, 'inProgress': 0},
  },
  'modules': {
    'purchase': {'todo': count, 'inProgress': 0},
  },
  'total': {'todo': count, 'inProgress': 0},
};

class _Api extends ApiClient {
  _Api() : super(Dio());
  int snapshots = 0;
  final puts = <Object?>[];
  Completer<Map<String, dynamic>>? snapshotGate;
  Completer<void>? putGate;
  final badgeGates = Queue<Completer<Map<String, dynamic>>>();
  Map<String, Object?> preferences = {};
  Set<String> delegable = {};
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.workbenchBadges) {
      return badgeGates.isEmpty ? _badges(5) : badgeGates.removeFirst().future;
    }
    if (path == ApiEndpoints.authMe) {
      snapshots++;
      if (snapshotGate != null) return snapshotGate!.future;
      return {
        'session': {
          'preferences': preferences,
          'delegableSurfaceKeys': delegable.toList(),
        },
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    puts.add(body);
    await putGate?.future;
    return {};
  }
}

class _Snapshots extends SessionSnapshotNotifier {
  void emit(AsyncValue<SessionSnapshot?> value) => state = value;
}

Future<ProviderContainer> _boot({_Api? api, bool wait = true}) async {
  SharedPreferences.setMockInitialValues({
    'page_prefs_cache_read.scope': 'true',
  });
  final local = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(local),
      sessionProvider.overrideWith(_Session.new),
      sessionSnapshotProvider.overrideWith(_Snapshots.new),
      if (api != null) _api.overrideWith((ref) => api),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      apiClientProvider.overrideWith((ref) => ref.watch(_api)),
    ],
  );
  container.listen(_prefs, (_, _) {});
  if (wait) await container.read(sessionSnapshotProvider.future);
  await Future<void>.value();
  return container;
}

void main() {
  testWidgets(
    'preference updates never confirm retained authorization during loading or error and keep retry alive',
    (tester) async {
      final c = await _boot();
      addTearDown(() => _dispose(c));
      final api = c.read(_api)..delegable = {'department.manage'};
      final notifier = c.read(sessionSnapshotProvider.notifier) as _Snapshots;
      await notifier.refresh();
      final privileged = c.read(sessionSnapshotProvider).value!;
      expect(
        confirmedSessionSnapshot(
          c.read(sessionSnapshotProvider),
        )!.canDelegate('department.manage'),
        isTrue,
      );
      final gate = Completer<Map<String, dynamic>>();
      api.snapshotGate = gate;
      final pending = notifier.refresh();
      notifier.updatePreference('read.scope', true);
      expect(c.read(sessionSnapshotProvider).isLoading, isTrue);
      expect(confirmedSessionSnapshot(c.read(sessionSnapshotProvider)), isNull);
      gate.completeError(StateError('permission refresh unavailable'));
      await pending;
      notifier.emit(
        AsyncError<SessionSnapshot?>(
          StateError('permission refresh unavailable'),
          StackTrace.current,
        ).copyWithPrevious(AsyncData(privileged)),
      );
      notifier.updatePreference('read.scope', false);
      expect(c.read(sessionSnapshotProvider).hasError, isTrue);
      expect(confirmedSessionSnapshot(c.read(sessionSnapshotProvider)), isNull);
      api.snapshotGate = null;
      api.delegable = {};
      final beforeRetry = api.snapshots;
      await tester.pump(const Duration(seconds: 5));
      await c.read(sessionSnapshotProvider.future);
      expect(api.snapshots, beforeRetry + 1);
      expect(
        confirmedSessionSnapshot(
          c.read(sessionSnapshotProvider),
        )!.canDelegate('department.manage'),
        isFalse,
      );
      _dispose(c);
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
  for (final oldFails in [false, true]) {
    testWidgets(
      'manual refresh supersedes initial build ${oldFails ? 'failure' : 'success'} without stale authorization',
      (tester) async {
        final first = Completer<Map<String, dynamic>>();
        final api = _Api()..snapshotGate = first;
        final c = await _boot(api: api, wait: false);
        addTearDown(() => _dispose(c));
        final originalFuture = c.read(sessionSnapshotProvider.future);
        api.snapshotGate = null;
        api.preferences = {'version': 'manual-current'};
        api.delegable = {};
        await c.read(sessionSnapshotProvider.notifier).refresh();
        expect(
          c.read(sessionSnapshotProvider).value!.preferences['version'],
          'manual-current',
        );
        if (oldFails) {
          first.completeError(StateError('initial read failed late'));
        } else {
          first.complete({
            'session': {
              'preferences': {'version': 'initial-old'},
              'delegableSurfaceKeys': ['department.manage'],
            },
          });
        }
        await originalFuture;
        await tester.pump(const Duration(seconds: 60));
        expect(c.read(sessionSnapshotProvider).hasError, isFalse);
        expect(
          c.read(sessionSnapshotProvider).value!.preferences['version'],
          'manual-current',
        );
        expect(
          confirmedSessionSnapshot(
            c.read(sessionSnapshotProvider),
          )!.canDelegate('department.manage'),
          isFalse,
        );
        expect(
          api.snapshots,
          2,
          reason: 'the obsolete initial error never schedules another GET',
        );
        _dispose(c);
        await tester.pump(const Duration(milliseconds: 1));
      },
    );
  }
  test(
    'recent me snapshots require the exact client and non-credential session lineage',
    () {
      final a = _Api(), b = _Api();
      const tokens = AuthTokenSnapshot(
        accessToken: null,
        refreshToken: null,
        generation: 2,
        intentGeneration: 1,
        sessionLineage: 'lineage-a',
      );
      const later = AuthTokenSnapshot(
        accessToken: null,
        refreshToken: null,
        generation: 3,
        intentGeneration: 2,
        sessionLineage: 'lineage-a-returned',
      );
      RecentMeSnapshot.remember(
        'a',
        {'preferences': <String, Object?>{}},
        a,
        tokens,
      );
      expect(RecentMeSnapshot.take('a', b, tokens), isNull);
      RecentMeSnapshot.remember(
        'a',
        {'preferences': <String, Object?>{}},
        a,
        tokens,
      );
      expect(RecentMeSnapshot.take('a', a, later), isNull);
      RecentMeSnapshot.remember(
        'a',
        {'preferences': <String, Object?>{}},
        a,
        tokens,
      );
      expect(RecentMeSnapshot.take('a', a, tokens), isNotNull);
      expect(RecentMeSnapshot.take('a', a, tokens), isNull);
    },
  );

  testWidgets('late snapshot refresh is fenced after A to B to A', (
    tester,
  ) async {
    final c = await _boot();
    addTearDown(() => _dispose(c));
    final original = c.read(_api);
    final stale = Completer<Map<String, dynamic>>();
    original.snapshotGate = stale;
    final pending = c.read(sessionSnapshotProvider.notifier).refresh();
    c.read(_api.notifier).state = _Api()..preferences = {'read.scope': false};
    await tester.pump(const Duration(milliseconds: 1));
    await c.read(sessionSnapshotProvider.future);
    original.snapshotGate = null;
    original.preferences = {'read.scope': false};
    c.read(_api.notifier).state = original;
    await tester.pump(const Duration(milliseconds: 1));
    await c.read(sessionSnapshotProvider.future);
    stale.complete({
      'session': {
        'preferences': {'read.scope': true},
      },
    });
    await pending;
    expect(
      c.read(sessionSnapshotProvider).value!.preferences['read.scope'],
      isFalse,
    );
    _dispose(c);
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'an old refresh failure does not replace or schedule retries for the new server',
    (tester) async {
      final c = await _boot();
      addTearDown(() => _dispose(c));
      final original = c.read(_api);
      final stale = Completer<Map<String, dynamic>>();
      original.snapshotGate = stale;
      final pending = c.read(sessionSnapshotProvider.notifier).refresh();
      final replacement = _Api()..preferences = {'read.scope': false};
      c.read(_api.notifier).state = replacement;
      await tester.pump(const Duration(milliseconds: 1));
      await c.read(sessionSnapshotProvider.future);
      stale.completeError(StateError('old server unavailable'));
      await pending;
      await tester.pump(const Duration(seconds: 60));
      expect(c.read(sessionSnapshotProvider).hasError, isFalse);
      expect(replacement.snapshots, 1);
      expect(
        c.read(sessionSnapshotProvider).value!.preferences['read.scope'],
        isFalse,
      );
      _dispose(c);
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('preference caches isolate server, account and actor', (
    tester,
  ) async {
    final c = await _boot();
    addTearDown(() => _dispose(c));
    await tester.pump();
    expect(
      c.read(_prefs),
      isFalse,
      reason: 'unowned legacy cache is not input',
    );
    c.read(_prefs.notifier).update(true);
    c.read(_scope.notifier).state = const AuthenticatedScope(userId: 'b');
    await tester.pump();
    expect(c.read(_prefs), isFalse);
    c.read(_scope.notifier).state = const AuthenticatedScope(userId: 'a');
    await tester.pump();
    expect(c.read(_prefs), isTrue);
    c.read(_scope.notifier).state = const AuthenticatedScope(
      userId: 'a',
      actorId: 'operator',
    );
    await tester.pump();
    expect(c.read(_prefs), isFalse);
    c.read(_scope.notifier).state = const AuthenticatedScope(userId: 'a');
    c.read(_server.notifier).state = 'https://b.invalid/api';
    await tester.pump();
    expect(c.read(_prefs), isFalse);
    _dispose(c);
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'queued preferences are cancelled before the next identity snapshot',
    (tester) async {
      final c = await _boot();
      addTearDown(() => _dispose(c));
      await tester.pump();
      final api = c.read(_api);
      api.snapshotGate = Completer<Map<String, dynamic>>();
      c.read(_prefs.notifier).update(true);
      c.read(_scope.notifier).state = const AuthenticatedScope(userId: 'b');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.puts, isEmpty);
      expect(c.read(_prefs), isFalse);
      api.snapshotGate!.complete({
        'session': {'preferences': <String, Object?>{}},
      });
      await tester.pump();
      _dispose(c);
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets(
    'old preference completion cannot change the new server snapshot',
    (tester) async {
      final c = await _boot();
      addTearDown(() => _dispose(c));
      await tester.pump();
      final original = c.read(_api)..putGate = Completer<void>();
      c.read(_prefs.notifier).update(true);
      await tester.pump(const Duration(milliseconds: 21));
      expect(original.puts, [true]);
      final replacement = _Api()..preferences = {'read.scope': false};
      c.read(_api.notifier).state = replacement;
      c.read(_server.notifier).state = 'https://b.invalid/api';
      await tester.pump();
      await c.read(sessionSnapshotProvider.future);
      original.putGate!.complete();
      await tester.pump();
      expect(c.read(_prefs), isFalse);
      expect(
        c.read(sessionSnapshotProvider).value!.preferences['read.scope'],
        isFalse,
      );
      expect(replacement.puts, isEmpty);
      expect(replacement.snapshots, 1);
      _dispose(c);
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets(
    'revocation clears badges immediately and ignores the old response',
    (tester) async {
      final c = await _boot();
      addTearDown(() => _dispose(c));
      c.listen(badgeSummaryProvider, (_, _) {});
      await tester.pump();
      expect(c.read(badgeTotalTodoProvider), 5);
      final oldResponse = Completer<Map<String, dynamic>>();
      final newResponse = Completer<Map<String, dynamic>>();
      c.read(_api).badgeGates.addAll([oldResponse, newResponse]);
      final oldRefresh = c.read(badgeSummaryProvider.notifier).refresh();
      await tester.pump();
      c.read(_permissions.notifier).state = {};
      await tester.pump();
      expect(c.read(badgeTotalTodoProvider), 0);
      oldResponse.complete(_badges(99));
      await oldRefresh;
      await tester.pump();
      expect(c.read(badgeTotalTodoProvider), 0);
      newResponse.complete(_badges(0));
      await tester.pump();
      expect(c.read(badgeTotalTodoProvider), 0);
      _dispose(c);
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}
