import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/expense/models/expense_item.dart';
import 'package:uten_imp/features/expense/widgets/expense_editable_items.dart';

void main() {
  test(
    'unfinished cells retain raw decimal text and row identity through recovery',
    () {
      final row = ExpenseGridRow()
        ..amount.text = '0001.'
        ..description.text = '未完成用途  ';
      final restored = ExpenseGridRow.restore(row.exportDraft(), id: row.id);
      expect(restored.amount.text, '0001.');
      expect(restored.description.text, '未完成用途  ');
      expect(restored.id, row.id);
      expect(restored.validationError?.column, 'amount');
      restored.amount.text = '12.50';
      expect(restored.validationError, isNull);
      expect(restored.toItem().amount, 12.5);
      row.dispose();
      restored.dispose();
    },
  );
  test(
    'copies retain raw inputs while dropping persisted source authority',
    () {
      final original = ExpenseGridRow.fromItem(
        ExpenseItem(
          id: 'persisted',
          category: ExpenseCategory.travel,
          amount: 100,
          date: DateTime(2026, 11),
          description: '住宿',
        ),
        persisted: true,
      );
      original.platformFields.version = 9;
      original.platformFields.loaded = true;
      original.platformFields.canWrite = true;
      original.amount.text = '100.005';
      final copied = original.clone();
      expect(copied.id, isNot(original.id));
      expect(copied.amount.text, '100.005');
      expect(copied.platformFields.sourceRecordId, isNull);
      expect(copied.platformFields.version, 0);
      expect(copied.platformFields.canWrite, isFalse);
      expect(original.platformFields.sourceRecordId, 'persisted');
      original.dispose();
      copied.dispose();
    },
  );
  testWidgets(
    'shared grid mounts a bounded subset of 2000 editable rows and preserves the tail',
    (tester) async {
      final grid = UtenEditableGridController<ExpenseGridRow>(
        initial: [
          for (var index = 0; index < 2000; index++)
            ExpenseGridRow()
              ..amount.text = '0.01'
              ..description.text = '费用 $index',
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ExpenseEditableItems(controller: grid, editable: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(grid.length, 2000);
      expect(grid.mountedRowCount, lessThan(100));
      expect(grid.rows.last.description.text, '费用 1999');
      expect(
        grid.rows.fold<BigInt>(
          BigInt.zero,
          (sum, row) => sum + row.amountUnits!,
        ),
        BigInt.from(20) * BigInt.from(10).pow(24),
      );
      grid.rows.last.amount.text = '0.';
      expect(grid.rows.last.exportDraft()['amountText'], '0.');
      expect(grid.rows.last.validationError?.column, 'amount');
      await tester.pumpWidget(const SizedBox());
      grid.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
