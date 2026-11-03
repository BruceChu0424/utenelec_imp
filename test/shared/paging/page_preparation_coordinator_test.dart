import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/paging/page_preparation_coordinator.dart';

Future<void> flush() async {
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class Reads {
  final started = <String>[];
  final pending = <String, Completer<void>>{};
  int active = 0;
  int maximum = 0;
  Future<void> Function() job(String name) => () {
    started.add(name);
    active++;
    if (active > maximum) maximum = active;
    final done = pending[name] = Completer<void>();
    return done.future.whenComplete(() => active--);
  };
  void release(String name) => pending[name]!.complete();
  void finish() {
    for (final done in pending.values) {
      if (!done.isCompleted) done.complete();
    }
  }
}

void main() {
  test('a slow transport cannot accumulate retired page waiters', () async {
    final budget = PagePreparationBudget();
    final gates = [Completer<void>(), Completer<void>()];
    for (final gate in gates) {
      unawaited(budget.run(() => gate.future, isCurrent: () => true));
    }
    var current = true;
    var forbiddenDispatches = 0;
    var retiredCompleted = false;
    unawaited(
      budget
          .run(() async {
            forbiddenDispatches++;
          }, isCurrent: () => current)
          .then((dispatched) {
            retiredCompleted = !dispatched;
          }),
    );
    current = false;
    final next = budget.run(() async {}, isCurrent: () => false);
    await flush();
    expect(
      retiredCompleted,
      isTrue,
      reason:
          'Old closure is released while the physical transports are still busy',
    );
    expect(forbiddenDispatches, 0);
    budget.dispose();
    for (final gate in gates) {
      gate.complete();
    }
    expect(await next, isFalse);
  });

  test('hidden budget waiters are retained for same-category resume', () async {
    final reads = Reads();
    final budget = PagePreparationBudget();
    final busy = PagePreparationCoordinator(budget: budget);
    final waiting = PagePreparationCoordinator(budget: budget);
    addTearDown(() {
      busy.dispose();
      waiting.dispose();
      budget.dispose();
      reads.finish();
    });
    var visible = true;
    busy.prepare('busy', [
      reads.job('a'),
      reads.job('b'),
    ], canPrepare: () => true);
    waiting.prepare('waiting', [
      reads.job('later-a'),
      reads.job('later-b'),
    ], canPrepare: () => visible);
    visible = false;
    reads.release('a');
    reads.release('b');
    await flush();
    expect(reads.started, ['a', 'b']);
    visible = true;
    waiting.prepare('waiting', const [], canPrepare: () => visible);
    await flush();
    expect(reads.started.toSet(), {'a', 'b', 'later-a', 'later-b'});
    expect(reads.maximum, 2);
  });

  test(
    'first pages use two physical slots and continue after completion',
    () async {
      final reads = Reads();
      final coordinator = PagePreparationCoordinator();
      addTearDown(() {
        coordinator.dispose();
        reads.finish();
      });
      coordinator.prepare('work', [
        for (final key in ['a', 'b', 'c']) reads.job(key),
      ], canPrepare: () => true);
      expect(reads.started, ['a', 'b']);
      reads.release('a');
      await flush();
      expect(reads.started, ['a', 'b', 'c']);
      expect(reads.maximum, 2);
    },
  );

  test(
    'changing category discards old queued pages and retains running slots',
    () async {
      final reads = Reads();
      final coordinator = PagePreparationCoordinator();
      addTearDown(() {
        coordinator.dispose();
        reads.finish();
      });
      coordinator.prepare('old', [
        for (final key in ['a', 'b', 'never']) reads.job(key),
      ], canPrepare: () => true);
      coordinator.prepare('new', [reads.job('new')], canPrepare: () => true);
      expect(reads.started, ['a', 'b']);
      reads.release('a');
      await flush();
      expect(reads.started, ['a', 'b', 'new']);
      expect(reads.maximum, 2);
    },
  );

  test(
    'different modules share the same physical budget during navigation',
    () async {
      final reads = Reads();
      final budget = PagePreparationBudget();
      final first = PagePreparationCoordinator(budget: budget);
      final second = PagePreparationCoordinator(budget: budget);
      addTearDown(() {
        first.dispose();
        second.dispose();
        budget.dispose();
        reads.finish();
      });
      first.prepare('sales', [
        reads.job('sales-a'),
        reads.job('sales-b'),
      ], canPrepare: () => true);
      second.prepare('warehouse', [
        reads.job('stock-a'),
        reads.job('stock-b'),
      ], canPrepare: () => true);
      first.retire();
      expect(reads.started, ['sales-a', 'sales-b']);
      reads.release('sales-a');
      await flush();
      expect(reads.started, ['sales-a', 'sales-b', 'stock-a']);
      expect(reads.maximum, 2);
      reads.release('sales-b');
      await flush();
      expect(reads.started.last, 'stock-b');
      expect(reads.maximum, 2);
    },
  );

  test('retired jobs waiting in a shared budget never dispatch', () async {
    final reads = Reads();
    final budget = PagePreparationBudget();
    final busy = PagePreparationCoordinator(budget: budget);
    final waiting = PagePreparationCoordinator(budget: budget);
    addTearDown(() {
      busy.dispose();
      waiting.dispose();
      budget.dispose();
      reads.finish();
    });
    busy.prepare('busy', [
      reads.job('a'),
      reads.job('b'),
    ], canPrepare: () => true);
    waiting.prepare('stale', [
      reads.job('never-a'),
      reads.job('never-b'),
    ], canPrepare: () => true);
    waiting.retire();
    waiting.prepare('current', [reads.job('current')], canPrepare: () => true);
    reads.release('a');
    await flush();
    expect(reads.started, ['a', 'b', 'current']);
  });

  test(
    'hidden work resumes in the same category without losing its queue',
    () async {
      final reads = Reads();
      final coordinator = PagePreparationCoordinator();
      addTearDown(() {
        coordinator.dispose();
        reads.finish();
      });
      coordinator.prepare('work', [reads.job('a')], canPrepare: () => false);
      expect(reads.started, isEmpty);
      coordinator.prepare('work', const [], canPrepare: () => true);
      expect(reads.started, ['a']);
    },
  );

  test(
    'speculative errors release slots and never become uncaught errors',
    () async {
      final reads = Reads();
      final coordinator = PagePreparationCoordinator(maximumConcurrent: 1);
      addTearDown(() {
        coordinator.dispose();
        reads.finish();
      });
      coordinator.prepare('work', [
        () async => throw StateError('offline'),
        reads.job('next'),
      ], canPrepare: () => true);
      await flush();
      expect(reads.started, ['next']);
    },
  );

  test('a completed expired batch is prepared again on reentry', () async {
    final coordinator = PagePreparationCoordinator(freshFor: Duration.zero);
    addTearDown(coordinator.dispose);
    var requests = 0;
    Future<void> read() async {
      requests++;
    }

    coordinator.prepare('work', [read], canPrepare: () => true);
    await flush();
    coordinator.prepare('work', [read], canPrepare: () => true);
    await flush();
    expect(requests, 2);
  });

  test(
    'disposal retires waiting work without reusing released transports',
    () async {
      final reads = Reads();
      final coordinator = PagePreparationCoordinator();
      coordinator.prepare('work', [
        for (final key in ['a', 'b', 'never']) reads.job(key),
      ], canPrepare: () => true);
      coordinator.dispose();
      reads.finish();
      await flush();
      coordinator.prepare('other', [
        reads.job('also-never'),
      ], canPrepare: () => true);
      expect(reads.started, ['a', 'b']);
    },
  );
}
