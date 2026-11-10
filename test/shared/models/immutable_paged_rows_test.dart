import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/immutable_paged_rows.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  test(
    'moving immutable suffix preserves only the sealed data common prefix',
    () {
      final builder = ImmutablePagedRowsBuilder<int>()
        ..add(1)
        ..add(2);
      final prefix = builder.snapshot();
      final tail = [90, 91];
      final first = immutablePagedRowsWithTail(prefix, tail);
      tail[0] = 99;
      builder.add(3);
      final grown = builder.snapshot();
      final second = immutablePagedRowsWithTail(grown, [90]);
      expect(first, [1, 2, 90, 91]);
      expect(second, [1, 2, 3, 90]);
      expect(immutablePagedRowsCommonPrefix(first, second), 2);
      expect(immutablePagedRowsCommonPrefix(second, grown), 3);
      expect(pagedRowsAppendStart(first, second), isNull);
      expect(second.getRange(1, 4), [2, 3, 90]);
      expect(second.map((row) => row + 1), [2, 3, 4, 91]);
      expect(() => first.add(99), throwsUnsupportedError);
      expect(
        () => immutablePagedRowsWithTail([1, 2], [90]),
        throwsArgumentError,
      );
      final other = ImmutablePagedRowsBuilder<int>()
        ..add(1)
        ..add(2);
      expect(immutablePagedRowsCommonPrefix(first, other.snapshot()), isNull);
      expect(immutablePagedRowsCommonPrefix(first, [1, 2, 90, 91]), isNull);
    },
  );
  test(
    'snapshots retain only sealed membership and prove transitive append',
    () {
      final builder = ImmutablePagedRowsBuilder<int>();
      builder.add(1);
      builder.add(2);
      final first = builder.snapshot();
      builder.add(3);
      final middle = builder.snapshot();
      builder.add(4);
      builder.add(5);
      final last = builder.snapshot();
      builder.add(6); // An unvalidated future batch is never visible.

      expect(first, [1, 2]);
      expect(middle, [1, 2, 3]);
      expect(last, [1, 2, 3, 4, 5]);
      expect(last.sublist(1, 4), [2, 3, 4]);
      expect(last.getRange(2, 5), [3, 4, 5]);
      expect(pagedRowsAppendStart(first, last), 2);
      expect(pagedRowsAppendStart(last, first), isNull);
      expect(() => first[0] = 9, throwsUnsupportedError);
      expect(() => first.add(9), throwsUnsupportedError);
      expect(() => first.clear(), throwsUnsupportedError);
      expect(() => first[-1], throwsRangeError);
      expect(() => first[2], throwsRangeError);
    },
  );

  test(
    'freezing trusted chunks creates independent owners without row copies',
    () {
      final previousObserver = debugPagedRowsCopyObserver;
      var copied = 0;
      debugPagedRowsCopyObserver = (rows, _) => copied += rows;
      try {
        final builder = ImmutablePagedRowsBuilder<int>();
        for (var value = 0; value < 1000; value++) {
          builder.add(value);
        }
        final source = builder.snapshot();
        final first = freezePagedRows(source);
        final second = freezePagedRows(source);
        expect(identical(first, second), isFalse);
        expect(pagedRowsAppendStart(first, second), 1000);
        expect(isIndependentPagedRows(first), isTrue);
        expect(copied, 1000);
      } finally {
        debugPagedRowsCopyObserver = previousObserver;
      }
    },
  );

  test(
    'empty responses and distinct reads never share an owner or append proof',
    () {
      final first = ImmutablePagedRowsBuilder<int>().snapshot();
      final second = ImmutablePagedRowsBuilder<int>().snapshot();
      final copy = freezePagedRows(first);
      expect(identical(first, copy), isFalse);
      expect(pagedRowsAppendStart(first, copy), 0);
      expect(pagedRowsAppendStart(first, second), isNull);
      expect(pagedRowsAppendStart(<int>[], first), isNull);
      final mutable = [1, 2];
      final frozen = freezePagedRows(mutable);
      mutable[0] = 9;
      expect(frozen, [1, 2]);
      expect(pagedRowsAppendStart(mutable, frozen), isNull);
    },
  );

  test(
    'ten thousand variable chunks copy logarithmic paths and keep old roots',
    () {
      final previousObserver = debugPagedRowsCopyObserver;
      var copiedRows = 0;
      var metadataReferences = 0;
      var largestPath = 0;
      debugPagedRowsCopyObserver = (rows, references) {
        copiedRows += rows;
        metadataReferences += references;
        if (references > largestPath) largestPath = references;
      };
      try {
        final builder = ImmutablePagedRowsBuilder<int>();
        final old = <List<int>>[];
        var next = 0;
        List<int>? last;
        for (var chunk = 0; chunk < 10000; chunk++) {
          for (var index = 0; index < 1 + chunk % 7; index++) {
            builder.add(next++);
          }
          last = builder.snapshot();
          if (chunk < 8 || chunk == 127 || chunk == 999) old.add(last);
        }
        final rows = last!;
        expect(copiedRows, next);
        expect(largestPath, lessThanOrEqualTo(32));
        expect(
          metadataReferences,
          lessThan(10000 * 32),
          reason: '10,000 chunks must not copy 50,005,000 directory entries',
        );
        expect(rows.length, next);
        for (var index = 0; index < next; index += 37) {
          expect(rows[index], index);
          final end = (index + 23).clamp(0, next);
          expect(rows.getRange(index, end), [
            for (var i = index; i < end; i++) i,
          ]);
        }
        expect(rows.map((row) => row + 1), [for (var i = 1; i <= next; i++) i]);
        expect(rows.getRange(next, next), isEmpty);
        expect(() => rows.getRange(-1, 3), throwsRangeError);
        expect(() => rows.getRange(0, next + 1), throwsRangeError);
        for (final prefix in old) {
          expect(prefix, [for (var i = 0; i < prefix.length; i++) i]);
          expect(pagedRowsAppendStart(prefix, rows), prefix.length);
        }
        final before = metadataReferences;
        final same = builder.snapshot();
        expect(
          metadataReferences - before,
          1,
          reason: 'publishing an already sealed root is constant work',
        );
        expect(identical(same, rows), isFalse);
        expect(pagedRowsAppendStart(rows, same), rows.length);
      } finally {
        debugPagedRowsCopyObserver = previousObserver;
      }
    },
  );
}
