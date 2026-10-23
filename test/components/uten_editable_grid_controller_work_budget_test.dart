import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';

class _Row extends EditableGridRow with AmountRowMixin {
  _Row(this.id);
  final int id;
  static int comparisons = 0;
  int disposals = 0;

  @override
  bool operator ==(Object other) {
    comparisons++;
    return identical(this, other);
  }

  @override
  int get hashCode => id.hashCode;

  @override
  void dispose() {
    disposals++;
    super.dispose();
  }
}

void main() {
  test(
    'row snapshots are reused until membership changes and stay immutable',
    () {
      final first = _Row(1);
      final second = _Row(2);
      final controller = UtenEditableGridController<_Row>(initial: [first]);
      addTearDown(controller.dispose);
      final before = controller.rows;
      expect(identical(before, controller.rows), isTrue);
      expect(() => before.clear(), throwsUnsupportedError);
      controller.toggleSelect(first);
      expect(identical(before, controller.rows), isTrue);
      // Total notifications are synchronous: readers must already see new rows.
      List<_Row>? observed;
      controller.totalListenable.addListener(() => observed = controller.rows);
      second.recalcAmount(() => 3.25);
      controller.addRow(second);
      expect(before, [first]);
      expect(controller.rows, [first, second]);
      expect(identical(observed, controller.rows), isTrue);
      expect(controller.total, 3.25);
      second.recalcAmount(() => 4.75);
      expect(
        controller.total,
        controller.rows.fold<double>(0, (sum, row) => sum + row.amountValue),
      );
    },
  );

  test(
    'large selected snapshots and batch removal perform linear membership work',
    () {
      final rows = [for (var i = 0; i < 2000; i++) _Row(i)];
      final controller = UtenEditableGridController<_Row>(initial: rows);
      addTearDown(controller.dispose);
      controller.setSelected(rows.reversed, true);
      _Row.comparisons = 0;
      final selected = controller.selectedRows;
      final selectionComparisons = _Row.comparisons;
      expect(selected, orderedEquals(rows.reversed));
      expect(selectionComparisons, lessThan(10000));
      final absent = _Row(3000);
      addTearDown(absent.dispose);
      _Row.comparisons = 0;
      controller.removeRows([...rows.reversed, rows.first, absent]);
      final removalComparisons = _Row.comparisons;
      debugPrint(
        'editable-membership rows=2000 selectedComparisons=$selectionComparisons removalComparisons=$removalComparisons',
      );
      expect(removalComparisons, lessThan(20000));
      expect(controller.rows, isEmpty);
      expect(controller.selectedRows, isEmpty);
      expect(rows.every((row) => row.disposals == 1), isTrue);
      expect(absent.disposals, 0);
    },
  );

  test(
    'swap and removal refresh membership without changing surviving row objects',
    () {
      final rows = [_Row(1), _Row(2), _Row(3)];
      final controller = UtenEditableGridController<_Row>(initial: rows);
      controller.setSelected([rows[2], rows[0]], true);
      expect(controller.selectedRows, [rows[2], rows[0]]);
      controller.swapRows([rows[0], rows[1]]);
      expect(controller.selectedRows, [rows[0]]);
      expect(rows[2].disposals, 0);
      controller.swapRows(rows);
      expect(controller.selectedRows, [rows[2], rows[0]]);
      controller.removeAt(0);
      expect(controller.selectedRows, [rows[2]]);
      expect(rows[0].disposals, 1);
      controller.dispose();
      expect(rows.every((row) => row.disposals == 1), isTrue);
    },
  );
}
