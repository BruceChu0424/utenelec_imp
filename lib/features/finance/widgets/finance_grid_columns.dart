// 钱流单据明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// FinanceGridRow：统一承载 3 种模式的字段（settle 核销 / allocate 分摊 / transfer 转入）。
// 模式由 [ItemMode] 标记（行构造时绑定，不可切换）——与 FinanceDocConfig.itemMode 一致：
// - 三种模式：amount 列均为 TextField 直接录入 → amountNotifier 同步（驱动表尾合计）；
//   allocate 的数量/单价为可选明细字段，不强制驱动金额（与老页面一致：金额独立可编辑）。
// amountNotifier 是所有模式下的「金额」真相源，保存时直接读 .value。
//
// financeGridColumns(mode, ...)：按模式返回不同列集，每列 cellBuilder 编辑对应行字段。
// 列宽固定 + 横向滚动（UtenEditableGrid 自带 sticky 表头），全尺寸 Excel（与其它模块一致）。
import 'package:flutter/material.dart';

import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/utils/china_datetime.dart';
import '../config/finance_doc_config.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import 'ar_ap_picker_dialog.dart';

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
  double? receivedOriginal;
  double? writtenOffOriginal;
  double? balanceOriginal;
  String? prepaymentAppliedOriginal;

  // ---- allocate（分摊 expense/otherIncome）----
  String? styleId; // expenseStyleId / incomeStyleId
  /// 部门 UUID 文本（可空；TODO 升级为部门 picker，目前保持 UUID 文本录入）。
  final TextEditingController department = TextEditingController();

  // ---- transfer（转入 bankTransfer）----
  String? inAccountId;

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
  final ValueNotifier<double> localAmountNotifier = ValueNotifier<double>(0);
  final ValueNotifier<double> writeOffLocalNotifier = ValueNotifier<double>(0);
  final ValueNotifier<double> balanceAfterNotifier = ValueNotifier<double>(0);

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
      ..receivedOriginal = a.receivedOriginal
      ..writtenOffOriginal = a.writtenOffOriginal
      ..balanceOriginal = a.balanceOriginal;
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
    department.dispose();
    occurDateNotifier.dispose();
    super.dispose();
  }
}

/// 按模式返回明细列集。
///
/// [names] 主档名称服务（提供项目/账户下拉选项，页面 build 时传入最新引用）。
/// [type] 当前单据类型（区分费用/收入项目标签）。
List<EditableGridColumn<FinanceGridRow>> financeGridColumns(
  ItemMode mode, {
  required FinanceNameService names,
  required FinanceDocType type,
}) {
  switch (mode) {
    case ItemMode.settle:
      return type == FinanceDocType.receipt
          ? _receiptSettleColumns(names)
          : _settleColumns();
    case ItemMode.allocate:
      return _allocateColumns(names, type);
    case ItemMode.transfer:
      return _transferColumns(names);
  }
}

// ===== settle：核销单据号（只读）+ 本次金额（录入）=====
List<EditableGridColumn<FinanceGridRow>> _receiptSettleColumns(
  FinanceNameService names,
) {
  return [
    EditableGridColumn<FinanceGridRow>(
      key: 'appliedBillNo',
      label: '应收单号',
      width: 160,
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
      cellBuilder: (context, row) => Text(
        '${financeArApSourceTypeLabel(row.sourceDocType)}'
        '${row.sourceDocNo?.trim().isNotEmpty == true ? ' · ${row.sourceDocNo}' : ''}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'salesOrderNos',
      label: '销售订单号',
      width: 190,
      cellBuilder: (context, row) => Text(
        row.salesOrderNos.isEmpty ? '—' : row.salesOrderNos.join('、'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'receivableOriginal',
      label: '应收总额',
      width: 110,
      numeric: true,
      cellBuilder: (context, row) => Text(_money(row.receivableOriginal)),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'receivedOriginal',
      label: '累计已收',
      width: 110,
      numeric: true,
      cellBuilder: (context, row) => Text(_money(row.receivedOriginal)),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'writtenOffOriginal',
      label: '累计冲销',
      width: 110,
      numeric: true,
      cellBuilder: (context, row) => Text(_money(row.writtenOffOriginal)),
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
      key: 'balanceOriginal',
      label: '本次可收',
      width: 110,
      numeric: true,
      cellBuilder: (context, row) => Text(
        _money(row.balanceOriginal),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'amount',
      label: '本次收款金额',
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
    EditableGridColumn<FinanceGridRow>(
      key: 'currency',
      label: '应收币别',
      width: 130,
      required: true,
      // 销售收款只能按被引用应收的原币核销。币别由 AR 带入并保持只读，
      // 财务只填写到账汇率，避免选择其它币别后必然被服务端拒绝。
      cellBuilder: (context, row) => Text(
        row.currencyCode?.trim().isNotEmpty == true
            ? row.currencyCode!.trim()
            : names.currency(row.currencyId),
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'exchangeRate',
      label: '到账汇率',
      width: 120,
      numeric: true,
      required: true,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.exchangeRate,
        isEmpty: () =>
            (double.tryParse(row.exchangeRate.text.trim()) ?? 0) <= 0,
        child: TextField(
          controller: row.exchangeRate,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '财务填写'),
        ),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'amountLocal',
      label: '换算人民币',
      width: 130,
      numeric: true,
      cellBuilder: (context, row) => ValueListenableBuilder<double>(
        valueListenable: row.localAmountNotifier,
        builder: (_, value, _) => Text(value.toStringAsFixed(2)),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'writeOff',
      label: '冲销金额（原币）',
      width: 120,
      numeric: true,
      cellBuilder: (context, row) => TextField(
        controller: row.writeOff,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(isDense: true, hintText: '0'),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'balanceAfter',
      label: '收款后未收',
      width: 120,
      numeric: true,
      cellBuilder: (context, row) => ValueListenableBuilder<double>(
        valueListenable: row.balanceAfterNotifier,
        builder: (_, value, _) => Text(
          value.toStringAsFixed(2),
          style: TextStyle(
            color: value < 0 ? Theme.of(context).colorScheme.error : null,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
    EditableGridColumn<FinanceGridRow>(
      key: 'remark',
      label: '备注',
      width: 180,
      cellBuilder: (context, row) => TextField(
        controller: row.remark,
        decoration: const InputDecoration(isDense: true),
      ),
    ),
  ];
}

String _money(double? value) => value == null ? '—' : value.toStringAsFixed(2);

List<EditableGridColumn<FinanceGridRow>> _settleColumns() {
  return [
    EditableGridColumn<FinanceGridRow>(
      key: 'appliedBillNo',
      label: '核销单据号',
      width: 260,
      cellBuilder: (context, row) => Text(
        row.appliedBillNo ?? '直接付款（未指定核销）',
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
  FinanceNameService names,
  FinanceDocType type,
) {
  final cat = type == FinanceDocType.expense ? 'EXPENSE' : 'INCOME';
  return [
    EditableGridColumn<FinanceGridRow>(
      key: 'style',
      label: type == FinanceDocType.expense ? '费用项目' : '收入项目',
      width: 200,
      cellBuilder: (context, row) {
        final styles = names.stylesFor(cat);
        return UtenDropdownField(
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
      label: '部门ID',
      width: 160,
      cellBuilder: (context, row) => TextField(
        controller: row.department,
        decoration: const InputDecoration(isDense: true, hintText: '可空'),
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
      cellBuilder: (context, row) => UtenDropdownField(
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
              decoration: const InputDecoration(isDense: true),
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
