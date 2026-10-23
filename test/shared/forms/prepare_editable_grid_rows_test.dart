import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/performance/json_value_snapshot.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/widgets/ar_ap_picker_dialog.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/features/sales/widgets/sales_doc_link_picker.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/shared/forms/prepare_editable_grid_rows.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

class _Row extends EditableGridRow {
  _Row(this.id);
  final int id;
  final value = TextEditingController();
  int disposed = 0;
  @override
  void dispose() {
    disposed++;
    value.dispose();
    super.dispose();
  }
}

void main() {
  test(
    'prepares private rows, yields and publishes the complete set once',
    () async {
      final grid = UtenEditableGridController<_Row>();
      final old = _Row(-1);
      grid.addRow(old);
      var published = 0;
      var timerSawOldRows = false;
      Timer.run(() => timerSawOldRows = identical(grid.rows.single, old));
      await prepareEditableGridRows(
        List.generate(1000, (index) => index),
        create: _Row.new,
        initialize: (row, value) => row.value.text = '000$value.',
        budget: UiWorkBudget(maxItems: 1),
        isCurrent: () => true,
        publish: (rows) {
          published++;
          grid.replaceAll(rows);
        },
      );
      expect(timerSawOldRows, isTrue);
      expect(published, 1);
      expect(grid.length, 1000);
      expect(grid[999].value.text, '000999.');
      expect(old.disposed, 1);
      grid.dispose();
    },
  );

  for (final reason in ['owner epoch', 'rows revision']) {
    test(
      '$reason change disposes all private rows without publication',
      () async {
        final grid = UtenEditableGridController<_Row>();
        grid.addRow(_Row(-1));
        final revision = grid.rowsRevision;
        var epoch = 1;
        final created = <_Row>[];
        Timer.run(() {
          if (reason == 'owner epoch') {
            epoch = 2;
          } else {
            grid.addRow(_Row(-2));
          }
        });
        await expectLater(
          prepareEditableGridRows(
            List.generate(1000, (index) => index),
            create: (value) {
              final row = _Row(value);
              created.add(row);
              return row;
            },
            initialize: (row, _) => row.value.text = '0001.',
            isCurrent: () => epoch == 1 && grid.rowsRevision == revision,
            budget: UiWorkBudget(maxItems: 1),
            publish: (_) => fail('a stale row set must never publish'),
          ),
          throwsA(isA<UiWorkCancelled>()),
        );
        expect(created, isNotEmpty);
        expect(created.length, lessThan(1000));
        expect(created.every((row) => row.disposed == 1), isTrue);
        expect(grid.rows.every((row) => row.id < 0), isTrue);
        grid.dispose();
      },
    );
  }

  test('initializer failure disposes the failing final row too', () async {
    final created = <_Row>[];
    await expectLater(
      prepareEditableGridRows(
        [0, 1, 2, 3],
        create: (value) {
          final row = _Row(value);
          created.add(row);
          return row;
        },
        initialize: (row, value) {
          row.value.text = 'unchanged raw';
          if (value == 2) throw const FormatException('bad field');
        },
        isCurrent: () => true,
        publish: (_) => fail('partial rows must never publish'),
      ),
      throwsFormatException,
    );
    expect(created.map((row) => row.id), [0, 1, 2]);
    expect(created.every((row) => row.disposed == 1), isTrue);
  });

  test(
    'late dependency and final input snapshot both fence publication',
    () async {
      for (final lateOwner in [true, false]) {
        var current = true;
        var finalChecks = 0;
        final rows = <_Row>[];
        await expectLater(
          prepareEditableGridRows(
            [1, 2],
            create: (value) {
              final row = _Row(value);
              rows.add(row);
              return row;
            },
            initialize: (_, _) {},
            isCurrent: () => current,
            beforePublish: (_) async {
              await Future<void>.delayed(Duration.zero);
              if (lateOwner) current = false;
            },
            canPublish: () {
              finalChecks++;
              return false;
            },
            publish: (_) => fail('late owner/input must reject publication'),
          ),
          throwsA(isA<UiWorkCancelled>()),
        );
        expect(rows.every((row) => row.disposed == 1), isTrue);
        expect(finalChecks, lateOwner ? 0 : 1);
      }
    },
  );

  test(
    'cell edits without a row revision invalidate the final snapshot',
    () async {
      final grid = UtenEditableGridController<_Row>();
      final existing = _Row(-1)..value.text = 'original';
      grid.addRow(existing);
      final revision = grid.rowsRevision;
      final snapshot = JsonValueSnapshot.capture({'raw': existing.value.text});
      final created = <_Row>[];
      Timer.run(() => existing.value.text = 'new user input');
      await expectLater(
        prepareEditableGridRows(
          [1, 2, 3],
          create: (value) {
            final row = _Row(value);
            created.add(row);
            return row;
          },
          initialize: (_, _) {},
          budget: UiWorkBudget(maxItems: 1),
          isCurrent: () => grid.rowsRevision == revision,
          canPublish: () => snapshot.matches({'raw': existing.value.text}),
          publish: grid.addRows,
        ),
        throwsA(isA<UiWorkCancelled>()),
      );
      expect(grid.rowsRevision, revision);
      expect(grid.rows, [existing]);
      expect(existing.value.text, 'new user input');
      expect(created.every((row) => row.disposed == 1), isTrue);
      grid.dispose();
    },
  );

  test(
    'draft preparation keeps raw text, full rows and selected order',
    () async {
      final grid = UtenEditableGridController<_Row>();
      await restoreDraftGridResponsive(
        grid,
        List.generate(
          1000,
          (i) => {'id': i, 'raw': '0001.', 'selected': i == 999},
        ),
        create: (raw) => _Row(raw['id'] as int),
        initialize: (row, raw) => row.value.text = raw['raw'] as String,
        isCurrent: () => true,
      );
      expect(grid.length, 1000);
      expect(grid.rows.every((row) => row.value.text == '0001.'), isTrue);
      expect(grid.isSelected(grid[0]), isFalse);
      expect(grid.isSelected(grid[999]), isTrue);
      grid.dispose();
    },
  );

  test(
    'Sales factory and owned restore preserve raw text and pricing flags',
    () {
      final source = SalesGridRow(
        amountUsesDiscount: true,
        allowPricingInput: true,
      );
      source.qty.text = '0001.';
      source.price.text = '0012.5000';
      source.discount.text = '0.8000';
      source.quoteDiscountLocked = true;
      source.requiresOrderPriceRefresh = true;
      source.remark.text = '原始未完成输入';
      final data = source.exportDraft();
      final factory = SalesGridRow.fromDraft(data, allowPricingInput: true);
      final owned = SalesGridRow(
        amountUsesDiscount: true,
        allowPricingInput: true,
      )..restoreDraft(data);
      expect(
        jsonValuesEqual(factory.exportDraft(), owned.exportDraft()),
        isTrue,
      );
      expect(owned.qty.text, '0001.');
      expect(owned.price.text, '0012.5000');
      expect(owned.discount.text, '0.8000');
      expect(owned.quoteDiscountLocked, isTrue);
      expect(owned.requiresOrderPriceRefresh, isTrue);
      for (final row in [source, factory, owned]) {
        row.dispose();
      }
    },
  );

  test(
    'Sales linked factory and owned initializer retain source identities',
    () {
      const linked = SalesLinkedItem(
        goodsId: 'goods',
        qty: 1.25,
        price: 12.5,
        orderItemId: 'physical-order-row',
        colorId: 'color',
        unitId: 'unit',
        unitRate: 2,
      );
      const goods = GoodsOption(id: 'goods', name: '商品');
      final factory = SalesGridRow.fromLinked(linked, goods);
      final owned = SalesGridRow()..initializeLinked(linked, goods);
      expect(
        jsonValuesEqual(factory.exportDraft(), owned.exportDraft()),
        isTrue,
      );
      expect(owned.orderItemId, 'physical-order-row');
      expect(owned.qty.text, '1.25');
      factory.dispose();
      owned.dispose();
    },
  );

  test(
    'Finance owned ledger initializer preserves authoritative raw values',
    () {
      const ledger = AppliedArAp(
        ledgerId: 'ledger',
        appliedBillNo: 'AR-1',
        receiptAmountText: '00012.50',
        authoritativeSalesOrderId: 'order',
        salesOrderIds: ['order'],
        currencyId: 'currency',
        balanceOriginal: 30,
        balanceOriginalText: '0030.00',
        receivableOriginalText: '0040.00',
        prepaymentAppliedOriginal: '0010.00',
      );
      final factory = FinanceGridRow.fromApplied(ItemMode.settle, ledger);
      final owned = FinanceGridRow(mode: ItemMode.settle)..applyLedger(ledger);
      for (final row in [factory, owned]) {
        expect(row.appliedLedgerId, 'ledger');
        expect(row.authoritativeSalesOrderId, 'order');
        expect(row.salesOrderIds, ['order']);
        expect(row.amount.text, '00012.50');
        expect(row.balanceOriginalText, '0030.00');
        expect(row.receivableOriginalText, '0040.00');
        expect(row.prepaymentAppliedOriginal, '0010.00');
        expect(row.amountValue, 12.5);
        row.dispose();
      }
    },
  );
}
