// 钱流单据明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// FinanceGridRow：统一承载 3 种模式的字段（settle 核销 / allocate 分摊 / transfer 转入）。
// 模式由 [ItemMode] 标记（行构造时绑定，不可切换）——与 FinanceDocConfig.itemMode 一致：
// - 三种模式：amount 列均为 TextField 直接录入 → amountNotifier 同步（驱动表尾合计）；
//   allocate 的数量/单价为可选明细字段，不强制驱动金额（与老页面一致：金额独立可编辑）。
// 金额控制器原文是输入来源；amountNotifier 仅供短显示，不能回写会计事实。
//
// financeGridColumns(mode, ...)：按模式返回不同列集，每列 cellBuilder 编辑对应行字段。
// 列宽固定 + 横向滚动（UtenEditableGrid 自带 sticky 表头），全尺寸 Excel（与其它模块一致）。
import 'package:flutter/material.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';

import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/utils/currency_display.dart';
import '../../../core/utils/china_datetime.dart';
import '../config/finance_doc_config.dart';
import '../models/finance_decimal.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import 'ar_ap_picker_dialog.dart';
import 'finance_entry_l10n.dart';
import '../../department/widgets/uten_department_picker.dart';

/// 钱流明细行（3 模式超集）。控制器/通知器在行内持有，跨重建存活。
class FinanceGridRow extends EditableGridRow with AmountRowMixin {
  FinanceGridRow({required this.mode}) {
    // 三种模式均：金额列直接录入 → 同步 amountNotifier（驱动合计）。
    // allocate 的数量/单价为可选明细字段，不强制驱动金额（与老页面一致：金额独立可编辑）。
    amount.addListener(_syncFromAmountField);
    exchangeRate.addListener(_syncFromAmountField);
    writeOff.addListener(_syncFromAmountField);
    _syncFromAmountField();
  }

  /// 该行的明细模式（构造时绑定，决定金额的来源）。
  final ItemMode mode;

  // ---- settle（核销 receipt/payment）----
  String? appliedLedgerId;
  String? appliedBillNo;
  List<String> salesOrderIds = const [];
  String? authoritativeSalesOrderId;
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
    final r = FinanceGridRow(mode: mode)
      ..appliedLedgerId = a.ledgerId
      ..appliedBillNo = a.appliedBillNo
      ..salesOrderIds = a.salesOrderIds
      ..authoritativeSalesOrderId = a.authoritativeSalesOrderId
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
    return r;
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
    return c;
  }

  @override
  void dispose() {
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
}) {
  switch (mode) {
    case ItemMode.settle:
      return type == FinanceDocType.receipt
          ? _receiptSettleColumns(
              context,
              names,
              accountBaseCurrency: accountBaseCurrency,
              showReconciliation: showReceiptReconciliation,
              bankReferenceController: bankReferenceController,
            )
          : _settleColumns();
    case ItemMode.allocate:
      return _allocateColumns(context, names, type);
    case ItemMode.transfer:
      return _transferColumns(names);
  }
}

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
      label: '应收单号',
      width: 160,
      // 行 model 普通字段（AR 引入时随行回填）——只给 textOf，行集变化时整体量宽。
      textOf: (r) => r.appliedBillNo ?? '',
      cellBuilder: (context, row) => Text(
        row.appliedBillNo ?? '—',
        style: TextStyle(
          color: row.appliedBillNo == null
              ? Theme.of(context).colorScheme.onSurfaceVariant
              : Theme.of(context).colorScheme.onSurface,
        ),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'source',
      label: '来源类型 / 单号',
      width: 200,
      // 单行省略号（2026-09-16 全站口径）+ 随文本自动加宽，不再折两行撑高整行。
      textOf: (row) =>
          '${financeArApSourceTypeLabel(row.sourceDocType)}'
          '${row.sourceDocNo?.trim().isNotEmpty == true ? ' · ${row.sourceDocNo}' : ''}',
      cellBuilder: (context, row) => Text(
        '${financeArApSourceTypeLabel(row.sourceDocType)}'
        '${row.sourceDocNo?.trim().isNotEmpty == true ? ' · ${row.sourceDocNo}' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'salesOrderNos',
      label: '销售订单号',
      width: 190,
      textOf: (row) =>
          row.salesOrderNos.isEmpty ? '—' : row.salesOrderNos.join('、'),
      cellBuilder: (context, row) => Text(
        row.salesOrderNos.isEmpty ? '—' : row.salesOrderNos.join('、'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'receivableOriginal',
      label: '应收总额',
      width: 110,
      numeric: true,
      cellBuilder: (context, row) =>
          Text(_moneyExact(row.receivableOriginalText, row.receivableOriginal)),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'receivedOriginal',
      label: '累计已收',
      width: 110,
      numeric: true,
      cellBuilder: (context, row) =>
          Text(_moneyExact(row.receivedOriginalText, row.receivedOriginal)),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'writtenOffOriginal',
      label: '累计冲销',
      width: 110,
      numeric: true,
      cellBuilder: (context, row) =>
          Text(_moneyExact(row.writtenOffOriginalText, row.writtenOffOriginal)),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'prepaymentAppliedOriginal',
      label: '预收已抵',
      width: 110,
      numeric: true,
      cellBuilder: (context, row) =>
          Text(row.prepaymentAppliedOriginal ?? '0.00'),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'currency',
      label: '应收币种',
      width: 110,
      required: true,
      // 销售收款只能按被引用应收的原币核销。币别由 AR 带入并保持只读，
      // 财务只填写到账汇率，避免选择其它币别后必然被服务端拒绝。
      cellBuilder: (context, row) => Text(
        financeCurrencyDisplayLabel(
              name: names.currency(row.currencyId),
              code: row.currencyCode,
            ) ??
            '原币',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
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
          textAlign: TextAlign.right,
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
      cellBuilder: (context, row) => Text(
        _moneyExact(row.balanceOriginalText, row.balanceOriginal),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'amount',
      label: '本次分配收款(原币)',
      width: 180,
      numeric: true,
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
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const UtenInputDecoration(
            InputDecoration(isDense: true, hintText: '0'),
          ),
        ),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'amountLocal',
      label: financeEntryText(context, 'convertedCnyColumn'),
      width: 170,
      numeric: true,
      headerInfo: financeEntryText(context, 'convertedCnyHint'),
      textOf: (row) =>
          financeExactMoneyDisplay(row.localAmountExactNotifier.value),
      listenableOf: (row) => row.localAmountExactNotifier,
      cellBuilder: (context, row) => ValueListenableBuilder<String?>(
        valueListenable: row.localAmountExactNotifier,
        builder: (_, value, _) => Text(financeExactMoneyDisplay(value)),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'balanceAfter',
      label: financeEntryText(context, 'remainingOriginalColumn'),
      width: 120,
      numeric: true,
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
        required: true,
        headerInfo: financeEntryText(context, 'batchBankReferenceHint'),
        // The document owns this controller. Each row edits the same bank
        // transaction reference; removing a row must not dispose it.
        textOf: (_) => bankReferenceController.text,
        listenableOf: (_) => bankReferenceController,
        cellBuilder: (context, _) => TextField(
          key: const ValueKey('finance-receipt-bank-reference'),
          controller: bankReferenceController,
          decoration: const UtenInputDecoration(InputDecoration(isDense: true)),
        ),
      ),
    EditableGridColumn<FinanceGridRow>(
      key: 'remark',
      label: '备注',
      width: 180,
      textOf: (r) => r.remark.text,
      listenableOf: (r) => r.remark,
      cellBuilder: (context, row) => TextField(
        controller: row.remark,
        decoration: const InputDecoration(isDense: true),
      ),
    ),
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
    'balanceAfter',
    'bankReference',
    'remark',
  };
  return columns.where((column) => entryKeys.contains(column.key)).toList();
}

String _money(double? value) => value == null ? '—' : value.toStringAsFixed(2);

String _moneyExact(String? text, double? fallback) =>
    text == null ? _money(fallback) : financeExactMoneyDisplay(text);

List<EditableGridColumn<FinanceGridRow>> _settleColumns() {
  return [
    EditableGridColumn<FinanceGridRow>(
      key: 'appliedBillNo',
      label: '核销单据号',
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
      label: '本次金额',
      width: 140,
      numeric: true,
      required: true,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.amount,
        isEmpty: () => (double.tryParse(row.amount.text.trim()) ?? 0) <= 0,
        child: TextField(
          controller: row.amount,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
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
    final styles = names.stylesFor(cat);
    for (final s in styles) {
      if (s.id == row.styleId) return s.name ?? s.id;
    }
    return row.styleId ?? '';
  }

  return [
    EditableGridColumn<FinanceGridRow>(
      key: 'style',
      label: type == FinanceDocType.expense ? '费用项目' : '收入项目',
      width: 200,
      // 随所选名称自动加宽（2026-09-16）：此前不接 textOf，选完长名称既不撑列
      // 又折成两行把整行撑高。展开箭头(20)一并计入。
      textOf: (row) => styleLabelOf(row),
      listenableOf: (row) => row.styleIdNotifier,
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, row) {
        final styles = names.stylesFor(cat);
        return UtenDropdownField(
          // dense：与同行数量/单价等输入格同高（2026-10-06 表格控件统一口径）。
          dense: true,
          value: row.styleId,
          items: [
            for (final s in styles)
              UtenDropdownItem(value: s.id, label: s.name ?? s.id),
            // 孤儿值兜底：当前 id 不在字典时补一条。
            if (row.styleId != null &&
                row.styleId!.isNotEmpty &&
                !styles.any((s) => s.id == row.styleId))
              UtenDropdownItem(value: row.styleId, label: row.styleId!),
          ],
          onChanged: (v) => row.styleId = v,
        );
      },
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
                // 表格控件统一口径：默认 40 最小点击区会撑高编辑行（行高标准=
                // 紧凑输入格，UtenEditableGridCellSpec），收紧到图标本身。
                style: IconButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
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
      cellBuilder: (context, row) => TextField(
        controller: row.qty,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(isDense: true, hintText: '0'),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'price',
      label: '单价',
      width: 96,
      numeric: true,
      cellBuilder: (context, row) => TextField(
        controller: row.price,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(isDense: true, hintText: '0'),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'amount',
      label: '金额',
      width: 120,
      numeric: true,
      required: true,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.amount,
        isEmpty: () => (double.tryParse(row.amount.text.trim()) ?? 0) <= 0,
        child: TextField(
          controller: row.amount,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
        ),
      ),
    ),
  ];
}

// ===== transfer：转入账户 + 日期 + 金额（录入）=====
List<EditableGridColumn<FinanceGridRow>> _transferColumns(
  FinanceNameService names,
) {
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
      cellBuilder: (context, row) => UtenDropdownField(
        // dense：与同行金额输入格同高（2026-10-06 表格控件统一口径）。
        dense: true,
        value: row.inAccountId,
        items: [
          for (final e in names.accountEntries.entries)
            UtenDropdownItem(value: e.key, label: e.value),
          if (row.inAccountId != null &&
              row.inAccountId!.isNotEmpty &&
              !names.accountEntries.containsKey(row.inAccountId))
            UtenDropdownItem(value: row.inAccountId, label: row.inAccountId!),
        ],
        onChanged: (v) => row.inAccountId = v,
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'occurDate',
      label: '日期',
      width: 150,
      required: true,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.occurDateNotifier,
        isEmpty: () => row.occurDate == null,
        child: ValueListenableBuilder<String?>(
          valueListenable: row.occurDateNotifier,
          builder: (context, v, _) => InkWell(
            onTap: () async {
              final picked = await showDatePicker(
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
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: UtenEditableGridCellSpec.pickerCellPadding,
              ),
              child: Text(
                v == null ? '未选择' : v.substring(0, 10),
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
      required: true,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.amount,
        isEmpty: () => (double.tryParse(row.amount.text.trim()) ?? 0) <= 0,
        child: TextField(
          controller: row.amount,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
        ),
      ),
    ),
  ];
}
