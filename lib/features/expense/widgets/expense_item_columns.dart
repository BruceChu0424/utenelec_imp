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
  MasterColumnDef(
    key: 'amount',
    label: '金额',
    width: 120,
    type: 'money',
    value: (item) => item.amount.toStringAsFixed(2),
  ),
];
