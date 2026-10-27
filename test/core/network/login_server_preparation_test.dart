import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/login_server_preparation.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _cacheKey = 'uten.local_server_reachable';
const _cloud = 'https://cloud.example.test/api';

class _DelayedPreferences extends InMemorySharedPreferences {
  Completer<void>? writeGate;

  @override
  Future<bool> setBool(String key, bool value) async {
    await writeGate?.future;
    return super.setBool(key, value);
  }
}

void main() {
  test(
    'concurrent probes await one transport and completed cache/state writes',
    () async {
      final preferences = _DelayedPreferences();
      await preferences.setBool(_cacheKey, false);
      final health = Completer<bool>();
      var calls = 0;
      final notifier = LocalServerReachabilityNotifier(
        preferences,
        web: false,
        healthProbe: () {
          calls++;
          return health.future;
        },
      );
      addTearDown(notifier.dispose);
      preferences.writeGate = Completer<void>();
      final first = notifier.probe();
      final second = notifier.probe();
      expect(identical(first, second), isTrue);
      var completed = false;
      unawaited(second.then((_) => completed = true));
      health.complete(true);
      await pumpEventQueue(times: 3);
      expect(calls, 1);
      expect(completed, isFalse);
      expect(notifier.state, isFalse);
      expect(preferences.getBool(_cacheKey), isFalse);
      preferences.writeGate!.complete();
      await Future.wait([first, second]);
      expect(notifier.state, isTrue);
      expect(preferences.getBool(_cacheKey), isTrue);
    },
  );

  test(
    'disposing during a probe does not publish or persist its late result',
    () async {
      final preferences = InMemorySharedPreferences();
      await preferences.setBool(_cacheKey, false);
      final health = Completer<bool>();
      final notifier = LocalServerReachabilityNotifier(
        preferences,
        web: false,
        healthProbe: () => health.future,
      );
      final probe = notifier.probe();
      notifier.dispose();
      health.complete(true);
      await probe;
      expect(preferences.getBool(_cacheKey), isFalse);
    },
  );

  for (final reachable in [true, false]) {
    test(
      'fresh native automatic preparation selects ${reachable ? 'local' : 'cloud'}',
      () async {
        final preferences = InMemorySharedPreferences();
        await preferences.setBool(_cacheKey, !reachable);
        await preferences.setString('uten.server_url_override', _cloud);
        var calls = 0;
        final container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            localServerReachableProvider.overrideWith(
              (ref) => LocalServerReachabilityNotifier(
                preferences,
                web: false,
                healthProbe: () async {
                  calls++;
                  return reachable;
                },
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        expect(
          container.read(apiBaseUrlProvider),
          reachable ? _cloud : localApiBaseUrl,
        );
        await container.read(loginServerPreparationProvider)();
        expect(
          container.read(apiBaseUrlProvider),
          reachable ? localApiBaseUrl : _cloud,
        );
        expect(calls, 1);
        expect(readServerMode(preferences), ServerMode.auto);
        expect(preferences.getString('uten.server_url_override'), _cloud);
      },
    );
  }

  for (final mode in [ServerMode.local, ServerMode.cloud]) {
    test(
      'explicit $mode diagnostics are preserved without a fresh probe',
      () async {
        final preferences = InMemorySharedPreferences();
        await writeServerMode(preferences, mode);
        var probeOwners = 0;
        final container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            localServerReachableProvider.overrideWith((ref) {
              probeOwners++;
              return LocalServerReachabilityNotifier(preferences, web: true);
            }),
          ],
        );
        addTearDown(container.dispose);
        await container.read(loginServerPreparationProvider)();
        expect(probeOwners, 0);
        expect(readServerMode(preferences), mode);
      },
    );
  }

  test('Web retains its same-origin routing without a local probe', () async {
    var calls = 0;
    await prepareLoginServerSelection(
      mode: ServerMode.auto,
      web: true,
      probe: () async => calls++,
    );
    expect(calls, 0);
  });

  test('configuration changes while probing retire the preparation', () async {
    final preferences = InMemorySharedPreferences();
    final health = Completer<bool>();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        localServerReachableProvider.overrideWith(
          (ref) => LocalServerReachabilityNotifier(
            preferences,
            web: false,
            healthProbe: () => health.future,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final preparing = container.read(loginServerPreparationProvider)();
    await writeServerMode(preferences, ServerMode.cloud);
    health.complete(true);
    await expectLater(
      preparing,
      throwsA(isA<LoginServerPreparationCancelled>()),
    );
  });

  test(
    'disposing the provider while probing retires the preparation',
    () async {
      final preferences = InMemorySharedPreferences();
      final health = Completer<bool>();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          localServerReachableProvider.overrideWith(
            (ref) => LocalServerReachabilityNotifier(
              preferences,
              web: false,
              healthProbe: () => health.future,
            ),
          ),
        ],
      );
      final preparing = container.read(loginServerPreparationProvider)();
      container.dispose();
      health.complete(true);
      await expectLater(
        preparing,
        throwsA(isA<LoginServerPreparationCancelled>()),
      );
    },
  );
}
