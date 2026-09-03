// 采购单据明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// PurchaseGridRow：货品(选择)/单位/数量/实际重量/单价→金额自动（AmountRowMixin）；
// 颜色/单位换算率/上游明细 id
// 为透传（从上游引入或详情回填时预填，保存时随行写回，UI 不单独编辑）。
// purchaseGridColumns：货品/数量/单价/金额 四列。
import 'package:flutter/material.dart';

import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/procurement_commercial_grid.dart';
import '../../../shared/widgets/procurement_supplier_cell.dart';
import '../models/purchase_doc.dart' show PurchaseSourceRequestRef;
import 'doc_link_picker.dart';

/// 采购明细行。货品用 [ValueNotifier]（点选后单元格自动刷新，无需 setState）；
/// 数量/单价控制器变更 → 自动重算金额（amountNotifier）。
/// 2026-09 起：币种/汇率/税率/结账方式与备注为行级（订货单），见
/// [CommercialTermsRowMixin]/[RemarkRowMixin]。
class PurchaseGridRow extends EditableGridRow
    with AmountRowMixin, CommercialTermsRowMixin, RemarkRowMixin {
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
  final TextEditingController weight = TextEditingController();
  final TextEditingController price = TextEditingController();

  /// 库位号（只读，货品主档带出；收货上架/退货拣货指引，异步补全后自动刷新）。
  final ValueNotifier<String?> stockPlaceNotifier = ValueNotifier<String?>(
    null,
  );

  /// 上游明细 id（引入时回填，保存时按 cfg.linkTo* 映射为
  /// requestItemId/orderItemId/receiptItemId）。
  String? upstreamItemId;

  /// 全部来源申请明细 id（V463 同货品合并行，含 [upstreamItemId] 首来源，
  /// 顺序=服务端 FIFO 分配顺序）；保存时 >1 条随行提交 requestItemIds。
  /// 空列表 = 无来源/手工行。
  List<String> upstreamItemIds = [];

  /// 来源申请引用（合并行多来源展示与跳详情）：与 [upstreamItemIds] 对齐。
  List<PurchaseSourceRequestRef> sourceDocs = [];

  /// 申请来源列显示：多来源单号顿号连接；无 sourceDocs 时退回单来源谱系。
  String get sourceDocsLabel {
    final nos = sourceDocs
        .map((doc) => doc.billNo)
        .whereType<String>()
        .where((no) => no.isNotEmpty)
        .toList();
    if (nos.isNotEmpty) return nos.join('、');
    return sourceRequestNo ?? '';
  }

  /// 是否存在可跳转的来源申请详情（任一来源带回申请单 id）。
  bool get canOpenSourceDocs =>
      sourceDocs.any((doc) => doc.requestId?.isNotEmpty == true) ||
      (sourceRequestId?.isNotEmpty == true);

  /// 来源单据编号谱系（到货登记=来源订货单号；与委外进仓口径一致，随行提交留痕）。
  String? sourceDocNo;

  /// 申请来源（订货单明细列展示）：来源采购申请的单号 + 单据 id。
  /// 任务中心带单新建/「从上游引入」时自动回填，点击单号跳申请详情；
  /// 纯前端展示不随保存提交（订单行 sourceDocNo 谱系由服务端按申请行继承计划号）。
  String? sourceRequestNo;
  String? sourceRequestId;
  String? colorId;
  String? unitId;
  double? unitRate;

  /// 明细级供应商（订货单可逐行选不同供应商，保存时按供应商自动拆单；为空回落表头）。
  /// ValueNotifier：多选统一设供应商/记忆预填后单元格与必填红框即时刷新。
  final ValueNotifier<String?> supplierIdNotifier = ValueNotifier<String?>(
    null,
  );
  String? get supplierId => supplierIdNotifier.value;
  set supplierId(String? v) => supplierIdNotifier.value = v;

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

  /// 深拷贝（明细复制/粘贴用）：拷用户录入（数量/重量/单价/行供应商/行级商业条款/
  /// 备注）与货品主档透传描述（颜色/单位/换算率/库位显示）。不拷上游明细 id、来源谱系、
  /// 到货门控（maxQty/approvedQty）——粘贴行是自由新明细，不得双引用上游行；sourceLocked
  /// 也不拷（无上游绑定的行可改货品）。
  PurchaseGridRow clone() {
    final c = PurchaseGridRow()
      ..goods = goods
      ..stockPlaceNotifier.value = stockPlaceNotifier.value
      ..colorId = colorId
      ..unitId = unitId
      ..unitRate = unitRate
      ..supplierId = supplierId;
    c.qty.text = qty.text;
    c.weight.text = weight.text;
    c.price.text = price.text;
    c.copyCommercialFrom(this);
    c.remark.text = remark.text;
    return c;
  }

  @override
  void dispose() {
    goodsNotifier.dispose();
    qty.dispose();
    weight.dispose();
    price.dispose();
    stockPlaceNotifier.dispose();
    supplierIdNotifier.dispose();
    super.dispose();
  }
}

/// 采购明细列：货品（点选）/ 数量 / 单价 / 金额（自动）。
/// [onPickGoods] 由编辑页提供（弹货品选择器并写回 row.goods）。
/// [arrivalMode]=true（预计到货「登记实际到货」预填场景）：列改为
/// 货品 / 批准剩余（只读对照）/ 实到数量——不显示单价/金额，仓库只关心到货数量。
/// [supplierEntries]+[onPickSupplier]：订货单显示「供应商」明细列（逐行选不同供应商，
/// 保存时按供应商自动拆单）；收货/退货不传，沿用表头单一供应商。点击单元格由
/// [onPickSupplier] 打开供应商滑入面板，页面按多选范围落值（联动填写）。
/// [supplierRequired]：订货单行级供应商必填（表头不再录入）→ 列头红 * + 空值红字提示。
/// [showStockPlace]（收货/退货实物单据）：货品列后加「库位号」只读列（主档带出，上架/拣货指引）。
/// [showSource]+[onOpenSource]（订货单）：货品列后加「申请来源」只读列，引入行自动回填
/// 来源申请单号；点击单号由 [onOpenSource] 跳申请详情（无来源 id 时退化为纯文本）。
/// [showCommercial]+[currencyEntries]/[settlementEntries]/[onPickCurrency]/[onPickSettlement]
/// （订货单）：金额列后加「币种/汇率/税率/结账方式」四列（行级商业条款，保存按组合拆单）。
/// [showRemark]：明细末尾加「备注」列（随行提交 remark）。
/// [unitAfterWeight]（订货单，2026-09-03 用户口径）：单位列放在「实际重量」之后
///（货品/来源/供应商之后紧跟数量、重量、单位、单价…）；默认 false 时单位在供应商前
///（申请/收货/退货原布局不变）。
List<EditableGridColumn<PurchaseGridRow>> purchaseGridColumns(
  Future<void> Function(PurchaseGridRow row) onPickGoods, {
  bool arrivalMode = false,
  bool showStockPlace = false,
  bool showSource = false,
  bool unitAfterWeight = false,
  Map<String, String> unitEntries = const {},
  Map<String, String> supplierEntries = const {},
  bool supplierRequired = false,
  String? headerSupplierId,
  Future<void> Function(PurchaseGridRow row)? onPickSupplier,
  void Function(PurchaseGridRow row)? onOpenSource,
  bool showCommercial = false,
  Map<String, String> currencyEntries = const {},
  Map<String, String> settlementEntries = const {},
  ValueChanged<String?> Function(PurchaseGridRow row)? onPickCurrency,
  ValueChanged<String?> Function(PurchaseGridRow row)? onPickSettlement,
  bool showRemark = false,
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
    if (showSource)
      EditableGridColumn<PurchaseGridRow>(
        key: 'source',
        label: '申请来源',
        width: 150,
        textOf: (r) => r.sourceDocsLabel,
        cellBuilder: (context, row) {
          final no = row.sourceDocsLabel;
          if (no.isEmpty) {
            return Text(
              '—',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            );
          }
          // 有来源单据 id 才可点跳详情；任务/接口未带回 id 时退化为纯文本谱系。
          final canOpen = row.canOpenSourceDocs;
          final theme = Theme.of(context);
          return InkWell(
            onTap: canOpen && onOpenSource != null
                ? () => onOpenSource(row)
                : null,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      no,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: canOpen
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                        decoration: canOpen ? TextDecoration.underline : null,
                        decorationColor: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  if (canOpen) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.open_in_new,
                      size: 12,
                      color: theme.colorScheme.primary,
                    ),
                  ],
                ],
              ),
            ),
          );
        },
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
    if (!unitAfterWeight)
      EditableGridColumn<PurchaseGridRow>(
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
    if (showSupplier)
      EditableGridColumn<PurchaseGridRow>(
        key: 'supplier',
        label: '供应商',
        width: 150,
        required: supplierRequired,
        textOf: (r) => supplierEntries[r.supplierId] ?? '',
        listenableOf: (r) => r.supplierIdNotifier,
        cellBuilder: (context, row) => ValueListenableBuilder<String?>(
          valueListenable: row.supplierIdNotifier,
          builder: (_, v, _) => ProcurementSupplierCell(
            value: v,
            fallback: headerSupplierId,
            entries: supplierEntries,
            requiredEmpty: supplierRequired && v == null,
            onPick: onPickSupplier == null ? null : () => onPickSupplier(row),
          ),
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
    EditableGridColumn<PurchaseGridRow>(
      key: 'weight',
      label: '实际重量',
      width: 104,
      numeric: true,
      cellBuilder: (context, row) => TextField(
        controller: row.weight,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(isDense: true, hintText: '可选'),
      ),
    ),
    // 订货单口径（2026-09-03）：单位列紧跟「实际重量」之后。
    if (unitAfterWeight)
      EditableGridColumn<PurchaseGridRow>(
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
    // 订货单行级商业条款（2026-09）：单头不再录，逐行选择/填写，保存按组合拆单。
    if (showCommercial && !arrivalMode)
      ...procurementCommercialColumns<PurchaseGridRow>(
        currencyEntries: currencyEntries,
        settlementEntries: settlementEntries,
        onPickCurrency: onPickCurrency ?? (row) => (value) {},
        onPickSettlement: onPickSettlement ?? (row) => (value) {},
      ),
    // 每行末尾备注列：随行提交 remark。
    if (showRemark) procurementRemarkColumn<PurchaseGridRow>(),
  ];
}
