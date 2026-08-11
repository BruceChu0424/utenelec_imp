import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/security/pending_refresh_revocation_store.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/auth/services/pending_refresh_revocation_drainer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('successful logout response removes the exact queued token', () async {
    final queue = _queue();
    await queue.enqueue('pending-token');
    final revoked = <String>[];
    final drainer = PendingRefreshRevocationDrainer(
      store: queue,
      revoke: (token) async => revoked.add(token),
      retryDelays: const <Duration>[Duration(hours: 1)],
    );
    addTearDown(drainer.dispose);

    await drainer.drain();

    expect(revoked, <String>['pending-token']);
    expect(await queue.pendingTokens(), isEmpty);
  });

  test(
    'failed response stays queued until a later successful response',
    () async {
      final queue = _queue();
      await queue.enqueue('pending-token');
      var fail = true;
      var calls = 0;
      final drainer = PendingRefreshRevocationDrainer(
        store: queue,
        revoke: (token) async {
          calls++;
          if (fail) throw StateError('offline');
        },
        retryDelays: const <Duration>[Duration(hours: 1)],
      );
      addTearDown(drainer.dispose);

      await drainer.drain();
      expect(calls, 1);
      expect(await queue.pendingTokens(), <String>['pending-token']);
      expect(drainer.hasScheduledRetry, isTrue);

      fail = false;
      await drainer.drain();
      expect(calls, 2);
      expect(await queue.pendingTokens(), isEmpty);
      expect(drainer.hasScheduledRetry, isFalse);
    },
  );

  test('concurrent drain wakeups remain single-flight', () async {
    final queue = _queue();
    await queue.enqueue('pending-token');
    final started = Completer<void>();
    final release = Completer<void>();
    var calls = 0;
    var active = 0;
    var maxActive = 0;
    final drainer = PendingRefreshRevocationDrainer(
      store: queue,
      revoke: (token) async {
        calls++;
        active++;
        if (active > maxActive) maxActive = active;
        if (!started.isCompleted) started.complete();
        await release.future;
        active--;
        throw StateError('still offline');
      },
      retryDelays: const <Duration>[Duration(hours: 1)],
    );
    addTearDown(drainer.dispose);

    final first = drainer.drain();
    final second = drainer.drain();
    final third = drainer.drain();
    await started.future;

    expect(calls, 1);
    expect(maxActive, 1);
    release.complete();
    await Future.wait(<Future<void>>[first, second, third]);

    expect(calls, 1);
    expect(maxActive, 1);
    expect(await queue.pendingTokens(), <String>['pending-token']);
    expect(drainer.hasScheduledRetry, isTrue);
  });

  test('enqueue waits for encrypted persistence but not the network', () async {
    final queue = _queue();
    final started = Completer<void>();
    final release = Completer<void>();
    final drainer = PendingRefreshRevocationDrainer(
      store: queue,
      revoke: (token) async {
        started.complete();
        await release.future;
      },
      retryDelays: const <Duration>[Duration(hours: 1)],
    );
    addTearDown(drainer.dispose);

    expect(await drainer.enqueueAndDrain('pending-token'), isTrue);
    await started.future;

    expect(drainer.isDraining, isTrue);
    expect(await queue.pendingTokens(), <String>['pending-token']);
    release.complete();
    await pumpEventQueue();
    expect(await queue.pendingTokens(), isEmpty);
  });

  test('bounded retry timers never overlap network attempts', () async {
    final queue = _queue();
    await queue.enqueue('pending-token');
    var calls = 0;
    var active = 0;
    var maxActive = 0;
    final completed = Completer<void>();
    final drainer = PendingRefreshRevocationDrainer(
      store: queue,
      revoke: (token) async {
        calls++;
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(Duration.zero);
        active--;
        if (calls < 4) throw StateError('transient');
        completed.complete();
      },
      retryDelays: const <Duration>[
        Duration(milliseconds: 1),
        Duration(milliseconds: 2),
      ],
    );
    addTearDown(drainer.dispose);

    await drainer.drain();
    await completed.future.timeout(const Duration(seconds: 1));
    await pumpEventQueue();

    expect(calls, 4);
    expect(maxActive, 1);
    expect(await queue.pendingTokens(), isEmpty);
  });
}

PendingRefreshRevocationStore _queue() =>
    PendingRefreshRevocationStore(SecureStorage(const FlutterSecureStorage()));
