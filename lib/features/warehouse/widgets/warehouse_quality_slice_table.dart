import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/uten_tokens.dart';
import '../models/warehouse_iqc_stock_in.dart'
    show WarehouseIqcStockInConfirmItem;
import '../models/warehouse_quality_result.dart';

/// 品质放行切片的可编辑草稿（勾选 + 本次数量 + 实际库位 + 所属收货单）。
/// 详情页待入库表格与批量入库弹窗共用同一草稿形态，保证键与校验一致。
class WarehouseQualitySliceDraft {
  WarehouseQualitySliceDraft(
    this.slice, {
    this.receiptTypeValue,
    this.receiptId,
    this.receiptNo,
    WarehouseQualitySliceSnapshot? snapshot,
  }) : selected = snapshot?.selected ?? true,
       quantity = TextEditingController(
         text:
             snapshot?.quantity ??
             warehouseQualityQuantity(slice.remainingBaseQty),
       ),
       place = TextEditingController(
         text: snapshot?.place ?? slice.placeHint ?? '',
       );

  final WarehouseQualityReleasedSlice slice;
  final String? receiptTypeValue;
  final String? receiptId;
  final String? receiptNo;
  bool selected;
  final TextEditingController quantity;
  final TextEditingController place;

  String get receiptKey => '$receiptTypeValue:$receiptId';

  WarehouseQualitySliceSnapshot get snapshot => WarehouseQualitySliceSnapshot(
    selected: selected,
    quantity: quantity.text,
    place: place.text,
  );

  void dispose() {
    quantity.dispose();
    place.dispose();
  }

  /// 就地校验（未勾选的行不校验）；返回错误文案或 null。
  String? validate() {
    if (!selected) return null;
    final value = double.tryParse(quantity.text.trim());
    if (value == null || value <= 0) {
      return '「${slice.goodsLabel.isEmpty ? slice.passEventId : slice.goodsLabel}」'
          '请输入大于 0 的本次实收数量';
    }
    if (value - slice.remainingBaseQty > 0.0000001) {
      return '「${slice.goodsLabel.isEmpty ? slice.passEventId : slice.goodsLabel}」'
          '本次数量 ${warehouseQualityQuantity(value)} 不得超过待入库余量 '
          '${warehouseQualityQuantity(slice.remainingBaseQty)}';
    }
    if (place.text.trim().isEmpty) {
      return '「${slice.goodsLabel.isEmpty ? slice.passEventId : slice.goodsLabel}」'
          '请填写本次实际库位';
    }
    return null;
  }
}

class WarehouseQualitySliceSnapshot {
  const WarehouseQualitySliceSnapshot({
    required this.selected,
    required this.quantity,
    required this.place,
  });

  final bool selected;
  final String quantity;
  final String place;
}

/// 放行切片表格（详情页待入库区块与批量入库弹窗共用形态）。
class WarehouseQualitySliceTable extends StatelessWidget {
  const WarehouseQualitySliceTable({
    super.key,
    required this.drafts,
    required this.editable,
    required this.saving,
    required this.onChanged,
    this.showReceipt = false,
  });

  final List<WarehouseQualitySliceDraft> drafts;
  final bool editable;
  final bool saving;
  final VoidCallback onChanged;
  final bool showReceipt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingTextStyle: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        dataRowMinHeight: 64,
        dataRowMaxHeight: 72,
        columnSpacing: UtenSpacing.s12,
        columns: [
          if (editable)
            DataColumn(
              label: Semantics(
                label: '全选待入库明细',
                child: Checkbox(
                  value:
                      drafts.isNotEmpty &&
                      drafts.every((draft) => draft.selected),
                  tristate: true,
                  onChanged: saving
                      ? null
                      : (value) {
                          final next = value != false;
                          for (final draft in drafts) {
                            draft.selected = next;
                          }
                          onChanged();
                        },
                ),
              ),
            ),
          if (showReceipt) const DataColumn(label: Text('收货单')),
          const DataColumn(label: Text('货品')),
          const DataColumn(label: Text('待入库量'), numeric: true),
          if (editable) ...[
            const DataColumn(label: Text('本次实收 *'), numeric: true),
            const DataColumn(label: Text('实际库位 *')),
          ],
          const DataColumn(label: Text('放行信息')),
        ],
        rows: [
          for (final draft in drafts)
            DataRow(
              selected: editable && draft.selected,
              onSelectChanged: editable && !saving
                  ? (value) {
                      draft.selected = value ?? false;
                      onChanged();
                    }
                  : null,
              cells: [
                if (editable)
                  DataCell(
                    Checkbox(
                      value: draft.selected,
                      onChanged: saving
                          ? null
                          : (value) {
                              draft.selected = value ?? false;
                              onChanged();
                            },
                    ),
                  ),
                if (showReceipt) DataCell(Text(draft.receiptNo ?? '—')),
                DataCell(
                  SizedBox(
                    width: 220,
                    child: Text(
                      draft.slice.goodsLabel.isEmpty
                          ? '未命名货品'
                          : draft.slice.goodsLabel,
                    ),
                  ),
                ),
                DataCell(
                  Text(
                    '${warehouseQualityQuantity(draft.slice.remainingBaseQty)}'
                    '${draft.slice.unitName == null ? '' : ' ${draft.slice.unitName}'}',
                  ),
                ),
                if (editable) ...[
                  DataCell(
                    SizedBox(
                      width: 130,
                      child: TextFormField(
                        key: ValueKey(
                          'quality-slice-qty-${draft.slice.passEventId}',
                        ),
                        controller: draft.quantity,
                        enabled: draft.selected && !saving,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [LengthLimitingTextInputFormatter(24)],
                        decoration: const InputDecoration(
                          isDense: true,
                          counterText: '',
                        ),
                        onChanged: (_) => onChanged(),
                      ),
                    ),
                  ),
                  DataCell(
                    SizedBox(
                      width: 150,
                      child: TextFormField(
                        key: ValueKey(
                          'quality-slice-place-${draft.slice.passEventId}',
                        ),
                        controller: draft.place,
                        enabled: draft.selected && !saving,
                        maxLength: 100,
                        decoration: InputDecoration(
                          isDense: true,
                          counterText: '',
                          hintText: draft.slice.placeHint ?? '实际库位',
                        ),
                        onChanged: (_) => onChanged(),
                      ),
                    ),
                  ),
                ],
                DataCell(
                  SizedBox(
                    width: 210,
                    child: Text(
                      [
                        if (draft.slice.releasedBy?.isNotEmpty == true)
                          '放行人 ${draft.slice.releasedBy}',
                        if (draft.slice.releasedAt?.isNotEmpty == true)
                          warehouseQualityDateTime(draft.slice.releasedAt),
                        if (draft.slice.releaseNote?.isNotEmpty == true)
                          draft.slice.releaseNote!,
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

String warehouseQualitySliceFingerprint(
  List<WarehouseIqcStockInConfirmItem> items,
) {
  final parts = [
    for (final item in items)
      '${item.passEventId}|${item.baseQty}|${item.expectedRemainingBaseQty}|${item.place.trim()}',
  ]..sort();
  return parts.join('||');
}

String warehouseQualityQuantity(double value) => value
    .toStringAsFixed(4)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');

String warehouseQualityDateTime(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return '—';
  final normalized = text.replaceFirst('T', ' ');
  return normalized.length > 16 ? normalized.substring(0, 16) : normalized;
}
