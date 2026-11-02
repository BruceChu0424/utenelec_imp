import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/paging/scoped_category_read.dart';

void main() {
  test(
    'exact warehouse, source and keyword scopes share pending reads only with themselves',
    () async {
      final reader = ScopedCategoryRead();
      addTearDown(reader.dispose);
      final gate = Completer<Map<String, int>>();
      var reads = 0;
      Future<Map<String, int>> fetch() {
        reads++;
        return gate.future;
      }

      final a = reader.read(
        query: [
          'TASK',
          'a',
          {'keyword': 'x'},
        ],
        fetch: fetch,
      );
      final same = reader.read(
        query: [
          'TASK',
          'a',
          {'keyword': 'x'},
        ],
        fetch: fetch,
      );
      final b = reader.read(
        query: [
          'TASK',
          'b',
          {'keyword': 'x'},
        ],
        fetch: () async => {'OPEN': 2},
      );
      expect(identical(a, same), isTrue);
      expect(reads, 1);
      gate.complete({'OPEN': 7});
      expect(await a, {'OPEN': 7});
      expect(await b, {'OPEN': 2});
      expect(
        await reader.read(
          query: [
            'TASK',
            'a',
            {'keyword': 'x'},
          ],
          fetch: fetch,
        ),
        {'OPEN': 7},
      );
      expect(reads, 1);
      expect(
        await reader.read(
          query: [
            'TASK',
            'a',
            {'keyword': 'x'},
          ],
          force: true,
          fetch: () async => {'OPEN': 8},
        ),
        {'OPEN': 8},
      );
    },
  );
  test(
    'retired readers reject late responses and failed reads can retry',
    () async {
      final reader = ScopedCategoryRead();
      await expectLater(
        reader.read<int>(
          query: 'a',
          fetch: () async => throw StateError('offline'),
        ),
        throwsStateError,
      );
      expect(await reader.read(query: 'a', fetch: () async => 2), 2);
      final gate = Completer<int>();
      final old = reader.read(query: 'b', fetch: () => gate.future);
      final rejected = expectLater(old, throwsStateError);
      reader.dispose();
      gate.complete(3);
      await rejected;
    },
  );
}
