import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/rmb_amount.dart';
import '../../../shared/platform_tables/platform_table_binding.dart';
import '../models/expense_item.dart';

/// Raw controllers are the draft authority, including invalid decimal text.
/// Conversion to the business input happens only after all rows validate.
class ExpenseGridRow extends EditableGridRow with AmountRowMixin {
  ExpenseGridRow({String? id}) : id = id ?? const Uuid().v4() {
    amount.addListener(_recalculate);
    description.addListener(_clearFlag);
    category.addListener(_clearFlag);
    date.addListener(_clearFlag);
  }
  final String id;
  final amount = TextEditingController();
  final description = TextEditingController();
  final category = ValueNotifier<ExpenseCategory>(ExpenseCategory.transport);
  final date = ValueNotifier<DateTime>(ChinaDateTime.today());
  int? get amountCents => parseExpenseAmountCents(amount.text);
  Iterable<Listenable> get draftListenables => [
    amount,
    description,
    category,
    date,
    platformFields,
  ];
  void _clearFlag() {
    if (flagged) flagged = false;
  }

  void _recalculate() {
    _clearFlag();
    recalcAmount(() => (amountCents ?? 0) / 100);
  }

  factory ExpenseGridRow.fromItem(ExpenseItem item, {bool persisted = false}) {
    final row = ExpenseGridRow(id: item.id)..applyItem(item);
    row.platformFields.sourceRecordId = persisted ? item.id : null;
    return row;
  }
  void applyItem(ExpenseItem item) {
    category.value = item.category;
    date.value = item.date;
    amount.text = item.amount.toStringAsFixed(2);
    description.text = item.description ?? '';
  }

  factory ExpenseGridRow.restore(
    Map<String, dynamic> data, {
    required String id,
  }) {
    final row = ExpenseGridRow(id: id);
    row.amount.text =
        data['amountText']?.toString() ?? data['amount']?.toString() ?? '';
    row.description.text = data['description']?.toString() ?? '';
    row.category.value = ExpenseCategory.fromApi(data['category']);
    row.date.value =
        DateTime.tryParse(data['date']?.toString() ?? '') ??
        ChinaDateTime.today();
    row.platformFields.restoreDraft(data['platformFieldDraft']);
    return row;
  }
  Map<String, dynamic> exportDraft() => {
    'id': id,
    'category': category.value.apiValue,
    'date': _date(date.value),
    'amount': (amountCents ?? 0) / 100,
    'amountText': amount.text,
    'description': description.text,
    'platformFieldDraft': platformFields.exportDraft(),
  };
  ({String column, String message})? get validationError {
    if (amountCents == null) {
      return (column: 'amount', message: '请填写有效金额，最多两位小数且大于零');
    }
    final today = ChinaDateTime.today();
    if (DateTime.utc(
      date.value.year,
      date.value.month,
      date.value.day,
    ).isAfter(DateTime.utc(today.year, today.month, today.day))) {
      return (column: 'date', message: '费用发生日期不能晚于今天');
    }
    if (description.text.trim().isEmpty ||
        description.text.trim().length > 500) {
      return (column: 'description', message: '请填写用途说明，最多500字');
    }
    return null;
  }

  ExpenseItem toItem() => ExpenseItem(
    id: id,
    category: category.value,
    amount: (amountCents ?? 0) / 100,
    date: date.value,
    description: description.text.trim(),
  );
  ExpenseGridRow clone() {
    final row = ExpenseGridRow();
    row.category.value = category.value;
    row.date.value = date.value;
    row.amount.text = amount.text;
    row.description.text = description.text;
    row.platformFields.copyFrom(platformFields);
    return row;
  }

  @override
  void dispose() {
    amount.dispose();
    description.dispose();
    category.dispose();
    date.dispose();
    super.dispose();
  }
}

class ExpenseEditableItems extends StatelessWidget {
  const ExpenseEditableItems({
    super.key,
    required this.controller,
    required this.editable,
    this.footer,
  });
  final UtenEditableGridController<ExpenseGridRow> controller;
  final bool editable;
  final Widget? footer;
  @override
  Widget build(BuildContext context) => UtenEditableGrid<ExpenseGridRow>(
    controller: controller,
    tableKey: 'expense.claim.items',
    platformBinding: PlatformTableBinding<ExpenseGridRow>(
      tableKey: 'expense.claim.items',
      scope: 'expense_claim_item',
      recordIdOf: (row) => row.platformFields.sourceRecordId,
      canEditValues: editable,
      canEditRow: (_) => editable,
      draftOf: (row) => row.platformFields,
      factValuesOf: (row) => {'amount': row.amount.text},
      factListenablesOf: (row) => [row.amount],
    ),
    createBlankRow: ExpenseGridRow.new,
    cloneRow: (row) => row.clone(),
    showAddRow: editable,
    showRowDelete: editable,
    selectionEnabled: editable,
    columnEditingEnabled: editable,
    addRowLabel: '添加费用',
    addRowsLabel: '添加多条费用',
    emptyMessage: '暂无费用明细',
    footer: footer,
    columns: [
      EditableGridColumn<ExpenseGridRow>(
        key: 'category',
        label: '费用科目',
        width: 150,
        required: true,
        textOf: (row) => row.category.value.label,
        listenableOf: (row) => row.category,
        cellBuilder: (_, row) => ValueListenableBuilder<ExpenseCategory>(
          valueListenable: row.category,
          builder: (_, value, _) => UtenDropdownField(
            label: '费用科目',
            value: value.apiValue,
            dense: true,
            items: [
              for (final category in ExpenseCategory.values)
                UtenDropdownItem(
                  value: category.apiValue,
                  label: category.label,
                ),
            ],
            enabled: editable,
            onChanged: (value) {
              if (editable && value != null) {
                row.category.value = ExpenseCategory.fromApi(value);
              }
            },
          ),
        ),
      ),
      EditableGridColumn<ExpenseGridRow>(
        key: 'date',
        label: '日期',
        width: 160,
        required: true,
        textOf: (row) => _date(row.date.value),
        listenableOf: (row) => row.date,
        cellBuilder: (_, row) => ValueListenableBuilder<DateTime>(
          valueListenable: row.date,
          builder: (_, value, _) => UtenDateField(
            label: '日期',
            value: value,
            enabled: editable,
            firstDate: DateTime.utc(2000),
            lastDate: ChinaDateTime.today(),
            onChanged: (value) => row.date.value = value,
          ),
        ),
      ),
      EditableGridColumn<ExpenseGridRow>(
        key: 'description',
        label: '说明',
        width: 360,
        required: true,
        textOf: (row) => row.description.text,
        listenableOf: (row) => row.description,
        headerInfo: '逐条填写费用用途；原始凭证在保存后补充，同一笔费用不要重复登记。',
        cellBuilder: (_, row) => RequiredCellFrame(
          listenable: row.description,
          isEmpty: () => row.description.text.trim().isEmpty,
          child: TextField(
            controller: row.description,
            enabled: editable,
            maxLength: 500,
            decoration: const UtenInputDecoration(
              InputDecoration(
                labelText: '用途说明',
                isDense: true,
                counterText: '',
              ),
            ),
          ),
        ),
      ),
      EditableGridColumn<ExpenseGridRow>(
        key: 'amount',
        label: '金额',
        width: 170,
        required: true,
        numeric: true,
        headerInfo: '人民币金额最多两位小数，按整数分校验与汇总；保存以服务端重新计算为准。',
        textOf: (row) => row.amount.text,
        listenableOf: (row) => row.amount,
        exactValueOf: (row) => row.amount.text,
        exactListenableOf: (row) => row.amount,
        cellBuilder: (_, row) => RequiredCellFrame(
          listenable: row.amount,
          isEmpty: () => row.amountCents == null,
          child: TextField(
            controller: row.amount,
            enabled: editable,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const UtenInputDecoration(
              InputDecoration(labelText: '金额', suffixText: '元', isDense: true),
            ),
          ),
        ),
      ),
    ],
  );
}

String _date(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
