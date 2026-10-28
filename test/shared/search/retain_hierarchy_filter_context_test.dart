import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/widgets/production_daily_grid_columns.dart';
import 'package:uten_imp/shared/search/retain_hierarchy_filter_context.dart';

void main() {
  test(
    'tree matching retains visible ancestors without unrelated siblings or another root',
    () {
      final root = Object(),
          branch = Object(),
          match = Object(),
          sibling = Object(),
          otherBranch = Object(),
          otherLeaf = Object();
      final all = [root, branch, match, sibling, otherBranch, otherLeaf];
      final depths = Map<Object, int>.identity()
        ..addAll({
          root: 0,
          branch: 1,
          match: 2,
          sibling: 2,
          otherBranch: 1,
          otherLeaf: 2,
        });
      expect(
        retainMatchedPreorderAncestors(all, [
          match,
        ], depthOf: (row) => depths[row]!),
        [root, branch, match],
      );
      expect(
        retainMatchedPreorderAncestors(all, [
          otherLeaf,
        ], depthOf: (row) => depths[row]!),
        [root, otherBranch, otherLeaf],
      );
      expect(
        retainMatchedPreorderAncestors(
          all,
          <Object>[],
          depthOf: (row) => depths[row]!,
        ),
        isEmpty,
      );
      expect(all, [root, branch, match, sibling, otherBranch, otherLeaf]);
      expect(
        retainMatchedPreorderAncestors(
          [root, branch],
          [branch],
          depthOf: (row) => depths[row]!,
        ),
        [root, branch],
      );
    },
  );

  test(
    'matching a material retains its product, section and destination in source order',
    () {
      final product = DailyGridRow();
      final section = DailyGridRow()..depth = 1;
      final material = DailyGridRow()..depth = 2;
      final destination = DailyGridRow()..depth = 2;
      final anotherProduct = DailyGridRow();
      final anotherMaterial = DailyGridRow()..depth = 2;
      final all = [
        product,
        section,
        material,
        destination,
        anotherProduct,
        anotherMaterial,
      ];
      addTearDown(() {
        for (final row in all) {
          row.dispose();
        }
      });
      final result = retainMatchedPreorderGroups(all, [
        material,
      ], isGroupStart: (DailyGridRow row) => !row.isSubRow);
      expect(result, [product, section, material, destination]);
      expect(all, [
        product,
        section,
        material,
        destination,
        anotherProduct,
        anotherMaterial,
      ]);
      expect(
        retainMatchedPreorderGroups(all, [
          product,
          anotherMaterial,
        ], isGroupStart: (DailyGridRow row) => !row.isSubRow),
        all,
      );
    },
  );

  test(
    'an expanded projection is not promoted to the complete logical tree',
    () {
      final root = Object(), shownChild = Object(), collapsedChild = Object();
      final all = [root, shownChild];
      expect(
        retainMatchedPreorderGroups(all, [
          shownChild,
        ], isGroupStart: (row) => identical(row, root)),
        all,
      );
      expect(all, isNot(contains(collapsedChild)));
      expect(
        retainMatchedPreorderGroups(
          all,
          <Object>[],
          isGroupStart: (row) => identical(row, root),
        ),
        isEmpty,
      );
    },
  );
}
