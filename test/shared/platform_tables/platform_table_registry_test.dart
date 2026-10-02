import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/features/production/widgets/production_daily_grid_columns.dart';
import 'package:uten_imp/features/production/widgets/production_grid_columns.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/features/warehouse/widgets/stock_grid_columns.dart';
import 'package:uten_imp/platform_table_registry.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';

PlatformTableBinding<T> _binding<T>(T row, String tableKey) =>
    resolvePlatformTable(
      PlatformTableDescriptor<T>(
        kind: 'editable',
        tableKey: tableKey,
        columnKeys: const ['qty', 'amount'],
        rows: [row],
      ),
    )!;

void main() {
  test(
    'cost table keys use independent cost permission and exact protected facts',
    () {
      final row = <String, dynamic>{
        'id': 'cost-owned-id',
        'amount': '1.23456789',
        'supplierSecret': 'not-a-display-fact',
      };
      for (final key in [
        'master.goods.cost.items',
        'master.goods.cost.actual.0',
        'master.goods.cost.versions',
        'finance.inventory_cost_posting',
      ]) {
        final binding = resolvePlatformTable(
          PlatformTableDescriptor<Map<String, dynamic>>(
            kind: 'master',
            tableKey: key,
            columnKeys: const ['amount'],
            rows: [row],
          ),
        )!;
        expect(binding.scope, 'view_goods_cost');
        expect(binding.recordIdOf(row), isNull);
        expect(binding.canEditValues, isFalse);
        expect(binding.factValuesOf!(row)['amount'], '1.23456789');
        expect(
          binding.factValuesOf!(row).containsKey('supplierSecret'),
          isFalse,
        );
      }
    },
  );
  test(
    'transactional finance edit computes from exact current input and canonical aliases',
    () {
      final row = FinanceGridRow(mode: ItemMode.allocate);
      addTearDown(row.dispose);
      row.amount.text = '0.1234567890123456789';
      row.exchangeRate.text = '2';
      final binding = _binding(row, 'finance.expense.items');
      expect(binding.scope, 'finance_expense_item');
      expect(binding.factValuesOf!(row)['amount'], '0.1234567890123456789');
      expect(binding.factListenablesOf!(row), contains(row.amount));
      final controller = PlatformTableController<FinanceGridRow>()
        ..binding = binding
        ..draftOf = ((row) => row.platformFields)
        ..capabilities = const PlatformTableCapabilities(
          scope: 'finance_expense_item',
          priceVisible: true,
          facts: [
            PlatformTableFact(
              key: 'amountOriginal',
              name: '原币金额',
              priceProtected: true,
            ),
          ],
        );
      addTearDown(controller.dispose);
      const formula = PlatformColumnDefinition(
        id: 'calc',
        scope: 'finance_expense_item',
        name: '参考',
        type: 'CALCULATED',
        formula: PlatformFormula(
          base: PlatformFormulaOperand(fact: 'amountOriginal'),
          steps: [
            PlatformFormulaStep(
              operation: 'MULTIPLY',
              operand: PlatformFormulaOperand(constant: '2'),
            ),
          ],
        ),
      );
      expect(controller.value(row, formula), '0.2469135780246913578');
      row.amount.text = '0.000000001';
      expect(controller.value(row, formula), '0.000000002');
      row.amount.clear();
      expect(controller.value(row, formula), isNull);
    },
  );

  test(
    'shipment record binding retains raw line calculation and input listeners',
    () {
      final row = SalesGridRow();
      addTearDown(row.dispose);
      row.qty.text = '1.00000001';
      row.price.text = '2';
      final binding = _binding(row, 'sales.shipment.items');
      expect(binding.scope, 'sales_shipment_item');
      expect(binding.factValuesOf!(row)['qty'], '1.00000001');
      expect(binding.factValuesOf!(row)['amount'], '2.00000002');
      expect(binding.factListenablesOf!(row), contains(row.qty));
    },
  );

  test(
    'stock checking keeps book and counted quantities distinct without unit guessing',
    () {
      final row = StockGridRow(isCheck: true);
      addTearDown(row.dispose);
      row.bookQty.text = '9.123456789';
      row.checkQty.text = '8.123456788';
      final binding = _binding(row, 'warehouse.check.items');
      expect(binding.columnAliases['bookQty'], 'qty');
      expect(binding.columnAliases['checkQty'], 'countQty');
      expect(binding.factValuesOf!(row)['qty'], '9.123456789');
      expect(binding.factValuesOf!(row)['countQty'], '8.123456788');
      expect(binding.factValuesOf!(row), isNot(contains('weight')));
    },
  );

  test(
    'production clone provenance is not an existing field record and child rows cannot write',
    () {
      final plan = ProductionGridRow()..sourceItemId = 'upstream-provenance';
      plan.qty.text = '3.000000001';
      final daily = DailyGridRow();
      final child = DailyGridRow()..depth = 1;
      addTearDown(plan.dispose);
      addTearDown(daily.dispose);
      addTearDown(child.dispose);
      final planBinding = _binding(plan, 'production.plan.items');
      expect(planBinding.recordIdOf(plan), isNull);
      expect(planBinding.factValuesOf!(plan)['qty'], '3.000000001');
      final dailyBinding = _binding(daily, 'production.daily.items');
      expect(dailyBinding.canEditRow!(daily), isTrue);
      expect(dailyBinding.canEditRow!(child), isFalse);
      expect(dailyBinding.factValuesOf!(child)['qty'], isNull);
    },
  );
}
