import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/async/bounded_read_map.dart';

void main() {
  test(
    'limits in-flight reads, refills free slots and preserves source order',
    () async {
      final completions = List.generate(7, (_) => Completer<int>());
      final started = <int>[];
      var active = 0;
      var peak = 0;
      final result = boundedReadMap(List.generate(7, (index) => index), (
        index,
      ) async {
        started.add(index);
        active++;
        if (active > peak) peak = active;
        final value = await completions[index].future;
        active--;
        return value;
      }, maxConcurrent: 3);
      expect(started, [0, 1, 2]);
      completions[1].complete(11);
      await Future<void>.delayed(Duration.zero);
      expect(started, [0, 1, 2, 3]);
      completions[3].complete(13);
      await Future<void>.delayed(Duration.zero);
      expect(started, [0, 1, 2, 3, 4]);
      for (final index in [0, 2, 4, 5, 6]) {
        completions[index].complete(10 + index);
      }
      expect(await result, [10, 11, 12, 13, 14, 15, 16]);
      expect(peak, 3);
    },
  );

  test(
    'a superseded batch stops claiming work and never returns partial data',
    () async {
      final pending = [Completer<int>(), Completer<int>()];
      final started = <int>[];
      var current = true;
      final result = boundedReadMap(
        [0, 1, 2, 3],
        (index) {
          started.add(index);
          return pending[index].future;
        },
        maxConcurrent: 2,
        isCurrent: () => current,
      );
      final expectation = expectLater(
        result,
        throwsA(isA<BoundedReadSuperseded>()),
      );
      current = false;
      pending[1].complete(1);
      await expectation;
      pending[0].completeError(StateError('late read also failed'));
      await Future<void>.delayed(Duration.zero);
      expect(started, [0, 1]);
    },
  );

  test(
    'first failure stops new reads and observes later failures without retry',
    () async {
      final pending = [Completer<int>(), Completer<int>()];
      final started = <int>[];
      final failure = StateError('read failed');
      final result = boundedReadMap([0, 1, 2, 3], (index) {
        started.add(index);
        return pending[index].future;
      }, maxConcurrent: 2);
      final expectation = expectLater(result, throwsA(same(failure)));
      pending[0].completeError(failure);
      await expectation;
      pending[1].completeError(StateError('late failure'));
      await Future<void>.delayed(Duration.zero);
      expect(started, [0, 1]);
    },
  );

  test('snapshots inputs and retains legitimate null results', () async {
    final input = [0, 1, 2];
    final first = Completer<int?>();
    final result = boundedReadMap<int, int?>(input, (index) async {
      return index == 0 ? await first.future : index;
    }, maxConcurrent: 1);
    input.clear();
    first.complete(null);
    expect(await result, [null, 1, 2]);
  });

  test(
    'does not start reads when already stale and validates the bound',
    () async {
      var calls = 0;
      Future<int> read(int value) async {
        calls++;
        return value;
      }

      await expectLater(
        boundedReadMap([1], read, isCurrent: () => false),
        throwsA(isA<BoundedReadSuperseded>()),
      );
      await expectLater(
        boundedReadMap([1], read, maxConcurrent: 0),
        throwsArgumentError,
      );
      expect(await boundedReadMap<int, int>([], read), isEmpty);
      expect(calls, 0);
    },
  );
}
