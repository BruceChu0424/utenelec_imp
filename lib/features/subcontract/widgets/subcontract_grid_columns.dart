// 委外单据明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// 与采购 purchase_grid_columns 同构（货品 ValueNotifier / 数量 / 单价→金额自动），
// 但委外 8 单据差异更大，列由 SubcontractDocConfig 显隐：
//  - 货品 / 数量 永远在；数量之后紧跟单位（2026-09-04 口径）；
//  - 单价 / 金额 仅 itemHasPrice（询价/申请/订货/进仓/退货）；
//  - 重量列已下线（2026-09-04：单位已表达重量；itemHasWeight 仍驱动保存透传）；
//  围数 itemHasGirth；胶箱数 itemHasBoxQty；
//  - 损耗 4 列（标准用量/结存数/损耗率/损耗原因）仅 itemHasWasteFields（损耗单）。
// 颜色/单位/上游明细 id 为透传（引入或回填时预填，保存时随行写回，UI 不单独编辑）。
import 'package:flutter/material.dart';

import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/providers/master_name_provider.dart' show GoodsOption;
import '../../../shared/widgets/procurement_commercial_grid.dart';
import '../../../shared/widgets/procurement_supplier_cell.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart' show SubcontractSourceApplicationRef;
import 'subcontract_link_picker.dart' show LinkedItem;

/// 委外明细行。货品用 [ValueNotifier]（点选后单元格自动刷新，无需 setState）；
/// 数量/单价控制器变更 → 自动重算金额（amountNotifier，仅 itemHasPrice 时有意义）。
/// 2026-09 起：币种/汇率/税率/结算方式与备注为行级（订货单），见
/// [CommercialTermsRowMixin]/[RemarkRowMixin]。
class SubcontractGridRow extends EditableGridRow
    with AmountRowMixin, CommercialTermsRowMixin, RemarkRowMixin {
  SubcontractGridRow({this.sourceLocked = false}) {
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

  /// 库位号（只读，货品主档带出；实物出入库单据的上架/拣货指引，异步补全后自动刷新）。
  final ValueNotifier<String?> stockPlaceNotifier = ValueNotifier<String?>(
    null,
  );
  // 损耗特有
  final TextEditingController endingQty = TextEditingController();
  final TextEditingController standardQty = TextEditingController();
  final TextEditingController wasteRate = TextEditingController();
  final TextEditingController cause = TextEditingController();

  /// 上游明细 id（引入时回填，保存时按 cfg.linkTo* 映射为
  /// applicationItemId/orderItemId/receiptItemId/materialIssueItemId）。
  String? upstreamItemId;

  /// 全部来源申请明细 id（V463 同货品合并行，含 [upstreamItemId] 首来源）；
  /// 保存时 >1 条随行提交 applicationItemIds。空列表 = 无来源/手工行。
  List<String> upstreamItemIds = [];

  /// 来源申请引用（合并行多来源展示与跳详情）：与 [upstreamItemIds] 对齐。
  List<SubcontractSourceApplicationRef> sourceDocs = [];

  /// 发料计划行 id（V304；计划生成的出仓草稿行回传，保存时原样带上不断链）。
  String? planItemId;
  final bool sourceLocked;
  double? maxQty;
  String? colorId;
  String? unitId;
  double? unitRate;
  String? sourceDocNo;

  /// 明细级委外商（订货单可逐行选不同委外商，保存时按委外商自动拆单；为空回落表头）。
  /// ValueNotifier：多选统一设委外商/记忆预填后单元格与必填提示即时刷新。
  final ValueNotifier<String?> supplierIdNotifier = ValueNotifier<String?>(
    null,
  );
  String? get supplierId => supplierIdNotifier.value;
  set supplierId(String? v) => supplierIdNotifier.value = v;

  /// 从上游引入项构造（货品/数量/单价/upstream/颜色/单位 预填）。
  factory SubcontractGridRow.fromLinked(LinkedItem li, GoodsOption goods) {
    final r = SubcontractGridRow(sourceLocked: li.upstreamItemId != null)
      ..goods = goods
      ..upstreamItemId = li.upstreamItemId
      ..maxQty = li.maxQty
      ..colorId = li.colorId
      ..unitId = li.unitId
      ..unitRate = li.unitRate;
    r.upstreamItemIds = [
      if (li.upstreamItemId != null && li.upstreamItemId!.isNotEmpty)
        li.upstreamItemId!,
    ];
    r.qty.text = li.qty.toString();
    if (li.price != null) r.price.text = li.price.toString();
    return r;
  }

  void _recalc() => recalcAmount(
    () => (double.tryParse(qty.text) ?? 0) * (double.tryParse(price.text) ?? 0),
  );

  /// 深拷贝（明细复制/粘贴用）：语义同 PurchaseGridRow.clone——拷用户录入（数量/
  /// 单价/重量/围数/胶箱数/行委外商/行级商业条款/备注/损耗单四列）与主档透传；
  /// 不拷上游 id、planItemId、来源谱系、数量门控 maxQty 与 sourceLocked。
  SubcontractGridRow clone() {
    final c = SubcontractGridRow()
      ..goods = goods
      ..stockPlaceNotifier.value = stockPlaceNotifier.value
      ..colorId = colorId
      ..unitId = unitId
      ..unitRate = unitRate
      ..supplierId = supplierId;
    c.qty.text = qty.text;
    c.price.text = price.text;
    c.weight.text = weight.text;
    c.girth.text = girth.text;
    c.boxQty.text = boxQty.text;
    c.endingQty.text = endingQty.text;
    c.standardQty.text = standardQty.text;
    c.wasteRate.text = wasteRate.text;
    c.cause.text = cause.text;
    c.copyCommercialFrom(this);
    c.remark.text = remark.text;
    return c;
  }

  @override
  void dispose() {
    goodsNotifier.dispose();
    qty.dispose();
    price.dispose();
    weight.dispose();
    girth.dispose();
    boxQty.dispose();
    stockPlaceNotifier.dispose();
    endingQty.dispose();
    standardQty.dispose();
    wasteRate.dispose();
    cause.dispose();
    supplierIdNotifier.dispose();
    super.dispose();
  }
}

/// 委外明细列：货品（点选）/ 数量 / 单位 / 单价? / 金额? / 围数? / 胶箱数? /
/// 损耗(标准用量?/结存数?/损耗率?/损耗原因?)，全部按 [cfg] 的 itemHas* 显隐。
/// [onPickGoods] 由编辑页提供（弹货品选择器并写回 row.goods）。
/// [showCommercial]+[currencyEntries]/[settlementEntries]/[onPickCurrency]/[onPickSettlement]
/// （订货单）：金额列后加「币种/汇率/税率/结算方式」四列（行级商业条款，保存按组合拆单）。
/// [showRemark]：明细末尾加「备注」列（随行提交 remark）。
/// 列序（2026-09-04 口径）：数量之后紧跟单位；实际重量列下线（cfg.itemHasWeight
/// 仍驱动保存透传，行模型 weight 保留既有单回填/回写）。
List<EditableGridColumn<SubcontractGridRow>> subcontractGridColumns(
  Future<void> Function(SubcontractGridRow row) onPickGoods,
  SubcontractDocConfig cfg, {
  Map<String, String> unitEntries = const {},
  Map<String, String> supplierEntries = const {},
  bool supplierRequired = false,
  String? headerSupplierId,
  Future<void> Function(SubcontractGridRow row)? onPickSupplier,
  bool showCommercial = false,
  Map<String, String> currencyEntries = const {},
  Map<String, String> settlementEntries = const {},
  ValueChanged<String?> Function(SubcontractGridRow row)? onPickCurrency,
  ValueChanged<String?> Function(SubcontractGridRow row)? onPickSettlement,
  bool showRemark = false,
}) {
  final showSupplier = supplierEntries.isNotEmpty && cfg.hasSupplier;
  return [
    EditableGridColumn<SubcontractGridRow>(
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
    if (cfg.itemHasStockPlace)
      EditableGridColumn<SubcontractGridRow>(
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
      EditableGridColumn<SubcontractGridRow>(
        key: 'supplier',
        label: '委外商',
        width: 150,
        required: supplierRequired,
        textOf: (r) => supplierEntries[r.supplierId] ?? '',
        listenableOf: (r) => r.supplierIdNotifier,
        cellBuilder: (context, row) => ValueListenableBuilder<Set<String>>(
          valueListenable: row.termsAutofilledNotifier,
          builder: (_, marks, _) => ValueListenableBuilder<String?>(
            valueListenable: row.supplierIdNotifier,
            builder: (_, v, _) => ProcurementSupplierCell(
              value: v,
              fallback: headerSupplierId,
              entries: supplierEntries,
              requiredEmpty: supplierRequired && v == null,
              autofilled: marks.contains('supplier'),
              onPick: onPickSupplier == null ? null : () => onPickSupplier(row),
            ),
          ),
        ),
      ),
    EditableGridColumn<SubcontractGridRow>(
      key: 'qty',
      label: '数量',
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
    // 单位紧跟数量（2026-09-04 口径）：单位已表达重量，实际重量列下线。
    EditableGridColumn<SubcontractGridRow>(
      key: 'unit',
      label: '单位',
      width: 84,
      textOf: (r) => unitEntries[r.unitId] ?? '',
      cellBuilder: (context, row) => Text(
        unitEntries[row.unitId] ?? (row.unitId == null ? '未维护' : row.unitId!),
        style: TextStyle(
          color: row.unitId == null
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
    if (cfg.itemHasPrice)
      EditableGridColumn<SubcontractGridRow>(
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
    // 订货单行级商业条款（2026-09）：单头不再录，逐行选择/填写，保存按组合拆单。
    if (showCommercial)
      ...procurementCommercialColumns<SubcontractGridRow>(
        currencyEntries: currencyEntries,
        settlementEntries: settlementEntries,
        settlementLabel: '结算方式',
        onPickCurrency: onPickCurrency ?? (row) => (value) {},
        onPickSettlement: onPickSettlement ?? (row) => (value) {},
      ),
    // 每行末尾备注列：随行提交 remark。
    if (showRemark) procurementRemarkColumn<SubcontractGridRow>(),
  ];
}
