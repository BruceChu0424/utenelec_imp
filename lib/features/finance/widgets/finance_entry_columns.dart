import 'package:flutter/material.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../basic_data/models/reference_method_option.dart';
import '../config/finance_doc_config.dart';
import '../providers/finance_name_provider.dart';
import 'finance_grid_columns.dart';

List<EditableGridColumn<FinanceGridRow>> financeEntryColumns({
  required BuildContext context,
  required FinanceDocConfig config,
  required FinanceNameService names,
  required List<ReferenceMethodOption> methods,
  required bool canPrepay,
  required Future<void> Function(FinanceGridRow) pickParty,
  required Future<void> Function(FinanceGridRow) pickAccount,
  required Future<void> Function(FinanceGridRow) pickSource,
  required Future<void> Function(FinanceGridRow) settings,
  required void Function(FinanceGridRow, String?) changeCurrency,
}) {
  EditableGridColumn<FinanceGridRow> picker(
    String key,
    String label,
    String Function(FinanceGridRow) text,
    Future<void> Function(FinanceGridRow) pick,
  ) => EditableGridColumn<FinanceGridRow>(
    key: key,
    label: label,
    width: 210,
    required: true,
    textOf: text,
    listenableOf: (row) => row.entry,
    cellBuilder: (_, row) => ListenableBuilder(
      listenable: row.entry,
      builder: (_, _) => UtenButton(
        type: UtenButtonType.secondary,
        size: UtenButtonSize.small,
        onPressed: () => pick(row),
        child: Text(text(row)),
      ),
    ),
  );
  final details = financeGridColumns(
    config.itemMode,
    context: context,
    names: names,
    type: config.type,
  );
  return [
    if (config.hasParty)
      picker(
        'entryParty',
        config.partyLabel,
        (row) => row.entry.partyId == null
            ? '选择${config.partyLabel}'
            : config.isClient
            ? names.client(row.entry.partyId)
            : names.supplier(row.entry.partyId),
        pickParty,
      ),
    picker(
      'entryAccount',
      config.accountLabel,
      (row) => row.entry.accountId == null
          ? '选择${config.accountLabel}'
          : names.account(row.entry.accountId),
      pickAccount,
    ),
    if (!config.isTransfer)
      EditableGridColumn<FinanceGridRow>(
        key: 'entryMethod',
        label: config.isClient || config.type.name == 'otherIncome'
            ? '收款方式'
            : '付款方式',
        width: 165,
        textOf: (row) =>
            methods
                .where((method) => method.id == row.entry.methodId)
                .firstOrNull
                ?.name ??
            '',
        listenableOf: (row) => row.entry,
        cellBuilder: (_, row) => ListenableBuilder(
          listenable: row.entry,
          builder: (_, _) => UtenDropdownField(
            dense: true,
            value: row.entry.methodId,
            items: [
              for (final method in methods)
                UtenDropdownItem(value: method.id, label: method.name),
            ],
            onChanged: (value) {
              row.entry.methodId = value;
              row.entry.touch();
            },
          ),
        ),
      ),
    EditableGridColumn<FinanceGridRow>(
      key: 'entryCurrency',
      label: '币种',
      width: 145,
      required: true,
      textOf: (row) => names.currency(row.entry.currencyId),
      listenableOf: (row) => row.entry,
      cellBuilder: (_, row) => ListenableBuilder(
        listenable: row.entry,
        builder: (_, _) => UtenDropdownField(
          dense: true,
          value: row.entry.currencyId,
          enabled:
              row.appliedLedgerId == null && row.entry.salesOrderId == null,
          items: [
            for (final currency in names.currencyEntries.entries)
              UtenDropdownItem(value: currency.key, label: currency.value),
          ],
          onChanged: (value) => changeCurrency(row, value),
        ),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'exchangeRate',
      label: '汇率',
      width: 125,
      numeric: true,
      required: true,
      textOf: (row) => row.exchangeRate.text,
      listenableOf: (row) => row.exchangeRate,
      cellBuilder: (_, row) => ListenableBuilder(
        listenable: row.entry,
        builder: (_, _) => TextField(
          controller: row.exchangeRate,
          readOnly: names.currencyIsBase(row.entry.currencyId) == true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const UtenInputDecoration(
            InputDecoration(isDense: true, labelText: '汇率'),
          ),
        ),
      ),
    ),
    if (config.isClient && canPrepay)
      EditableGridColumn<FinanceGridRow>(
        key: 'entryKind',
        label: '收款类型',
        width: 170,
        textOf: (row) =>
            row.entry.receiptKind == 'CUSTOMER_PREPAYMENT' ? '订单预收' : '应收核销',
        listenableOf: (row) => row.entry,
        cellBuilder: (_, row) => ListenableBuilder(
          listenable: row.entry,
          builder: (_, _) => UtenDropdownField(
            dense: true,
            allowClear: false,
            value: row.entry.receiptKind,
            enabled:
                row.appliedLedgerId == null && row.entry.salesOrderId == null,
            items: const [
              UtenDropdownItem(value: 'AR_SETTLEMENT', label: '应收核销'),
              UtenDropdownItem(value: 'CUSTOMER_PREPAYMENT', label: '订单预收'),
            ],
            onChanged: (value) {
              row.entry.receiptKind = value ?? 'AR_SETTLEMENT';
              row.entry.touch();
            },
          ),
        ),
      ),
    if (config.isSettle) ...[
      picker(
        'entrySource',
        '引用单据',
        (row) =>
            row.entry.salesOrderNo ??
            row.appliedBillNo ??
            (row.entry.receiptKind == 'CUSTOMER_PREPAYMENT'
                ? '选择销售订单'
                : config.isClient
                ? '引用应收'
                : '引用应付'),
        pickSource,
      ),
      EditableGridColumn<FinanceGridRow>(
        key: 'entryBalance',
        label: '未结金额',
        headerInfo: '引用单据币种下尚未结清的金额。',
        width: 160,
        numeric: true,
        textOf: (row) => row.balanceOriginalText ?? '',
        listenableOf: (row) => row.entry,
        cellBuilder: (_, row) => Text(row.balanceOriginalText ?? '—'),
      ),
    ],
    for (final column in details)
      if (column.key != 'remark' &&
          (config.isAllocate || config.isTransfer
              ? !{'exchangeRate', 'amountLocal'}.contains(column.key)
              : column.key == 'amount'))
        column,
    if (config.isSettle) ...[
      EditableGridColumn<FinanceGridRow>(
        key: 'entryBankReference',
        label: '流水号（选填）',
        width: 190,
        textOf: (row) => row.entry.bankReference.text,
        listenableOf: (row) => row.entry.bankReference,
        cellBuilder: (_, row) => TextField(
          controller: row.entry.bankReference,
          maxLength: 128,
          decoration: const UtenInputDecoration(
            InputDecoration(
              isDense: true,
              counterText: '',
              labelText: '流水号（选填）',
            ),
          ),
        ),
      ),
      EditableGridColumn<FinanceGridRow>(
        key: 'entrySettings',
        label: '结算设置',
        width: 130,
        cellBuilder: (_, row) => UtenButton(
          type: UtenButtonType.secondary,
          size: UtenButtonSize.small,
          icon: Icons.tune_rounded,
          onPressed: () => settings(row),
          child: const Text('设置'),
        ),
      ),
    ],
    // Keep the same trailing remark column for all five document types.
    if (details.any((column) => column.key == 'remark'))
      ...details.where((column) => column.key == 'remark')
    else
      financeRemarkColumn(),
  ];
}
