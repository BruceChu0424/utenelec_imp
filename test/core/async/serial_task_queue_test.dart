import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/async/serial_task_queue.dart';
import 'package:uten_imp/core/security/auth_refresh_lock.dart';

void main() {
  test(
    'queued tasks keep arrival order when the first task is blocked',
    () async {
      final queue = SerialTaskQueue();
      final entered = Completer<void>();
      final release = Completer<void>();
      final events = <String>[];
      final first = queue.run(() async {
        events.add('first started');
        entered.complete();
        await release.future;
        events.add('first finished');
        return 1;
      });
      await entered.future;
      final second = queue.run(() async {
        events.add('second');
        return 2;
      });
      final third = queue.run(() async {
        events.add('third');
        return 3;
      });
      await pumpEventQueue();
      expect(events, ['first started']);
      release.complete();
      expect(await Future.wait([first, second, third]), [1, 2, 3]);
      expect(events, ['first started', 'first finished', 'second', 'third']);
    },
  );

  test(
    'a failed task releases queued callers without hiding its error',
    () async {
      final queue = SerialTaskQueue();
      final release = Completer<void>();
      final failure = StateError('task failed');
      final first = queue.run<void>(() async {
        await release.future;
        throw failure;
      });
      final rejected = expectLater(first, throwsA(same(failure)));
      final next = queue.run(() async => 'next result');
      release.complete();
      await rejected;
      expect(await next, 'next result');
      expect(await queue.run(() async => 'later result'), 'later result');
    },
  );

  test('one authentication scope does not block another scope', () async {
    final firstLock = AuthRefreshLock('queue-regression-scope-one');
    final secondLock = AuthRefreshLock('queue-regression-scope-two');
    final entered = Completer<void>();
    final release = Completer<void>();
    final first = firstLock.synchronized(() async {
      entered.complete();
      await release.future;
      return 'first';
    });
    await entered.future;
    expect(await secondLock.synchronized(() async => 'second'), 'second');
    release.complete();
    expect(await first, 'first');
    expect(
      identical(firstLock, AuthRefreshLock('queue-regression-scope-one')),
      isTrue,
    );
  });
}
