import 'package:flutter/material.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../basic_data/models/reference_method_option.dart';
import '../config/finance_doc_config.dart';
import '../models/finance_doc.dart' show FinanceDocType;
import '../providers/finance_name_provider.dart';
import '../shared/finance_entry_capabilities.dart';
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
  final balanceColumn = EditableGridColumn<FinanceGridRow>(
    key: 'entryBalance',
    label: config.type == FinanceDocType.receipt ? '还欠' : '未结金额',
    headerInfo: config.type == FinanceDocType.receipt
        ? '所选出货批次当前尚欠的货款；填入本次收款不会提前扣减，审核后刷新核对。金额须按真实到账填写。'
        : '引用单据币种下尚未结清的金额。',
    width: 160,
    numeric: true,
    textOf: (row) => row.balanceOriginalText ?? '',
    listenableOf: (row) => row.entry,
    cellBuilder: (_, row) => Text(
      row.balanceOriginalText ?? '—',
      style:
          config.type == FinanceDocType.receipt &&
              (financeAmountUnits(row.balanceOriginalText) ?? BigInt.zero) >
                  BigInt.zero
          ? TextStyle(color: Theme.of(context).colorScheme.error)
          : null,
    ),
  );
  final currencyColumn = EditableGridColumn<FinanceGridRow>(
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
        hintText: '选择币种',
        info: financeEntryRequiresBaseCurrency(config)
            ? '这类单据按本位币入账；历史原币输入保留，不能作为新的外币入账。'
            : null,
        value: row.entry.currencyId,
        enabled: row.appliedLedgerId == null && row.entry.salesOrderId == null,
        items: [
          for (final currency in financeEntryCurrencyChoices(
            config,
            names,
          ).entries)
            UtenDropdownItem(value: currency.key, label: currency.value),
          if (row.entry.currencyId != null &&
              !financeEntryCurrencyChoices(
                config,
                names,
              ).containsKey(row.entry.currencyId))
            UtenDropdownItem(
              value: row.entry.currencyId,
              label: names.currency(row.entry.currencyId),
              enabled: false,
              visible: false,
            ),
        ],
        onChanged: (value) => changeCurrency(row, value),
      ),
    ),
  );
  final exchangeRateColumn = EditableGridColumn<FinanceGridRow>(
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
  );
  return [
    if (config.hasParty)
      picker(
        'entryParty',
        config.partyLabel,
        (row) => row.entry.partyId == null
            ? '选择${config.partyLabel}'
            : row.entry.partyName ??
                  (config.isClient
                      ? names.client(row.entry.partyId)
                      : names.supplier(row.entry.partyId)),
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
    // The cash amount is an essential entry fact. Keep it in the first screen;
    // optional quantity/price inputs retain their original shared calculator.
    if (config.isAllocate) ...[
      ...details.where((column) => column.key == 'amount'),
      currencyColumn,
      exchangeRateColumn,
    ],
    if (!config.isTransfer)
      EditableGridColumn<FinanceGridRow>(
        key: 'entryMethod',
        required: methods.isNotEmpty,
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
            hintText: config.isClient || config.type.name == 'otherIncome'
                ? '选择收款方式'
                : '选择付款方式',
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
    if (config.isClient && canPrepay)
      EditableGridColumn<FinanceGridRow>(
        key: 'entryKind',
        label: '收款类型',
        width: 220,
        textOf: (row) => row.entry.receiptKind == 'CUSTOMER_PREPAYMENT'
            ? '订单预收（定金/多付）'
            : '出货收款',
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
              UtenDropdownItem(value: 'AR_SETTLEMENT', label: '出货收款'),
              UtenDropdownItem(
                value: 'CUSTOMER_PREPAYMENT',
                label: '订单预收（定金/多付）',
              ),
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
        (row) => row.entry.receiptKind == 'CUSTOMER_PREPAYMENT'
            ? row.entry.salesOrderNo ?? '选订货单'
            : row.sourceDocNo ??
                  row.appliedBillNo ??
                  (config.isClient ? '选出货单' : '引用应付'),
        pickSource,
      ),
      if (config.type != FinanceDocType.receipt) balanceColumn,
    ],
    for (final column in details)
      if (!config.isAllocate && column.key == 'amount') ...[
        column,
        currencyColumn,
        exchangeRateColumn,
      ] else if (!{'remark', 'amount', 'currency'}.contains(column.key) &&
          !config.isSettle)
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
    // Preserve the original remark column before receipt-only appended money fields.
    if (details.any((column) => column.key == 'remark'))
      ...details.where((column) => column.key == 'remark')
    else
      financeRemarkColumn(),
    if (config.type == FinanceDocType.receipt) balanceColumn,
  ];
}
