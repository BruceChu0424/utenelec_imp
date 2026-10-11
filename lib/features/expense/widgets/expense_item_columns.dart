import '../../../shared/formatters/money_display.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/expense_item.dart';

/// One schema for creation, detail, approval, preview and downloads.
final expenseItemColumns = <MasterColumnDef<ExpenseItem>>[
  MasterColumnDef(
    key: 'category',
    label: '费用科目',
    width: 130,
    value: (item) => item.category.label,
  ),
  MasterColumnDef(
    key: 'date',
    label: '日期',
    width: 110,
    type: 'date',
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
    label: '金额',
    width: 140,
    type: 'money',
    value: (item) =>
        financeLocalMoneyWithUnitSuffix(item.amount.toStringAsFixed(2)),
  ),
];
