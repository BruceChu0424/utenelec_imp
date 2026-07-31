// 采购单据明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// PurchaseGridRow：货品(选择)/数量/单价→金额自动（AmountRowMixin）；颜色/单位/上游明细 id
// 为透传（从上游引入或详情回填时预填，保存时随行写回，UI 不单独编辑）。
// purchaseGridColumns：货品/数量/单价/金额 四列。
import 'package:flutter/material.dart';

import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/providers/master_name_provider.dart';
import 'doc_link_picker.dart';

/// 采购明细行。货品用 [ValueNotifier]（点选后单元格自动刷新，无需 setState）；
/// 数量/单价控制器变更 → 自动重算金额（amountNotifier）。
class PurchaseGridRow extends EditableGridRow with AmountRowMixin {
  PurchaseGridRow({this.sourceLocked = false}) {
    qty.addListener(_recalc);
    price.addListener(_recalc);
  }

  final bool sourceLocked;
  double? maxQty;
  final ValueNotifier<GoodsOption?> goodsNotifier = ValueNotifier<GoodsOption?>(
    null,
  );
  GoodsOption? get goods => goodsNotifier.value;
  set goods(GoodsOption? v) => goodsNotifier.value = v;

  final TextEditingController qty = TextEditingController();
  final TextEditingController price = TextEditingController();

  /// 上游明细 id（引入时回填，保存时按 cfg.linkTo* 映射为
  /// requestItemId/orderItemId/receiptItemId）。
  String? upstreamItemId;
  String? colorId;
  String? unitId;

  /// 从上游引入项构造（货品/数量/单价/upstream/颜色/单位 预填）。
  factory PurchaseGridRow.fromLinked(LinkedItem li, GoodsOption goods) {
    final r = PurchaseGridRow(sourceLocked: true)
      ..goods = goods
      ..upstreamItemId = li.upstreamItemId
      ..maxQty = li.maxQty
      ..colorId = li.colorId
      ..unitId = li.unitId;
    r.qty.text = li.qty.toString();
    if (li.price != null) r.price.text = li.price.toString();
    return r;
  }

  void _recalc() => recalcAmount(
    () => (double.tryParse(qty.text) ?? 0) * (double.tryParse(price.text) ?? 0),
  );

  @override
  void dispose() {
    goodsNotifier.dispose();
    qty.dispose();
    price.dispose();
    super.dispose();
  }
}

/// 采购明细列：货品（点选）/ 数量 / 单价 / 金额（自动）。
/// [onPickGoods] 由编辑页提供（弹货品选择器并写回 row.goods）。
List<EditableGridColumn<PurchaseGridRow>> purchaseGridColumns(
  Future<void> Function(PurchaseGridRow row) onPickGoods,
) {
  return [
    EditableGridColumn<PurchaseGridRow>(
      key: 'goods',
      label: '货品',
      width: 220,
      cellBuilder: (context, row) => InkWell(
        onTap: row.sourceLocked ? null : () => onPickGoods(row),
        child: InputDecorator(
          decoration: const InputDecoration(isDense: true),
          child: Row(
            children: [
              Expanded(
                child: ValueListenableBuilder<GoodsOption?>(
                  valueListenable: row.goodsNotifier,
                  builder: (context, g, _) => Text(
                    g?.name ?? '点击选择',
                    style: TextStyle(
                      color: g == null
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
              Icon(
                row.sourceLocked ? Icons.lock_outline : Icons.search_rounded,
                size: 16,
              ),
            ],
          ),
        ),
      ),
    ),
    EditableGridColumn<PurchaseGridRow>(
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
    EditableGridColumn<PurchaseGridRow>(
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
    EditableGridColumn<PurchaseGridRow>(
      key: 'amount',
      label: '金额',
      width: 110,
      numeric: true,
      cellBuilder: (context, row) => ValueListenableBuilder<double>(
        valueListenable: row.amountNotifier,
        builder: (_, v, _) => Text('¥${v.toStringAsFixed(2)}'),
      ),
    ),
  ];
}
