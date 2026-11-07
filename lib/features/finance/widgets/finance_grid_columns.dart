import 'package:uten_imp/components/feedback/uten_date_range_picker.dart';
import '../../../core/formatters/exact_number_text.dart';
// 钱流单据明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// FinanceGridRow：统一承载 3 种模式的字段（settle 核销 / allocate 分摊 / transfer 转入）。
// 模式由 [ItemMode] 标记（行构造时绑定，不可切换）——与 FinanceDocConfig.itemMode 一致：
// - 三种模式：amount 列均为 TextField 直接录入 → amountNotifier 同步（驱动表尾合计）；
//   新建 allocate 行启用公共 LinePricingController；已有记录/旧草稿保留独立原文。
// 金额控制器原文是输入来源；amountNotifier 仅供短显示，不能回写会计事实。
//
// financeGridColumns(mode, ...)：按模式返回不同列集，每列 cellBuilder 编辑对应行字段。
// 列宽固定 + 横向滚动（UtenEditableGrid 自带 sticky 表头），全尺寸 Excel（与其它模块一致）。
import 'package:flutter/material.dart';
import '../../../components/data_display/uten_review_input_cell.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';

import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_multi_value_cell.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/theme/uten_tokens.dart';
import '../config/finance_doc_config.dart';
import '../models/finance_decimal.dart';
import '../models/finance_doc.dart';
import '../models/finance_entry_terms.dart';
import '../../../shared/pricing/line_pricing_controller.dart';
import '../providers/finance_name_provider.dart';
import '../shared/finance_entry_capabilities.dart';
import 'ar_ap_picker_dialog.dart';
import 'finance_entry_l10n.dart';
import 'finance_style_picker.dart';
import '../../../shared/widgets/uten_department_picker.dart';
import '../../../shared/models/accounting_expense_purpose.dart';

/// 钱流明细行（3 模式超集）。控制器/通知器在行内持有，跨重建存活。
class FinanceGridRow extends EditableGridRow with AmountRowMixin {
  FinanceGridRow({required this.mode}) {
    // 三种模式均：金额列直接录入 → 同步 amountNotifier（驱动合计）。
    // 新建数量/单价联动由 enableEntryPricing 显式启用。
    amount.addListener(_syncFromAmountField);
    exchangeRate.addListener(_syncFromAmountField);
    writeOff.addListener(_syncFromAmountField);
    _syncFromAmountField();
  }

  /// 该行的明细模式（构造时绑定，决定金额的来源）。
  final ItemMode mode;
  final entry = FinanceEntryTerms();
  LinePricingController? pricing;
  bool _syncingPricing = false;

  /// Existing recorded documents keep their historical independent inputs.
  /// New allocation rows share procurement's exact two-of-three calculator.
  void enableEntryPricing() {
    if (mode != ItemMode.allocate || pricing != null) return;
    final calculator = LinePricingController(
      qty: qty,
      price: price,
      supportsTotalInput: true,
    );
    pricing = calculator;
    calculator.totalAmount.addListener(_copyPricingAmount);
    amount.addListener(_copyEnteredAmount);
    if (amount.text.isNotEmpty) _copyEnteredAmount();
  }

  void _copyPricingAmount() {
    if (_syncingPricing) return;
    _syncingPricing = true;
    amount.text = pricing!.totalAmount.text;
    _syncingPricing = false;
  }

  void _copyEnteredAmount() {
    if (_syncingPricing) return;
    _syncingPricing = true;
    pricing!.totalAmount.text = amount.text;
    _syncingPricing = false;
  }

  // ---- settle（核销 receipt/payment）----
  String? appliedLedgerId;
  String? appliedBillNo;
  List<String> salesOrderIds = const [];
  String? authoritativeSalesOrderId;
  String? requestedSalesOrderId;
  String? sourceDocType;
  String? sourceDocNo;
  List<String> salesOrderNos = const [];
  String? currencyId;
  String? currencyCode;
  double? receivableOriginal;
  String? receivableOriginalText;
  double? receivedOriginal;
  String? receivedOriginalText;
  double? writtenOffOriginal;
  String? writtenOffOriginalText;
  double? balanceOriginal;
  String? balanceOriginalText;
  String? prepaymentAppliedOriginal;

  // ---- allocate（分摊 expense/otherIncome）----
  /// 费用/收入项目（expenseStyleId / incomeStyleId）。ValueNotifier 承载：
  /// 下拉选完单元格即时刷新，且列宽随所选名称自动加宽（textOf/listenableOf）。
  final ValueNotifier<String?> styleIdNotifier = ValueNotifier<String?>(null);
  final postingPurposeNotifier = ValueNotifier<AccountingExpensePurpose>(
    AccountingExpensePurpose.ordinaryExpense,
  );
  late final Listenable styleSelectionListenable = Listenable.merge([
    styleIdNotifier,
    postingPurposeNotifier,
  ]);
  AccountingExpensePurpose get postingPurpose => postingPurposeNotifier.value;
  set postingPurpose(AccountingExpensePurpose value) =>
      postingPurposeNotifier.value = value;
  String? get styleId => styleIdNotifier.value;
  set styleId(String? v) => styleIdNotifier.value = v;

  /// Optional UUID remains the persistence authority; labels never replace it.
  final TextEditingController department = TextEditingController();
  String? _departmentNameId;
  String? _departmentName;
  String? get departmentReferenceName =>
      _departmentNameId == department.text ? _departmentName : null;
  void setDepartment(String? id, String? name) {
    _departmentNameId = id ?? '';
    _departmentName = name;
    department.text = id ?? '';
  }

  // ---- transfer（转入 bankTransfer）----
  /// 转入账户。同 [styleId]：通知器承载，选完即时刷新 + 列宽自适应。
  final ValueNotifier<String?> inAccountIdNotifier = ValueNotifier<String?>(
    null,
  );
  String? get inAccountId => inAccountIdNotifier.value;
  set inAccountId(String? v) => inAccountIdNotifier.value = v;

  /// 转入行日期（yyyy-MM-dd）；ValueNotifier 让日期单元格点击后自动刷新。
  final ValueNotifier<String?> occurDateNotifier = ValueNotifier<String?>(null);
  String? get occurDate => occurDateNotifier.value;
  set occurDate(String? v) => occurDateNotifier.value = v;

  // ---- 公共 ----
  final TextEditingController qty = TextEditingController();
  final TextEditingController price = TextEditingController();

  /// settle/transfer：本次/转入金额录入；allocate：构造时透传初始计算结果（一般留空）。
  final TextEditingController amount = TextEditingController();
  final TextEditingController exchangeRate = TextEditingController();
  final TextEditingController writeOff = TextEditingController(text: '0');
  final TextEditingController remark = TextEditingController();
  String? originalAmountSnapshot;
  String? amountInputSnapshot;
  String? summarySnapshot;
  final ValueNotifier<double> localAmountNotifier = ValueNotifier<double>(0);
  final ValueNotifier<double> writeOffLocalNotifier = ValueNotifier<double>(0);
  final ValueNotifier<double> balanceAfterNotifier = ValueNotifier<double>(0);
  final ValueNotifier<String?> localAmountExactNotifier =
      ValueNotifier<String?>(null);
  final ValueNotifier<String?> balanceAfterExactNotifier =
      ValueNotifier<String?>(null);

  /// 「从应收应付引入」构造：核销台账 id + 单据号 + 本次核销额 预填。
  factory FinanceGridRow.fromApplied(ItemMode mode, AppliedArAp a) {
    final row = FinanceGridRow(mode: mode);
    try {
      row.applyLedger(a);
      return row;
    } catch (_) {
      row.dispose();
      rethrow;
    }
  }

  void applyLedger(AppliedArAp a) {
    if (a.clientId != null) {
      entry.partyId = a.clientId;
      entry.partyName = a.clientName;
    }
    final r = this
      ..appliedLedgerId = a.ledgerId
      ..appliedBillNo = a.appliedBillNo
      ..salesOrderIds = a.salesOrderIds
      ..authoritativeSalesOrderId = a.authoritativeSalesOrderId
      ..requestedSalesOrderId = a.requestedSalesOrderId
      ..sourceDocType = a.sourceDocType
      ..sourceDocNo = a.sourceDocNo
      ..salesOrderNos = a.salesOrderNos
      ..currencyId = a.currencyId
      ..currencyCode = a.currencyCode
      ..receivableOriginal = a.receivableOriginal
      ..receivableOriginalText = a.receivableOriginalText
      ..receivedOriginal = a.receivedOriginal
      ..receivedOriginalText = a.receivedOriginalText
      ..writtenOffOriginal = a.writtenOffOriginal
      ..writtenOffOriginalText = a.writtenOffOriginalText
      ..balanceOriginal = a.balanceOriginal;
    r.balanceOriginalText = a.balanceOriginalText;
    r.prepaymentAppliedOriginal = a.prepaymentAppliedOriginal;
    r.amount.text = a.receiptAmountText;
  }

  void _syncFromAmountField() {
    final cash = double.tryParse(amount.text) ?? 0;
    final rate = double.tryParse(exchangeRate.text) ?? 0;
    final offset = mode == ItemMode.settle
        ? (double.tryParse(writeOff.text) ?? 0)
        : 0;
    localAmountNotifier.value = cash * rate;
    writeOffLocalNotifier.value = offset * rate;
    balanceAfterNotifier.value = (balanceOriginal ?? 0) - cash - offset;
    recalcAmount(() => mode == ItemMode.settle ? cash + offset : cash);
    localAmountExactNotifier.value = financeExactMultiplyTexts([
      amount.text.trim(),
      exchangeRate.text.trim(),
    ]);
    final balanceUnits = financeAmountUnits(
      balanceOriginalText ?? balanceOriginal?.toString(),
    );
    final cashUnits = financeAmountUnits(amount.text.trim());
    balanceAfterExactNotifier.value = balanceUnits == null || cashUnits == null
        ? null
        : financeAmountFromUnits(balanceUnits - cashUnits);
  }

  /// 深拷贝（明细复制/粘贴用，allocate/transfer 模式）：拷用户录入（金额/数量/单价/
  /// 汇率/核销/备注/部门）与下拉/日期选择（费用/收入风格、转入账户、转入日期）。
  /// settle 台账绑定（appliedLedgerId 等）不拷——核销明细由「引用应收应付」生成，
  /// 该模式无增删行操作条与行菜单，正常到不了 clone。金额文本回填即触发
  /// [_syncFromAmountField]，amountNotifier/表尾合计自动同步。
  FinanceGridRow clone() {
    final c = FinanceGridRow(mode: mode)
      ..styleId = styleId
      ..postingPurpose = postingPurpose
      ..inAccountId = inAccountId
      ..occurDate = occurDate;
    c.setDepartment(department.text, departmentReferenceName);
    c.qty.text = qty.text;
    c.price.text = price.text;
    c.amount.text = amount.text;
    c.exchangeRate.text = exchangeRate.text;
    c.writeOff.text = writeOff.text;
    c.remark.text = remark.text;
    c.summarySnapshot = summarySnapshot;
    c.entry.restore(entry.toJson());
    if (pricing != null) {
      c.enableEntryPricing();
      c.pricing!.restoreState(pricing!.exportState());
    }
    return c;
  }

  @override
  void dispose() {
    pricing?.dispose();
    entry.dispose();
    qty.dispose();
    price.dispose();
    amount.dispose();
    exchangeRate.dispose();
    writeOff.dispose();
    remark.dispose();
    localAmountNotifier.dispose();
    writeOffLocalNotifier.dispose();
    balanceAfterNotifier.dispose();
    localAmountExactNotifier.dispose();
    balanceAfterExactNotifier.dispose();
    department.dispose();
    occurDateNotifier.dispose();
    styleIdNotifier.dispose();
    postingPurposeNotifier.dispose();
    inAccountIdNotifier.dispose();
    super.dispose();
  }
}

/// 按模式返回明细列集。
///
/// [names] 主档名称服务（提供项目/账户下拉选项，页面 build 时传入最新引用）。
/// [type] 当前单据类型（区分费用/收入项目标签）。
List<EditableGridColumn<FinanceGridRow>> financeGridColumns(
  ItemMode mode, {
  required BuildContext context,
  required FinanceNameService names,
  required FinanceDocType type,
  bool? accountBaseCurrency,
  bool showReceiptReconciliation = true,
  TextEditingController? bankReferenceController,
  Map<FinanceGridRow, Map<String, String?>>? reviewBaseline,
  String? documentCurrencyId,
}) {
  final documentCurrencyColumn = _financeCurrencyColumn(
    'currency',
    type == FinanceDocType.payment ? '付款币种' : '币种',
    (row) {
      final id = type == FinanceDocType.payment
          ? row.currencyId ?? documentCurrencyId
          : documentCurrencyId;
      return financeCurrencyText(
        name: id == null ? null : names.currency(id),
        code: type == FinanceDocType.payment ? row.currencyCode : null,
        fallback: '—',
      );
    },
  );
  final columns = switch (mode) {
    ItemMode.settle =>
      type == FinanceDocType.receipt
          ? _receiptSettleColumns(
              context,
              names,
              accountBaseCurrency: accountBaseCurrency,
              showReconciliation: showReceiptReconciliation,
              bankReferenceController: bankReferenceController,
            )
          : [..._settleColumns(), documentCurrencyColumn],
    ItemMode.allocate => [
      ..._allocateColumns(context, names, type),
      documentCurrencyColumn,
    ],
    ItemMode.transfer => [..._transferColumns(names), documentCurrencyColumn],
  };
  if (reviewBaseline == null) return columns;
  return [
    for (final column in columns)
      EditableGridColumn<FinanceGridRow>(
        key: column.key,
        label: column.label,
        width: column.width,
        minimumWidthOf: column.minimumWidthOf,
        numeric: column.numeric,
        defaultVisible: column.defaultVisible,
        exportDefinition: column.exportDefinition,
        exactValueOf: column.exactValueOf,
        exactListenableOf: column.exactListenableOf,
        required: column.required,
        headerInfo: column.headerInfo,
        textOf: column.textOf,
        listenableOf: column.listenableOf,
        filterValueOf: column.filterValueOf,
        columnSearchEnabled: column.columnSearchEnabled,
        frozenTextOf: column.frozenTextOf,
        chromeWidth: column.chromeWidth,
        chromeWidthOf: column.chromeWidthOf,
        fillsCellHeight: column.fillsCellHeight,
        cellColor: column.cellColor,
        cellColorListenableOf: column.cellColorListenableOf,
        legendOf: column.legendOf,
        reviewReasonOf: column.reviewReasonOf,
        aiSensitive: column.aiSensitive,
        cellBuilder: (context, row) {
          final before = reviewBaseline[row];
          if (before == null || !before.containsKey(column.key)) {
            return column.cellBuilder(context, row);
          }
          final listenable = switch (column.key) {
            'amount' => row.amount,
            'qty' => row.qty,
            'price' => row.price,
            'exchangeRate' => row.exchangeRate,
            'writeOff' => row.writeOff,
            'remark' => row.remark,
            'style' => row.styleIdNotifier,
            'department' => row.department,
            'inAccount' => row.inAccountIdNotifier,
            'occurDate' => row.occurDateNotifier,
            'bankReference' => bankReferenceController,
            _ => null,
          };
          if (listenable == null) return column.cellBuilder(context, row);
          return ListenableBuilder(
            listenable: listenable,
            builder: (context, _) => UtenReviewInputCell(
              before: before[column.key],
              after: financeGridReviewValues(
                row,
                names,
                type,
                bankReferenceController,
              )[column.key],
              beforeKey: ValueKey(
                'finance-review-before-${column.key}-${row.hashCode}',
              ),
              child: column.cellBuilder(context, row),
            ),
          );
        },
      ),
  ];
}

Map<String, String?> financeGridReviewValues(
  FinanceGridRow row,
  FinanceNameService names,
  FinanceDocType type,
  TextEditingController? bankReference,
) => {
  'amount': row.amount.text,
  'qty': row.qty.text,
  'price': row.price.text,
  'exchangeRate': row.exchangeRate.text,
  'writeOff': row.writeOff.text,
  'remark': row.remark.text,
  'style': type == FinanceDocType.expense
      ? names.expenseStyleName(row.styleId, row.postingPurpose)
      : names.styleName(row.styleId, 'INCOME'),
  if (type == FinanceDocType.expense)
    'postingPurpose': row.postingPurpose.label,
  'department': names.department(
    row.department.text,
    referencedName: row.departmentReferenceName,
  ),
  'inAccount': names.accountEntries[row.inAccountId],
  'occurDate': row.occurDate,
  'bankReference': bankReference?.text,
};

EditableGridColumn<FinanceGridRow> _financeCurrencyColumn(
  String key,
  String label,
  String Function(FinanceGridRow) valueOf, {
  bool required = false,
}) => EditableGridColumn<FinanceGridRow>(
  key: key,
  label: label,
  width: 90,
  required: required,
  textOf: valueOf,
  filterValueOf: valueOf,
  cellBuilder: (_, row) => Text(valueOf(row)),
);

// ===== settle：核销单据号（只读）+ 本次金额（录入）=====
List<EditableGridColumn<FinanceGridRow>> _receiptSettleColumns(
  BuildContext context,
  FinanceNameService names, {
  bool? accountBaseCurrency,
  required bool showReconciliation,
  TextEditingController? bankReferenceController,
}) {
  final columns = [
    EditableGridColumn<FinanceGridRow>(
      key: 'appliedBillNo',
      label: '出货单/原来源',
      headerInfo: '实际出货单号或已核验历史期初原来源；系统应收编号保留在核对明细，不编造订单或出货单。',
      width: 160,
      // 行 model 普通字段（AR 引入时随行回填）——只给 textOf，行集变化时整体量宽。
      textOf: (r) => r.sourceDocNo ?? r.appliedBillNo ?? '',
      cellBuilder: (context, row) => Text(
        row.sourceDocNo ?? row.appliedBillNo ?? '—',
        style: TextStyle(
          color: row.appliedBillNo == null
              ? Theme.of(context).colorScheme.onSurfaceVariant
              : Theme.of(context).colorScheme.onSurface,
        ),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'source',
      label: '应收编号/来源',
      headerInfo: '保留系统应收编号供核对；实际出货单或期初原来源在前一列，两个编号各保留其用途。',
      width: 200,
      // 单行省略号（2026-09-16 全站口径）+ 随文本自动加宽，不再折两行撑高整行。
      textOf: (row) =>
          '${financeArApSourceTypeLabel(row.sourceDocType)}'
          '${row.appliedBillNo?.trim().isNotEmpty == true ? ' · ${row.appliedBillNo}' : ''}',
      filterValueOf: (row) => financeArApSourceTypeLabel(row.sourceDocType),
      columnSearchEnabled: true,
      cellBuilder: (context, row) => Text(
        '${financeArApSourceTypeLabel(row.sourceDocType)}'
        '${row.appliedBillNo?.trim().isNotEmpty == true ? ' · ${row.appliedBillNo}' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'salesOrderNos',
      label: '销售订单号',
      width: 190,
      // textOf（导出/复制/编辑态）保留全量；屏幕格走多值截断+弹窗口径（2026-10-29）。
      textOf: (row) =>
          row.salesOrderNos.isEmpty ? '—' : row.salesOrderNos.join('、'),
      cellBuilder: (context, row) =>
          UtenMultiValueCell(values: row.salesOrderNos, title: '销售订单号'),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'receivableOriginal',
      label: '应收总额',
      width: 110,
      numeric: true,
      frozenTextOf: (row) =>
          row.receivableOriginalText ?? _money(row.receivableOriginal),
      cellBuilder: (context, row) =>
          Text(_moneyExact(row.receivableOriginalText, row.receivableOriginal)),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'receivedOriginal',
      label: '累计已收',
      width: 110,
      numeric: true,
      frozenTextOf: (row) =>
          row.receivedOriginalText ?? _money(row.receivedOriginal),
      cellBuilder: (context, row) =>
          Text(_moneyExact(row.receivedOriginalText, row.receivedOriginal)),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'writtenOffOriginal',
      label: '累计冲销',
      width: 110,
      numeric: true,
      frozenTextOf: (row) =>
          row.writtenOffOriginalText ?? _money(row.writtenOffOriginal),
      cellBuilder: (context, row) =>
          Text(_moneyExact(row.writtenOffOriginalText, row.writtenOffOriginal)),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'prepaymentAppliedOriginal',
      label: '预收已抵',
      width: 110,
      numeric: true,
      frozenTextOf: (row) => row.prepaymentAppliedOriginal ?? '0.00',
      cellBuilder: (context, row) =>
          Text(row.prepaymentAppliedOriginal ?? '0.00'),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'exchangeRate',
      label: '批次汇率',
      width: 190,
      numeric: true,
      textOf: (row) => row.exchangeRate.text,
      listenableOf: (row) => row.exchangeRate,
      cellBuilder: (context, row) => ValueListenableBuilder<TextEditingValue>(
        valueListenable: row.exchangeRate,
        builder: (_, value, _) => Text(
          value.text.trim().isEmpty ? '待填写' : value.text.trim(),
          style: TextStyle(
            color: value.text.trim().isEmpty
                ? Theme.of(context).colorScheme.error
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'balanceOriginal',
      label: financeEntryText(context, 'availableOriginalColumn'),
      width: 110,
      numeric: true,
      frozenTextOf: (row) =>
          row.balanceOriginalText ?? _money(row.balanceOriginal),
      cellBuilder: (context, row) => Text(
        _moneyExact(row.balanceOriginalText, row.balanceOriginal),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'amount',
      label: '本次收款',
      width: 220,
      numeric: true,
      frozenTextOf: (row) => row.amount.text,
      listenableOf: (row) => row.amount,
      required: true,
      // 列说明挂表头 ⓘ（2026-09-09 口径）：不再逐格渲染重复 ⓘ。
      headerInfo: workflowFieldText(context).workflowReceiptAllocationHint,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.amount,
        isEmpty: () {
          final units = financeAmountUnits(row.amount.text.trim());
          return units == null || units <= BigInt.zero;
        },
        child: TextField(
          controller: row.amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const UtenInputDecoration(
            InputDecoration(isDense: true, labelText: '本次收款'),
          ),
        ),
      ),
    ),
    _financeCurrencyColumn(
      'currency',
      '应收币种',
      (row) => financeCurrencyText(
        name: row.currencyId == null ? null : names.currency(row.currencyId),
        code: row.currencyCode,
        fallback: '—',
      ),
      required: true,
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'amountLocal',
      label: financeEntryText(context, 'convertedCnyColumn'),
      width: 170,
      numeric: true,
      exactValueOf: (row) => row.localAmountExactNotifier.value,
      exactListenableOf: (row) => row.localAmountExactNotifier,
      headerInfo: financeEntryText(context, 'convertedCnyHint'),
      textOf: (row) =>
          financeExactMoneyDisplay(row.localAmountExactNotifier.value),
      listenableOf: (row) => row.localAmountExactNotifier,
      cellBuilder: (context, row) => ValueListenableBuilder<String?>(
        valueListenable: row.localAmountExactNotifier,
        builder: (_, value, _) => Text(financeExactMoneyDisplay(value)),
      ),
    ),
    _financeCurrencyColumn(
      'localCurrency',
      '本位币',
      (_) => financeCurrencyText(name: names.baseCurrencyName, fallback: '—'),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'balanceAfter',
      label: financeEntryText(context, 'remainingOriginalColumn'),
      width: 120,
      numeric: true,
      frozenTextOf: (row) => row.balanceAfterExactNotifier.value ?? '—',
      listenableOf: (row) => row.balanceAfterExactNotifier,
      cellBuilder: (context, row) => ValueListenableBuilder<String?>(
        valueListenable: row.balanceAfterExactNotifier,
        builder: (_, value, _) {
          final units = financeAmountUnits(value);
          return Text(
            financeExactMoneyDisplay(value),
            style: TextStyle(
              color: units != null && units < BigInt.zero
                  ? Theme.of(context).colorScheme.error
                  : null,
              fontWeight: FontWeight.w600,
            ),
          );
        },
      ),
    ),
    if (bankReferenceController != null)
      EditableGridColumn<FinanceGridRow>(
        key: 'bankReference',
        label: financeEntryText(context, 'bankReferenceColumn'),
        width: 220,
        headerInfo: financeEntryText(context, 'batchBankReferenceHint'),
        // The document owns this controller. Each row edits the same bank
        // transaction reference; removing a row must not dispose it.
        textOf: (_) => bankReferenceController.text,
        listenableOf: (_) => bankReferenceController,
        cellBuilder: (context, _) => TextField(
          key: const ValueKey('finance-receipt-bank-reference'),
          controller: bankReferenceController,
          decoration: UtenInputDecoration(
            InputDecoration(
              isDense: true,
              labelText: financeEntryText(context, 'bankReferenceColumn'),
            ),
          ),
        ),
      ),
    financeRemarkColumn(),
  ];
  if (showReconciliation) return columns;
  // Only presentation changes: rows retain source UUIDs, reconciliation
  // snapshots and rate listeners, and save still validates every authority.
  const entryKeys = {
    'appliedBillNo',
    'currency',
    'balanceOriginal',
    'amount',
    'amountLocal',
    'localCurrency',
    'balanceAfter',
    'bankReference',
    'remark',
  };
  return columns.where((column) => entryKeys.contains(column.key)).toList();
}

/// The trailing editable remark uses the same controller and presentation in
/// single-document, grouped-entry and review grids.
EditableGridColumn<FinanceGridRow> financeRemarkColumn() =>
    EditableGridColumn<FinanceGridRow>(
      key: 'remark',
      label: '备注',
      width: 180,
      textOf: (row) => row.remark.text,
      listenableOf: (row) => row.remark,
      cellBuilder: (context, row) => TextField(
        controller: row.remark,
        decoration: const UtenInputDecoration(
          InputDecoration(isDense: true, labelText: '备注'),
        ),
      ),
    );

String _money(double? value) =>
    value == null ? '—' : value.toExactString(minimumFractionDigits: 2);

String _moneyExact(String? text, double? fallback) =>
    text == null ? _money(fallback) : financeExactMoneyDisplay(text);

List<EditableGridColumn<FinanceGridRow>> _settleColumns() {
  return [
    EditableGridColumn<FinanceGridRow>(
      key: 'appliedBillNo',
      label: '应付单号',
      width: 260,
      textOf: (r) => r.appliedBillNo ?? '',
      cellBuilder: (context, row) => Text(
        row.appliedBillNo ?? '直接付款(未指定核销)',
        style: TextStyle(
          color: row.appliedBillNo == null
              ? Theme.of(context).colorScheme.onSurfaceVariant
              : Theme.of(context).colorScheme.onSurface,
        ),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'amount',
      label: financePaymentOriginalAmountLabel,
      width: 180,
      numeric: true,
      frozenTextOf: (row) => row.amount.text,
      listenableOf: (row) => row.amount,
      required: true,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.amount,
        isEmpty: () => (double.tryParse(row.amount.text.trim()) ?? 0) <= 0,
        child: TextField(
          controller: row.amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const UtenInputDecoration(
            InputDecoration(
              isDense: true,
              labelText: financePaymentOriginalAmountLabel,
            ),
          ),
        ),
      ),
    ),
  ];
}

// ===== allocate：项目 + 部门 + 数量 + 单价 + 金额(自动) =====
List<EditableGridColumn<FinanceGridRow>> _allocateColumns(
  BuildContext context,
  FinanceNameService names,
  FinanceDocType type,
) {
  final cat = type == FinanceDocType.expense ? 'EXPENSE' : 'INCOME';
  // 所选项目的展示名（格内值与列宽测量共用同一份，所见即所量）。
  String styleLabelOf(FinanceGridRow row) {
    final styles = type == FinanceDocType.expense
        ? names.expenseStylesFor(row.postingPurpose)
        : names.stylesFor(cat);
    for (final s in styles) {
      if (s.id == row.styleId) return s.name ?? s.id;
    }
    return row.styleId ?? '';
  }

  return [
    if (type == FinanceDocType.expense)
      EditableGridColumn<FinanceGridRow>(
        key: 'postingPurpose',
        label: '支出类型',
        width: 150,
        textOf: (r) => r.postingPurpose.label,
        listenableOf: (r) => r.postingPurposeNotifier,
        cellBuilder: (_, row) => UtenDropdownField(
          dense: true,
          value: row.postingPurpose.apiValue,
          items: [
            for (final p in AccountingExpensePurpose.values)
              UtenDropdownItem(value: p.apiValue, label: p.label),
          ],
          onChanged: (value) {
            if (value == null) return;
            row.postingPurpose = AccountingExpensePurpose.fromApi(value);
            row.styleId = null;
            if (row.postingPurpose ==
                AccountingExpensePurpose.manufacturingCost) {
              names.loadStyleCategory(row.postingPurpose.apiValue, force: true);
            }
          },
        ),
      ),
    EditableGridColumn<FinanceGridRow>(
      key: 'style',
      required: true,
      label: type == FinanceDocType.expense ? '费用项目' : '收入项目',
      width: 200,
      // 随所选名称自动加宽（2026-09-16）：此前不接 textOf，选完长名称既不撑列
      // 又折成两行把整行撑高。展开箭头(20)一并计入。
      textOf: (row) => styleLabelOf(row),
      listenableOf: (row) => row.styleSelectionListenable,
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, row) => ListenableBuilder(
        listenable: row.styleSelectionListenable,
        builder: (context, _) => FinanceStylePicker(
          names: names,
          category: cat,
          postingPurpose: type == FinanceDocType.expense
              ? row.postingPurpose
              : null,
          dense: true,
          value: row.styleId,
          onChanged: (value) => row.styleId = value,
        ),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'department',
      label: '部门',
      width: 200,
      textOf: (row) => names.department(
        row.department.text,
        referencedName: row.departmentReferenceName,
      ),
      listenableOf: (row) => row.department,
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      chromeWidthOf: (context) =>
          UtenEditableGridCellSpec.dropdownChevronWidth +
          (names.departmentLoadError == null
              ? 0
              : UtenControlMetrics.minimumHitExtent(context, desktop: 32)),
      cellBuilder: (context, row) => ValueListenableBuilder<TextEditingValue>(
        valueListenable: row.department,
        builder: (context, value, _) => Row(
          children: [
            Expanded(
              child: UtenDepartmentPicker(
                mode: UtenDepartmentPickerMode.single,
                // dense：选择格统一规格，与同行数量/单价等输入格同高（2026-10-08
                // 表格输入格统一口径）。
                dense: true,
                hint: '请选择部门(可空)',
                enabled: names.departmentTree != null,
                treeOverride: names.departmentTree ?? const [],
                allowClear: true,
                initialSelection: value.text.isEmpty
                    ? const []
                    : [
                        DeptSelection(
                          id: value.text,
                          name: names.department(
                            value.text,
                            referencedName: row.departmentReferenceName,
                          ),
                          fullPath: '',
                          level: '',
                        ),
                      ],
                onChanged: (selection) => row.setDepartment(
                  selection.firstOrNull?.id,
                  selection.firstOrNull?.name,
                ),
              ),
            ),
            if (names.departmentLoadError != null)
              IconButton(
                tooltip: '${names.departmentLoadError} 点击重试',
                // 重试与部门选择是不同操作；独立槽同源估宽，触摸不能缩成图标大小。
                style: IconButton.styleFrom(
                  minimumSize: Size.square(
                    UtenControlMetrics.minimumHitExtent(context, desktop: 32),
                  ),
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.standard,
                ),
                iconSize: 16,
                onPressed: () => names.ensureDepartmentsLoaded(),
                icon: const Icon(Icons.refresh),
              ),
          ],
        ),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'qty',
      label: '数量',
      width: 96,
      numeric: true,
      frozenTextOf: (row) => row.qty.text,
      listenableOf: (row) => row.qty,
      cellBuilder: (context, row) => TextField(
        controller: row.qty,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const UtenInputDecoration(
          InputDecoration(isDense: true, labelText: '数量'),
        ),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'price',
      label: '单价',
      width: 96,
      numeric: true,
      frozenTextOf: (row) => row.price.text,
      listenableOf: (row) => row.price,
      cellBuilder: (context, row) => TextField(
        controller: row.price,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const UtenInputDecoration(
          InputDecoration(isDense: true, labelText: '单价'),
        ),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'amount',
      label: '金额',
      width: 120,
      numeric: true,
      frozenTextOf: (row) => row.amount.text,
      listenableOf: (row) => row.amount,
      required: true,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.amount,
        isEmpty: () => (double.tryParse(row.amount.text.trim()) ?? 0) <= 0,
        child: TextField(
          controller: row.amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const UtenInputDecoration(
            InputDecoration(isDense: true, labelText: '金额'),
          ),
        ),
      ),
    ),
  ];
}

// ===== transfer：转入账户 + 日期 + 金额（录入）=====
List<EditableGridColumn<FinanceGridRow>> _transferColumns(
  FinanceNameService names,
) {
  final accounts = {
    for (final account in financeEntryAccountChoices(
      FinanceDocConfig.bankTransfer,
      names,
    ))
      account.id:
          names.accountEntries[account.id] ?? account.name ?? account.id,
  };
  return [
    EditableGridColumn<FinanceGridRow>(
      key: 'inAccount',
      label: '转入账户',
      width: 200,
      // 同费用项目列：选完随账户名自动加宽（含展开箭头），不再折行撑高整行。
      textOf: (row) => row.inAccountId == null
          ? ''
          : (names.accountEntries[row.inAccountId] ?? row.inAccountId!),
      listenableOf: (row) => row.inAccountIdNotifier,
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, row) => ValueListenableBuilder<String?>(
        valueListenable: row.inAccountIdNotifier,
        builder: (context, value, _) => UtenDropdownField(
          dense: true,
          label: '转入账户',
          value: value,
          items: [
            for (final e in accounts.entries)
              UtenDropdownItem(value: e.key, label: e.value),
            if (value != null &&
                value.isNotEmpty &&
                !accounts.containsKey(value))
              UtenDropdownItem(
                value: value,
                label: names.accountEntries[value] ?? value,
                enabled: false,
                visible: false,
              ),
          ],
          onChanged: (value) => row.inAccountId = value,
        ),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'occurDate',
      label: '日期',
      width: 150,
      required: true,
      filterValueOf: (row) {
        final value = row.occurDate;
        return value == null
            ? null
            : value.length >= 10
            ? value.substring(0, 10)
            : value;
      },
      listenableOf: (row) => row.occurDateNotifier,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.occurDateNotifier,
        isEmpty: () => row.occurDate == null,
        child: ValueListenableBuilder<String?>(
          valueListenable: row.occurDateNotifier,
          builder: (context, v, _) => InkWell(
            onTap: () async {
              final picked = await showUtenDatePicker(
                context: context,
                initialDate: v == null
                    ? ChinaDateTime.today()
                    : (DateTime.tryParse(v) ?? ChinaDateTime.today()),
                firstDate: DateTime(2010),
                lastDate: DateTime(2100),
              );
              if (picked != null) {
                row.occurDate =
                    '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
              }
            },
            child: InputDecorator(
              // 选择格统一内边距（2026-10-06 表格控件统一口径）。
              decoration: InputDecoration(
                isDense: true,
                contentPadding: UtenEditableGridCellSpec.contentPaddingOf(
                  context,
                ),
              ),
              child: Text(
                v == null ? '日期' : v.substring(0, 10),
                style: TextStyle(
                  color: v == null
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'amount',
      label: '金额',
      width: 140,
      numeric: true,
      frozenTextOf: (row) => row.amount.text,
      listenableOf: (row) => row.amount,
      required: true,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.amount,
        isEmpty: () => (double.tryParse(row.amount.text.trim()) ?? 0) <= 0,
        child: TextField(
          controller: row.amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const UtenInputDecoration(
            InputDecoration(isDense: true, labelText: '金额'),
          ),
        ),
      ),
    ),
  ];
}
