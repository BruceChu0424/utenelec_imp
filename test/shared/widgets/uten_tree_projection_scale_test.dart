import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/widgets/uten_tree_row_projection.dart';

void main() {
  test('boundary discovery matches independent forward-scan oracle', () {
    final random = Random(317);
    for (var sample = 0; sample < 80; sample++) {
      final depths = List.generate(100, (_) => random.nextInt(9) - 1);
      final keys = List.generate(100, (_) => random.nextInt(3));
      final actual = utenTreeProjection<int>(
        List.generate(depths.length, (index) => index),
        depthOf: (index) => depths[index],
        treeKeyOf: (index) => keys[index],
      );
      final ancestors = <int, int>{};
      for (var index = 0; index < depths.length; index++) {
        var end = index + 1;
        var children = 0;
        while (end < depths.length && depths[end] > depths[index]) {
          if (depths[end] == depths[index] + 1) children++;
          end++;
        }
        final sibling =
            end < depths.length &&
            depths[end] == depths[index] &&
            keys[end] == keys[index];
        expect(actual[index].subtreeEnd, end);
        expect(actual[index].childCount, children);
        expect(actual[index].isLastChild, !sibling);
        final parent = ancestors[depths[index] - 1];
        final expected = depths[index] <= 0
            ? <bool>[]
            : parent == null
            ? List<bool>.filled(depths[index], true)
            : [
                ...actual[parent].ancestorContinuations,
                !actual[parent].isLastChild,
              ];
        expect(actual[index].ancestorContinuations, expected);
        ancestors[depths[index]] = index;
        ancestors.removeWhere((key, _) => key > depths[index]);
      }
    }
  });

  test('nested 500-product fixture has bounded structural work', () {
    final depths = <int>[
      for (var product = 0; product < 500; product++) ...[
        0,
        1,
        2,
        3,
        3,
        2,
        1,
        2,
        3,
        3,
      ],
    ];
    final result = utenTreeProjection<int>(depths, depthOf: (value) => value);
    expect(result.length, 5000);
    expect(
      debugTreeProjectionBoundaryVisits,
      lessThanOrEqualTo(2 * depths.length),
    );
    expect(result.first.subtreeEnd, 10);
    expect(result.last.subtreeEnd, depths.length);
  });
}
