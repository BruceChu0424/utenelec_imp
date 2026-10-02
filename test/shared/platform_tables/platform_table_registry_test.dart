import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/account_node.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/features/production/widgets/production_daily_grid_columns.dart';
import 'package:uten_imp/features/production/widgets/production_grid_columns.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/features/stock/models/stock_query.dart';
import 'package:uten_imp/features/warehouse/widgets/stock_grid_columns.dart';
import 'package:uten_imp/platform_table_registry.dart';
import 'package:uten_imp/shared/formatters/exact_decimal.dart';
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
    'instant inventory display formulas distinguish physical and pending quantities',
    () {
      const row = InstantInventoryRow(
        goodsId: 'goods-identity-is-not-a-stock-record',
        qty: 12.3456789,
        pendingQty: 3,
        pendingStockInQty: 7,
        moreQty: 2,
        costAmount: 987.65,
        unitWeightKg: 0.08,
      );
      final binding = _binding(
        row,
        'features.stock.pages.instant_inventory_page.items',
      );
      expect(binding.scope, 'view_warehouse');
      expect(binding.recordIdOf(row), isNull);
      expect(binding.canEditValues, isFalse);
      expect(binding.factValuesOf!(row), {
        'qty': '12.3456789',
        'weight': null,
        'pendingQty': '3.0',
        'pendingStockInQty': '7.0',
        'moreQty': '2.0',
      });
      final controller = PlatformTableController<InstantInventoryRow>()
        ..binding = binding
        ..capabilities = const PlatformTableCapabilities(
          scope: 'view_warehouse',
          supportsValues: false,
          facts: [
            PlatformTableFact(key: 'qty', name: '库存数量'),
            PlatformTableFact(key: 'pendingStockInQty', name: '合格待入库'),
          ],
        );
      addTearDown(controller.dispose);
      const formula = PlatformColumnDefinition(
        id: 'expected-stock',
        scope: 'view_warehouse',
        name: '入库后参考数量',
        type: 'CALCULATED',
        formula: PlatformFormula(
          base: PlatformFormulaOperand(fact: 'qty'),
          steps: [
            PlatformFormulaStep(
              operation: 'ADD',
              operand: PlatformFormulaOperand(fact: 'pendingStockInQty'),
            ),
          ],
        ),
      );
      expect(controller.value(row, formula), '19.3456789');
      expect(row.qty, 12.3456789);
    },
  );

  test(
    'account statement formulas retain exact amounts and dedicated access scope',
    () {
      const row = AccountStatementRow(
        entryId: 'ledger-entry',
        inAmountText: '9007199254740993.00000001',
        outAmountText: '0.00000001',
        balanceText: '9007199254740993',
      );
      final binding = _binding(
        row,
        'features.basic_data.pages.account_detail_page.flow',
      );
      expect(binding.scope, 'view_account_statement');
      expect(binding.recordIdOf(row), isNull);
      expect(binding.canEditValues, isFalse);
      final controller = PlatformTableController<AccountStatementRow>()
        ..binding = binding
        ..capabilities = const PlatformTableCapabilities(
          scope: 'view_account_statement',
          priceVisible: true,
          supportsValues: false,
          facts: [
            PlatformTableFact(
              key: 'inAmount',
              name: '收入',
              priceProtected: true,
            ),
            PlatformTableFact(
              key: 'outAmount',
              name: '支出',
              priceProtected: true,
            ),
            PlatformTableFact(key: 'balance', name: '余额', priceProtected: true),
          ],
        );
      addTearDown(controller.dispose);
      const formula = PlatformColumnDefinition(
        id: 'cash-flow',
        scope: 'view_account_statement',
        name: '净流入',
        type: 'CALCULATED',
        priceProtected: true,
        formula: PlatformFormula(
          base: PlatformFormulaOperand(fact: 'inAmount'),
          steps: [
            PlatformFormulaStep(
              operation: 'SUBTRACT',
              operand: PlatformFormulaOperand(fact: 'outAmount'),
            ),
          ],
        ),
      );
      expect(
        financeExactTrimmed(controller.value(row, formula)),
        '9007199254740993',
      );
      controller.capabilities = const PlatformTableCapabilities(
        scope: 'view_account_statement',
        supportsValues: false,
        facts: [
          PlatformTableFact(key: 'balance', name: '余额', priceProtected: true),
        ],
      );
      expect(controller.value(row, formula), '***');
      const unprotectedFormula = PlatformColumnDefinition(
        id: 'unprotected',
        scope: 'view_account_statement',
        name: '无权限引用',
        type: 'CALCULATED',
        formula: PlatformFormula(base: PlatformFormulaOperand(fact: 'balance')),
      );
      expect(controller.value(row, unprotectedFormula), isNull);
      expect(
        platformDisplayFacts(
          const AccountStatementRow(balance: 123.45),
        )['balance'],
        isNull,
      );
    },
  );

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
