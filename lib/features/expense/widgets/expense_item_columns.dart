import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/formatters/money_display.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/expense_item.dart';

/// One schema for creation, detail, approval, preview and downloads.
final expenseItemColumns = <MasterColumnDef<ExpenseItem>>[
  // 2026-11-11 口径：费用科目类别列按值筛选；日期/金额列可排序（明细表是
  //全量快照，就地排序、收集桶；币种列恒人民币不设筛选）。
  MasterColumnDef(
    key: 'category',
    label: '费用科目',
    width: 130,
    filterFromRows: true,
    value: (item) => item.category.label,
  ),
  MasterColumnDef(
    key: 'date',
    label: '日期',
    width: 110,
    type: 'date',
    sortable: true,
    value: (item) =>
        '${item.date.year}-${item.date.month.toString().padLeft(2, '0')}-${item.date.day.toString().padLeft(2, '0')}',
  ),
  MasterColumnDef(
    key: 'description',
    label: '说明',
    width: 260,
    value: (item) => item.description,
  ),
  // 报销恒人民币（2026-10-10 金额带单位口径：数值后自动带「元」）。
  MasterColumnDef(
    key: 'amount',
    exactValueOf: (item) => item.amountText,
    label: '金额',
    width: 140,
    type: 'money',
    sortable: true,
    value: (item) => financeLocalMoneyWithUnitSuffix(
      financeExactMoneyDisplay(item.amountText),
    ),
  ),
  MasterColumnDef(
    key: 'currency',
    label: '币种',
    width: 80,
    value: (_) => expenseClaimCurrencyName,
  ),
];
