// 委外单据明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// 与采购 purchase_grid_columns 同构（货品 ValueNotifier / 数量 / 单价→金额自动），
// 但委外 8 单据差异更大，列由 SubcontractDocConfig 显隐：
//  - 货品 / 数量 永远在；
//  - 单价 / 金额 仅 itemHasPrice（询价/申请/订货/进仓/退货）；
//  - 重量 itemHasWeight；围数 itemHasGirth；胶箱数 itemHasBoxQty；
//  - 损耗 4 列（标准用量/结存数/损耗率/损耗原因）仅 itemHasWasteFields（损耗单）。
// 颜色/单位/上游明细 id 为透传（引入或回填时预填，保存时随行写回，UI 不单独编辑）。
import 'package:flutter/material.dart';

import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/providers/master_name_provider.dart' show GoodsOption;
import '../config/subcontract_doc_config.dart';
import 'subcontract_link_picker.dart' show LinkedItem;

/// 委外明细行。货品用 [ValueNotifier]（点选后单元格自动刷新，无需 setState）；
/// 数量/单价控制器变更 → 自动重算金额（amountNotifier，仅 itemHasPrice 时有意义）。
class SubcontractGridRow extends EditableGridRow with AmountRowMixin {
  SubcontractGridRow() {
    qty.addListener(_recalc);
    price.addListener(_recalc);
  }

  final ValueNotifier<GoodsOption?> goodsNotifier = ValueNotifier<GoodsOption?>(
    null,
  );
  GoodsOption? get goods => goodsNotifier.value;
  set goods(GoodsOption? v) => goodsNotifier.value = v;

  final TextEditingController qty = TextEditingController();
  final TextEditingController price = TextEditingController();
  final TextEditingController weight = TextEditingController();
  final TextEditingController girth = TextEditingController(); // 围数（进仓/退货/材料退）
  final TextEditingController boxQty = TextEditingController(); // 胶箱数量（材料出）
  // 损耗特有
  final TextEditingController endingQty = TextEditingController();
  final TextEditingController standardQty = TextEditingController();
  final TextEditingController wasteRate = TextEditingController();
  final TextEditingController cause = TextEditingController();

  /// 上游明细 id（引入时回填，保存时按 cfg.linkTo* 映射为
  /// applicationItemId/orderItemId/receiptItemId/materialIssueItemId）。
  String? upstreamItemId;
  String? colorId;
  String? unitId;

  /// 从上游引入项构造（货品/数量/单价/upstream/颜色/单位 预填）。
  factory SubcontractGridRow.fromLinked(LinkedItem li, GoodsOption goods) {
    final r = SubcontractGridRow()
      ..goods = goods
      ..upstreamItemId = li.upstreamItemId
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
    weight.dispose();
    girth.dispose();
    boxQty.dispose();
    endingQty.dispose();
    standardQty.dispose();
    wasteRate.dispose();
    cause.dispose();
    super.dispose();
  }
}

/// 委外明细列：货品（点选）/ 数量 / 单价? / 金额? / 重量? / 围数? / 胶箱数? /
/// 损耗(标准用量?/结存数?/损耗率?/损耗原因?)，全部按 [cfg] 的 itemHas* 显隐。
/// [onPickGoods] 由编辑页提供（弹货品选择器并写回 row.goods）。
List<EditableGridColumn<SubcontractGridRow>> subcontractGridColumns(
  Future<void> Function(SubcontractGridRow row) onPickGoods,
  SubcontractDocConfig cfg,
) {
  return [
    EditableGridColumn<SubcontractGridRow>(
      key: 'goods',
      label: '货品',
      width: 220,
      cellBuilder: (context, row) => InkWell(
        onTap: () => onPickGoods(row),
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
              const Icon(Icons.search_rounded, size: 16),
            ],
          ),
        ),
      ),
    ),
    EditableGridColumn<SubcontractGridRow>(
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
    if (cfg.itemHasPrice)
      EditableGridColumn<SubcontractGridRow>(
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
    if (cfg.itemHasPrice)
      EditableGridColumn<SubcontractGridRow>(
        key: 'amount',
        label: '金额',
        width: 110,
        numeric: true,
        cellBuilder: (context, row) => ValueListenableBuilder<double>(
          valueListenable: row.amountNotifier,
          builder: (_, v, _) => Text('¥${v.toStringAsFixed(2)}'),
        ),
      ),
    if (cfg.itemHasWeight)
      EditableGridColumn<SubcontractGridRow>(
        key: 'weight',
        label: '重量',
        width: 96,
        numeric: true,
        cellBuilder: (context, row) => TextField(
          controller: row.weight,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
        ),
      ),
    if (cfg.itemHasGirth)
      EditableGridColumn<SubcontractGridRow>(
        key: 'girth',
        label: '围数',
        width: 96,
        numeric: true,
        cellBuilder: (context, row) => TextField(
          controller: row.girth,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
        ),
      ),
    if (cfg.itemHasBoxQty)
      EditableGridColumn<SubcontractGridRow>(
        key: 'boxQty',
        label: '胶箱数',
        width: 96,
        numeric: true,
        cellBuilder: (context, row) => TextField(
          controller: row.boxQty,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
        ),
      ),
    if (cfg.itemHasWasteFields) ...[
      EditableGridColumn<SubcontractGridRow>(
        key: 'standardQty',
        label: '标准用量',
        width: 110,
        numeric: true,
        cellBuilder: (context, row) => TextField(
          controller: row.standardQty,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
        ),
      ),
      EditableGridColumn<SubcontractGridRow>(
        key: 'endingQty',
        label: '结存数',
        width: 100,
        numeric: true,
        cellBuilder: (context, row) => TextField(
          controller: row.endingQty,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
        ),
      ),
      EditableGridColumn<SubcontractGridRow>(
        key: 'wasteRate',
        label: '损耗率%',
        width: 100,
        numeric: true,
        cellBuilder: (context, row) => TextField(
          controller: row.wasteRate,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
        ),
      ),
      EditableGridColumn<SubcontractGridRow>(
        key: 'cause',
        label: '损耗原因',
        width: 200,
        cellBuilder: (context, row) => TextField(
          controller: row.cause,
          maxLines: 2,
          decoration: const InputDecoration(isDense: true, hintText: '选填'),
        ),
      ),
    ],
  ];
}
