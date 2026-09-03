// 采购/委外订货单明细行级商业条款（2026-09）共享组件：
//  - [CommercialTermsRowMixin]：明细行混入的币种/汇率/税率/结账(结算)方式状态；
//  - [RemarkRowMixin]：明细行备注（每行末尾备注列）；
//  - [ProcurementTermDropdownCell]：grid 单元格里的紧凑下拉选择格（弹菜单）；
//  - [procurementCommercialColumns]：币种/汇率/税率/结账方式四列（订货单明细）；
//  - [procurementRemarkColumn]：备注列（明细最后一列）。
//
// 商业字段下移明细行后，单头不再录商业条款；保存时逐行提交，
// 后端 createBatch 按「供应商+商业条款」组合拆单归集到各张单的头字段。
import 'package:flutter/material.dart';

import '../../components/layout/uten_editable_grid.dart';

/// 行级商业条款行的契约（列构建的泛型约束；Dart 无交集类型，用抽象类收口）。
/// [CommercialTermsRowMixin] 实现本契约，混入即满足约束。
abstract class CommercialTermsGridRow extends EditableGridRow {
  String? get currencyId;
  set currencyId(String? value);
  String? get settlementMethodId;
  set settlementMethodId(String? value);
  ValueNotifier<String?> get currencyIdNotifier;
  ValueNotifier<String?> get settlementMethodIdNotifier;
  TextEditingController get exchangeRate;
  TextEditingController get taxRate;
}

/// 备注行的契约（同上）。
abstract class RemarkGridRow extends EditableGridRow {
  TextEditingController get remark;
}

/// 明细行级商业条款状态（币种/结账方式为 ValueNotifier：批量赋值与学习预填后
/// 单元格即时刷新；汇率/税率为文本控制器，与数量/单价同款）。
mixin CommercialTermsRowMixin on EditableGridRow
    implements CommercialTermsGridRow {
  @override
  final ValueNotifier<String?> currencyIdNotifier = ValueNotifier<String?>(
    null,
  );
  @override
  final ValueNotifier<String?> settlementMethodIdNotifier =
      ValueNotifier<String?>(null);
  @override
  final TextEditingController exchangeRate = TextEditingController();
  @override
  final TextEditingController taxRate = TextEditingController();

  @override
  String? get currencyId => currencyIdNotifier.value;

  @override
  set currencyId(String? v) => currencyIdNotifier.value = v;

  @override
  String? get settlementMethodId => settlementMethodIdNotifier.value;

  @override
  set settlementMethodId(String? v) => settlementMethodIdNotifier.value = v;

  /// 行克隆时拷贝另一行的条款（不共享控制器/通知器）。
  void copyCommercialFrom(CommercialTermsRowMixin other) {
    currencyId = other.currencyId;
    settlementMethodId = other.settlementMethodId;
    exchangeRate.text = other.exchangeRate.text;
    taxRate.text = other.taxRate.text;
  }

  @override
  void dispose() {
    currencyIdNotifier.dispose();
    settlementMethodIdNotifier.dispose();
    exchangeRate.dispose();
    taxRate.dispose();
    super.dispose();
  }
}

/// 明细行备注（每行末尾的备注列；保存时随行提交 remark）。
mixin RemarkRowMixin on EditableGridRow implements RemarkGridRow {
  final TextEditingController _remark = TextEditingController();

  @override
  TextEditingController get remark => _remark;

  @override
  void dispose() {
    _remark.dispose();
    super.dispose();
  }
}

/// grid 单元格里的紧凑下拉选择格（币种/结账方式等短字典）：
/// outlined 只读格 + 右侧展开箭头，点击弹菜单选值（与供应商单元格同款视觉）。
/// [value] 当前值；[entries] id→名称；[onChanged] 选中回写（页面按多选范围落值）；
/// [requiredEmpty] 必填未选时提示标红。
class ProcurementTermDropdownCell extends StatelessWidget {
  const ProcurementTermDropdownCell({
    super.key,
    required this.value,
    required this.entries,
    this.onChanged,
    this.requiredEmpty = false,
    this.hint = '点击选择',
  });

  final String? value;
  final Map<String, String> entries;
  final ValueChanged<String?>? onChanged;
  final bool requiredEmpty;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasValue = value != null && value!.isNotEmpty;
    final label = hasValue ? (entries[value] ?? value!) : hint;
    return PopupMenuButton<String>(
      initialValue: hasValue ? value : null,
      enabled: onChanged != null,
      onSelected: onChanged,
      constraints: const BoxConstraints(minWidth: 160),
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        for (final entry in entries.entries)
          PopupMenuItem<String>(
            value: entry.key,
            height: 42,
            child: Text(
              entry.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
      ],
      child: InputDecorator(
        decoration: InputDecoration(
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 8,
          ),
          suffixIcon: Icon(
            hasValue ? Icons.unfold_more_rounded : Icons.search_rounded,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          suffixIconConstraints: const BoxConstraints(minWidth: 20),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: hasValue
                ? theme.colorScheme.onSurface
                : (requiredEmpty
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

/// 订货单明细的商业条款四列：币种 / 汇率 / 税率(%) / 结账(结算)方式。
/// [onPickCurrency]/[onPickSettlement] 由页面提供（按多选范围落值联动）；
/// [settlementLabel] 采购叫「结账方式」、委外叫「结算方式」。
/// 币种与结账方式必填（列头红 * + 空值红字提示）；汇率>0、税率 0-100 由保存校验兜底。
List<EditableGridColumn<R>>
procurementCommercialColumns<R extends CommercialTermsGridRow>({
  required Map<String, String> currencyEntries,
  required Map<String, String> settlementEntries,
  required ValueChanged<String?> Function(R row) onPickCurrency,
  required ValueChanged<String?> Function(R row) onPickSettlement,
  String settlementLabel = '结账方式',
}) {
  return [
    EditableGridColumn<R>(
      key: 'currency',
      label: '币种',
      width: 110,
      required: true,
      textOf: (r) =>
          r.currencyId == null ? '' : (currencyEntries[r.currencyId] ?? ''),
      listenableOf: (r) => r.currencyIdNotifier,
      cellBuilder: (context, row) => ValueListenableBuilder<String?>(
        valueListenable: row.currencyIdNotifier,
        builder: (_, v, _) => ProcurementTermDropdownCell(
          value: v,
          entries: currencyEntries,
          requiredEmpty: v == null,
          onChanged: (next) => onPickCurrency(row)(next),
        ),
      ),
    ),
    EditableGridColumn<R>(
      key: 'exchangeRate',
      label: '汇率',
      width: 84,
      numeric: true,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.exchangeRate,
        isEmpty: () =>
            (double.tryParse(row.exchangeRate.text.trim()) ?? 0) <= 0,
        child: TextField(
          controller: row.exchangeRate,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '1'),
        ),
      ),
    ),
    EditableGridColumn<R>(
      key: 'taxRate',
      label: '税率(%)',
      width: 84,
      numeric: true,
      cellBuilder: (context, row) => TextField(
        controller: row.taxRate,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(isDense: true, hintText: '0'),
      ),
    ),
    EditableGridColumn<R>(
      key: 'settlement',
      label: settlementLabel,
      width: 140,
      required: true,
      textOf: (r) => r.settlementMethodId == null
          ? ''
          : (settlementEntries[r.settlementMethodId] ?? ''),
      listenableOf: (r) => r.settlementMethodIdNotifier,
      cellBuilder: (context, row) => ValueListenableBuilder<String?>(
        valueListenable: row.settlementMethodIdNotifier,
        builder: (_, v, _) => ProcurementTermDropdownCell(
          value: v,
          entries: settlementEntries,
          requiredEmpty: v == null,
          onChanged: (next) => onPickSettlement(row)(next),
        ),
      ),
    ),
  ];
}

/// 明细末尾的备注列（自动随内容加宽，封顶由表格组件控制）。
EditableGridColumn<R> procurementRemarkColumn<R extends RemarkGridRow>({
  double width = 220,
}) {
  return EditableGridColumn<R>(
    key: 'remark',
    label: '备注',
    width: width,
    textOf: (r) => r.remark.text,
    listenableOf: (r) => r.remark,
    cellBuilder: (context, row) => TextField(
      controller: row.remark,
      maxLines: 2,
      decoration: const InputDecoration(isDense: true, hintText: '选填'),
    ),
  );
}
