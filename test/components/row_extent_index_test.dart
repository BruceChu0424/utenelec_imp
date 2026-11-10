import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/src/row_extent_index.dart';

int _naiveRowAt(List<double> heights, double offset) {
  var end = 0.0;
  for (var index = 0; index < heights.length; index++) {
    end += heights[index];
    if (end > offset) return index;
  }
  return heights.isEmpty ? 0 : heights.length - 1;
}

void _compare(RowExtentIndex index, List<double> heights, Random random) {
  expect(index.rowCount, heights.length);
  var prefix = 0.0;
  expect(index[0], 0);
  final offsets = <double>[-1, 0];
  for (var row = 0; row < heights.length; row++) {
    prefix += heights[row];
    expect(index[row + 1], prefix);
    offsets.addAll([prefix, prefix - .125, prefix + .125]);
  }
  expect(index.last, prefix);
  offsets.addAll([prefix + 10, random.nextDouble() * (prefix + 1)]);
  for (final offset in offsets) {
    expect(
      index.rowAt(offset),
      _naiveRowAt(heights, offset),
      reason: 'lookup at $offset in ${heights.length} rows',
    );
  }
}

void main() {
  test('100k fractional estimated rows can all be measured as zero', () {
    final index = RowExtentIndex();
    index.reset(
      count: 100000,
      estimate: 52.3,
      deltas: List<double>.filled(100000, 0),
    );
    for (var row = 0; row < 100000; row++) {
      index.setHeight(row, 0);
    }
    expect(index.last, closeTo(0, RowExtentIndex.geometryEpsilon));
    expect(index.rowAt(0), 99999);
  });
  for (final estimate in [.1, 10.1, 52.3]) {
    test(
      'fractional estimate $estimate reaches all zero without negative extent',
      () {
        final index = RowExtentIndex();
        index.reset(
          count: 1000,
          estimate: estimate,
          deltas: List<double>.filled(1000, 0),
        );
        for (var row = 0; row < 1000; row++) {
          index.setHeight(row, 0);
          index.setHeight(
            row,
            0,
          ); // A duplicate late measurement is idempotent.
        }
        expect(index.last, closeTo(0, 1e-7));
        expect(index.rowAt(0), 999);
        for (var repeat = 0; repeat < 100; repeat++) {
          index.setHeight(500, 21.37);
          expect(index.last, closeTo(21.37, 1e-7));
          index.setHeight(500, 0);
          index.replaceTail(
            common: 998,
            count: 1000,
            deltas: [-estimate, -estimate],
          );
        }
        expect(index.last, closeTo(0, 1e-7));
        expect(index.rowAt(0), 999);
      },
    );
  }
  test(
    'append, moving suffix, measurements and resets match naive prefix sums',
    () {
      for (final seed in [1, 19, 20261110]) {
        final random = Random(seed);
        final index = RowExtentIndex();
        final heights = <double>[];
        var estimate = 52.0;
        index.reset(count: 0, estimate: estimate, deltas: const []);
        for (var operation = 0; operation < 600; operation++) {
          if (operation % 37 == 0) {
            estimate = random.nextInt(240) / 4;
            index.reset(
              count: heights.length,
              estimate: estimate,
              deltas: heights.map((height) => height - estimate),
            );
          } else if (heights.isNotEmpty && random.nextBool()) {
            final row = random.nextInt(heights.length);
            final height = random.nextInt(800) / 4;
            heights[row] = height;
            index.setHeight(row, height);
          } else {
            final common = heights.isEmpty
                ? 0
                : random.nextInt(heights.length + 1);
            final tail = [
              for (var i = 0; i < random.nextInt(12); i++)
                random.nextInt(800) / 4,
            ];
            heights.replaceRange(common, heights.length, tail);
            index.replaceTail(
              common: common,
              count: heights.length,
              deltas: tail.map((height) => height - estimate),
            );
          }
          _compare(index, heights, random);
        }
      }
    },
  );

  test(
    'zero rows/heights, large extents and removed negative deltas have no ghosts',
    () {
      final index = RowExtentIndex();
      final random = Random(3);
      index.reset(count: 0, estimate: 0, deltas: const []);
      _compare(index, [], random);
      final heights = [0.0, 0.0, 1e12, .25, 0.0, 1e12];
      index.reset(
        count: heights.length,
        estimate: 52,
        deltas: heights.map((height) => height - 52),
      );
      _compare(index, heights, random);
      index.replaceTail(common: 2, count: 3, deltas: const [-52]);
      _compare(index, [0, 0, 0], random);
      index.replaceTail(common: 0, count: 0, deltas: const []);
      _compare(index, [], random);
      index.reset(count: 0, estimate: 52, deltas: const []);
      expect(
        index.capacity,
        0,
        reason: 'retiring a full source releases its cells',
      );
      expect(() => index[1], throwsRangeError);
      expect(() => index.setHeight(0, 10), throwsRangeError);
      expect(
        () => index.reset(count: 1, estimate: -1, deltas: const [0]),
        throwsArgumentError,
      );
      index.reset(count: 1, estimate: 0, deltas: const [0]);
      for (final invalid in [-1e-9, double.nan, double.infinity]) {
        expect(
          () => index.setHeight(0, invalid),
          throwsArgumentError,
          reason: 'geometry tolerance never accepts an invalid input height',
        );
      }
    },
  );

  test(
    '100k append and footer moves retain linear growth and logarithmic updates',
    () {
      final work = <String, int>{};
      final index = RowExtentIndex(
        onWork: (operation, count) {
          work.update(
            operation,
            (previous) => previous + count,
            ifAbsent: () => count,
          );
        },
      );
      index.reset(count: 0, estimate: 52, deltas: const []);
      var before = 0;
      for (var count = 1000; count <= 100000; count += 1000) {
        index.replaceTail(
          common: before,
          count: count + 2,
          deltas: [for (var i = before; i < count; i++) 0.0, 28.0, -12.0],
        );
        expect(index.last, count * 52 + 80 + 40);
        expect(index[count], count * 52);
        expect(index.rowAt(count * 52), count);
        index.setHeight(count, 81.25);
        index.setHeight(count + 1, 0);
        expect(index.last, count * 52 + 81.25);
        before = count;
      }
      expect(index.capacity, lessThan(2 * index.rowCount));
      expect(work['growCopiedCells'] ?? 0, lessThan(2 * index.capacity));
      expect(
        work['resetCells'],
        0,
        reason: 'ordinary append never resets all rows',
      );
      expect(work['updateCells'] ?? 0, lessThan(100 * 10 * 18));
      final updates = work['updateCells'] ?? 0;
      index.setHeight(50000, 100);
      expect((work['updateCells'] ?? 0) - updates, lessThanOrEqualTo(18));
      expect(index[50000], 50000 * 52);
      expect(index[50001], 50000 * 52 + 100);
    },
  );
}
