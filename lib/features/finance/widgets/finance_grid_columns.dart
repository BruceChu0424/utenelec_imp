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
    _syncFromAmountField();
  }

  /// 该行的明细模式（构造时绑定，决定金额的来源）。
  final ItemMode mode;

  // ---- settle（核销 receipt/payment）----
  String? appliedLedgerId;
  String? appliedBillNo;

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

  /// 「从应收应付引入」构造：核销台账 id + 单据号 + 本次核销额 预填。
  factory FinanceGridRow.fromApplied(ItemMode mode, AppliedArAp a) {
    final r = FinanceGridRow(mode: mode)
      ..appliedLedgerId = a.ledgerId
      ..appliedBillNo = a.appliedBillNo;
    r.amount.text = a.amountLocal.toStringAsFixed(2);
    return r;
  }

  void _syncFromAmountField() =>
      recalcAmount(() => double.tryParse(amount.text) ?? 0);

  @override
  void dispose() {
    qty.dispose();
    price.dispose();
    amount.dispose();
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
      return _settleColumns();
    case ItemMode.allocate:
      return _allocateColumns(names, type);
    case ItemMode.transfer:
      return _transferColumns(names);
  }
}

// ===== settle：核销单据号（只读）+ 本次金额（录入）=====
List<EditableGridColumn<FinanceGridRow>> _settleColumns() {
  return [
    EditableGridColumn<FinanceGridRow>(
      key: 'appliedBillNo',
      label: '核销单据号',
      width: 260,
      cellBuilder: (context, row) => Text(
        row.appliedBillNo ?? '直接收款（未指定核销）',
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
      cellBuilder: (context, row) => TextField(
        controller: row.amount,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(isDense: true, hintText: '0'),
      ),
    ),
  ];
}

// ===== allocate：项目 + 部门 + 数量 + 单价 + 金额(自动) =====
List<EditableGridColumn<FinanceGridRow>> _allocateColumns(
    FinanceNameService names, FinanceDocType type) {
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
      cellBuilder: (context, row) => TextField(
        controller: row.amount,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(isDense: true, hintText: '0'),
      ),
    ),
  ];
}

// ===== transfer：转入账户 + 日期 + 金额（录入）=====
List<EditableGridColumn<FinanceGridRow>> _transferColumns(
    FinanceNameService names) {
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
      cellBuilder: (context, row) => ValueListenableBuilder<String?>(
        valueListenable: row.occurDateNotifier,
        builder: (context, v, _) => InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate:
                  v == null ? DateTime.now() : (DateTime.tryParse(v) ?? DateTime.now()),
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
    EditableGridColumn<FinanceGridRow>(
      key: 'amount',
      label: '金额',
      width: 140,
      numeric: true,
      cellBuilder: (context, row) => TextField(
        controller: row.amount,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(isDense: true, hintText: '0'),
      ),
    ),
  ];
}
