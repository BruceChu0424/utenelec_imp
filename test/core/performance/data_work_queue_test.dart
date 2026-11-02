import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/performance/data_work_queue.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';

void main() {
  test(
    'retired queued data is released while both active operations remain blocked',
    () async {
      final queue = DataWorkQueue();
      final gates = [Completer<void>(), Completer<void>()];
      final active = [
        queue.run(() => gates[0].future),
        queue.run(() => gates[1].future),
      ];
      await Future<void>.delayed(Duration.zero);
      var current = true, executed = false;
      final stale = queue.run<void>(() async {
        executed = true;
      }, isCurrent: () => current);
      final outcome = expectLater(stale, throwsA(isA<UiWorkCancelled>()));
      current = false;
      await outcome.timeout(const Duration(seconds: 1));
      expect(executed, isFalse);
      expect(queue.active, 2);
      expect(queue.pending, 0);
      for (final gate in gates) {
        gate.complete();
      }
      await Future.wait(active);
    },
  );
  test('all valid jobs are FIFO and at most two execute at once', () async {
    final queue = DataWorkQueue();
    final gates = List.generate(12, (_) => Completer<void>());
    final order = <int>[];
    var peak = 0;
    final work = List.generate(
      12,
      (i) => queue.run(() async {
        order.add(i);
        if (queue.active > peak) peak = queue.active;
        await gates[i].future;
        return i;
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(order, [0, 1]);
    expect(queue.pending, 10);
    for (var i = 0; i < 12; i++) {
      gates[i].complete();
      await Future<void>.delayed(Duration.zero);
    }
    expect(await Future.wait(work), List.generate(12, (i) => i));
    expect(order, List.generate(12, (i) => i));
    expect(peak, lessThanOrEqualTo(2));
  });
  test(
    'ten thousand retired reads yield to input and never execute their payloads',
    () async {
      final queue = DataWorkQueue();
      var current = true, executed = 0, pulses = 0;
      final work = List.generate(
        10000,
        (_) => queue
            .run(() async {
              executed++;
              return 1;
            }, isCurrent: () => current)
            .then<int>(
              (value) => value,
              onError: (Object error) {
                expect(error, isA<UiWorkCancelled>());
                return -1;
              },
            ),
      );
      current = false;
      final timer = Timer.periodic(Duration.zero, (_) => pulses++);
      addTearDown(timer.cancel);
      expect(await Future.wait(work), everyElement(-1));
      expect(executed, 0);
      expect(pulses, greaterThan(0));
      expect(queue.pending, 0);
    },
  );
  test('errors propagate unchanged and no work is replayed', () async {
    final queue = DataWorkQueue();
    final failure = StateError('fixture');
    var attempts = 0;
    await expectLater(
      queue.run<void>(() async {
        attempts++;
        throw failure;
      }),
      throwsA(same(failure)),
    );
    expect(attempts, 1);
  });
}
