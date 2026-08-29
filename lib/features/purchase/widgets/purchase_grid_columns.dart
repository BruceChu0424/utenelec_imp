// 采购单据明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// PurchaseGridRow：货品(选择)/数量/单价→金额自动（AmountRowMixin）；颜色/单位/上游明细 id
// 为透传（从上游引入或详情回填时预填，保存时随行写回，UI 不单独编辑）。
// purchaseGridColumns：货品/数量/单价/金额 四列。
import 'package:flutter/material.dart';

import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/procurement_supplier_cell.dart';
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

  /// 库位号（只读，货品主档带出；收货上架/退货拣货指引，异步补全后自动刷新）。
  final ValueNotifier<String?> stockPlaceNotifier = ValueNotifier<String?>(
    null,
  );

  /// 上游明细 id（引入时回填，保存时按 cfg.linkTo* 映射为
  /// requestItemId/orderItemId/receiptItemId）。
  String? upstreamItemId;

  /// 来源单据编号谱系（到货登记=来源订货单号；与委外进仓口径一致，随行提交留痕）。
  String? sourceDocNo;
  String? colorId;
  String? unitId;

  /// 明细级供应商（订货单可逐行选不同供应商，保存时按供应商自动拆单；为空回落表头）。
  String? supplierId;

  /// 预计到货登记模式（[purchaseGridColumns] arrivalMode）：该行财务批准剩余量，
  /// 只读对照列展示；不实设 maxQty，仓库须能如实登记超量实到数。
  num? approvedQty;

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
    stockPlaceNotifier.dispose();
    super.dispose();
  }
}

/// 采购明细列：货品（点选）/ 数量 / 单价 / 金额（自动）。
/// [onPickGoods] 由编辑页提供（弹货品选择器并写回 row.goods）。
/// [arrivalMode]=true（预计到货「登记实际到货」预填场景）：列改为
/// 货品 / 批准剩余（只读对照）/ 实到数量——不显示单价/金额，仓库只关心到货数量。
/// [supplierEntries]+[onSupplierChanged]：订货单显示「供应商」明细列（逐行选不同供应商，
/// 保存时按供应商自动拆单）；收货/退货不传，沿用表头单一供应商。
/// [showStockPlace]（收货/退货实物单据）：货品列后加「库位号」只读列（主档带出，上架/拣货指引）。
List<EditableGridColumn<PurchaseGridRow>> purchaseGridColumns(
  Future<void> Function(PurchaseGridRow row) onPickGoods, {
  bool arrivalMode = false,
  bool showStockPlace = false,
  Map<String, String> supplierEntries = const {},
  String? headerSupplierId,
  ValueChanged<String?>? onSupplierChanged,
}) {
  final showSupplier = !arrivalMode && supplierEntries.isNotEmpty;
  return [
    EditableGridColumn<PurchaseGridRow>(
      key: 'goods',
      label: '货品',
      width: 220,
      required: true,
      textOf: (r) => r.goods?.name ?? '',
      listenableOf: (r) => r.goodsNotifier,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.goodsNotifier,
        isEmpty: () => row.goods == null,
        child: InkWell(
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
    ),
    if (showStockPlace)
      EditableGridColumn<PurchaseGridRow>(
        key: 'stockPlace',
        label: '库位号',
        width: 90,
        textOf: (r) => r.stockPlaceNotifier.value ?? '',
        listenableOf: (r) => r.stockPlaceNotifier,
        cellBuilder: (context, row) => ValueListenableBuilder<String?>(
          valueListenable: row.stockPlaceNotifier,
          builder: (_, v, _) => Text(
            (v == null || v.isEmpty) ? '—' : v,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: (v == null || v.isEmpty)
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    if (showSupplier)
      EditableGridColumn<PurchaseGridRow>(
        key: 'supplier',
        label: '供应商',
        width: 150,
        cellBuilder: (context, row) => ProcurementSupplierCell(
          value: row.supplierId,
          fallback: headerSupplierId,
          entries: supplierEntries,
          onChanged: (v) {
            row.supplierId = v;
            onSupplierChanged?.call(v);
          },
        ),
      ),
    // 批准剩余：只读对照（财务批准还能收多少），超量实到不拦截，由服务端审核隔离。
    if (arrivalMode)
      EditableGridColumn<PurchaseGridRow>(
        key: 'approvedQty',
        label: '批准剩余',
        width: 96,
        numeric: true,
        cellBuilder: (context, row) => Text(
          row.approvedQty == null ? '—' : procurementQty(row.approvedQty!),
        ),
      ),
    EditableGridColumn<PurchaseGridRow>(
      key: 'qty',
      label: arrivalMode ? '实到数量' : '数量',
      width: 96,
      numeric: true,
      required: true,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.qty,
        isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
        child: TextField(
          controller: row.qty,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
        ),
      ),
    ),
    if (!arrivalMode)
      EditableGridColumn<PurchaseGridRow>(
        key: 'price',
        label: '单价',
        width: 96,
        numeric: true,
        required: true,
        cellBuilder: (context, row) => RequiredCellFrame(
          listenable: row.price,
          isEmpty: () =>
              row.price.text.trim().isEmpty ||
              double.tryParse(row.price.text.trim()) == null,
          child: TextField(
            controller: row.price,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(isDense: true, hintText: '0'),
          ),
        ),
      ),
    if (!arrivalMode)
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
