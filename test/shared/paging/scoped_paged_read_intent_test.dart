import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';

void main() {
  test(
    'nested asynchronous reads require both the parent owner and current query',
    () async {
      var owner = true, query = true;
      expect(PagedReadIntent.currentRead, isNull);
      await PagedReadIntent.scopedRead(() => owner, () async {
        final parent = PagedReadIntent.currentRead!;
        await Future<void>.delayed(Duration.zero);
        expect(parent(), isTrue);
        await PagedReadIntent.scopedRead(() => query, () async {
          final current = PagedReadIntent.currentRead!;
          await Future<void>.delayed(Duration.zero);
          expect(current(), isTrue);
          query = false;
          expect(current(), isFalse);
          expect(parent(), isTrue);
          query = true;
          owner = false;
          expect(current(), isFalse);
        });
        expect(identical(PagedReadIntent.currentRead, parent), isTrue);
      });
      expect(PagedReadIntent.currentRead, isNull);
    },
  );
  test(
    'retiring one concurrent query cannot cancel an unrelated reader owner',
    () async {
      var ownerA = true;
      final gate = Completer<void>();
      late bool Function() a, b;
      final first = PagedReadIntent.scopedRead(() => ownerA, () async {
        a = PagedReadIntent.currentRead!;
        await gate.future;
        expect(a(), isFalse);
      });
      final second = PagedReadIntent.scopedRead(() => true, () async {
        b = PagedReadIntent.currentRead!;
        await gate.future;
        expect(b(), isTrue);
      });
      ownerA = false;
      gate.complete();
      await Future.wait([first, second]);
      expect(PagedReadIntent.currentRead, isNull);
    },
  );
  test(
    'a failed read releases its cancellation intent before unrelated work',
    () async {
      final error = StateError('read failed');
      await expectLater(
        PagedReadIntent.scopedRead(() => false, () async {
          await Future<void>.delayed(Duration.zero);
          throw error;
        }),
        throwsA(same(error)),
      );
      expect(PagedReadIntent.currentRead, isNull);
      final value = await Future.value('unrelated operation');
      expect(value, 'unrelated operation');
    },
  );
}
