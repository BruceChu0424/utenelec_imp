// 采购单据明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// PurchaseGridRow：货品(选择)/数量/单位/单价→金额自动（AmountRowMixin）；
// 颜色/单位换算率/上游明细 id
// 为透传（从上游引入或详情回填时预填，保存时随行写回，UI 不单独编辑）。
// 2026-09-04 口径：实际重量不再录入（单位已表达重量，行模型 weight 字段保留
// 供既有单回填/保存透传），单位列紧跟数量之后。
// purchaseGridColumns：货品/数量/单价/金额 四列。
import 'package:flutter/material.dart';
import '../../../shared/business_columns/business_columns_row.dart';
import '../../../shared/drafts/form_draft_values.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/inputs/required_field_decoration.dart'
    show applyAutofillHint;
import '../../../components/inputs/uten_input_decoration.dart';

import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/procurement_commercial_grid.dart';
import '../../../shared/widgets/procurement_supplier_cell.dart';
import '../models/purchase_doc.dart' show PurchaseSourceRequestRef;
import 'doc_link_picker.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/pricing/line_pricing_controller.dart';
import '../../../shared/pricing/line_pricing_amount_cell.dart';

/// 「允许超收%」输入解析（ADR-144）：空 = 未填(不允许超收，按 0%)，有效；
/// 填了须是 0 到 100 的数，提交值按两位小数（服务端 NUMERIC(5,2)）。
({double? value, bool valid}) parsePurchaseOverReceiptPct(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return (value: null, valid: true);
  final parsed = double.tryParse(text);
  if (parsed == null || !parsed.isFinite || parsed < 0 || parsed > 100) {
    return (value: null, valid: false);
  }
  return (value: double.parse(parsed.toStringAsFixed(2)), valid: true);
}

/// 采购明细行。货品用 [ValueNotifier]（点选后单元格自动刷新，无需 setState）；
/// 数量/单价控制器变更 → 自动重算金额（amountNotifier）。
/// 2026-09 起：币种/汇率/税率/结账方式与备注为行级（订货单），见
/// [CommercialTermsRowMixin]/[RemarkRowMixin]。
class PurchaseGridRow extends EditableGridRow
    with
        AmountRowMixin,
        CommercialTermsRowMixin,
        RemarkRowMixin,
        BusinessColumnsRow {
  PurchaseGridRow({
    this.sourceLocked = false,
    this.supportsTotalInput = false,
  }) {
    pricing = LinePricingController(
      qty: qty,
      price: price,
      supportsTotalInput: supportsTotalInput,
      extraColumns: () => extraColumnSnapshots,
      extraColumnsChanged: extraColumnsChanged,
      canCalculatePrice: () => supportsTotalInput || upstreamItemId == null,
      canCalculateQuantity: () => supportsTotalInput || upstreamItemId == null,
    )..addListener(_recalc);
    // 查重标红（保存前查重被拦回时标记）：改动货品/数量/单价/供应商即消除，
    // 下次保存重新判定。
    goodsNotifier.addListener(_clearFlagged);
    qty.addListener(_clearFlagged);
    price.addListener(_clearFlagged);
    supplierIdNotifier.addListener(_clearFlagged);
    remark.addListener(_clearFlagged);
  }

  /// 清除整行查重标红（[EditableGridRow.flagged]）。
  void _clearFlagged() {
    if (flaggedNotifier.value) flaggedNotifier.value = false;
  }

  final bool sourceLocked;
  final bool supportsTotalInput;
  late final LinePricingController pricing;
  double? maxQty;
  final ValueNotifier<GoodsOption?> goodsNotifier = ValueNotifier<GoodsOption?>(
    null,
  );
  GoodsOption? get goods => goodsNotifier.value;
  set goods(GoodsOption? v) => goodsNotifier.value = v;

  final TextEditingController qty = TextEditingController();
  final TextEditingController weight = TextEditingController();
  final TextEditingController price = TextEditingController();

  /// 订货明细允许超收%（ADR-144）：货品主档记忆预填带黄标；用户改成别的值即清黄标。
  /// 空 = 不允许超收(按 0%)。
  final TextEditingController allowedOverReceiptPct = TextEditingController();
  String? _allowedOverReceiptAutofillValue;
  bool _allowedOverReceiptWatchAttached = false;

  /// 标记允许超收为主档记忆带入值（黄框提醒核对）；改动≠带入值时自动清除。
  void markAllowedOverReceiptAutofilled(String value) {
    _allowedOverReceiptAutofillValue = value;
    markTermsAutofilled('allowedOverReceipt', value);
    if (!_allowedOverReceiptWatchAttached) {
      _allowedOverReceiptWatchAttached = true;
      allowedOverReceiptPct.addListener(_checkAllowedOverReceiptAutofill);
    }
  }

  void _checkAllowedOverReceiptAutofill() {
    if (termsAutofilled.contains('allowedOverReceipt') &&
        allowedOverReceiptPct.text != _allowedOverReceiptAutofillValue) {
      clearTermsAutofilled('allowedOverReceipt');
    }
  }

  /// 本行当前货品的允许超收预填机会已用过(ADR-144)：每行每个货品只按主档记忆
  /// 预填一次。之后留空(用户清掉 / 已存单据本来就空)就是「不允许超收(按 0%)」，
  /// 加行、引入申请等再跑预填也不会把它填回去。随填写草稿保存与恢复；
  /// 只有换货品([resetAllowedOverReceiptForGoods])才重新给一次机会。
  bool overReceiptPrefillConsumed = false;

  /// 换货品前调用：货品真的变了才重置预填机会；旧货品带入(黄标)的比例一并清掉，
  /// 让新货品按自己的记忆预填(没有记忆就留空 = 不允许超收)。用户自己填的比例保留。
  void resetAllowedOverReceiptForGoods(String? nextGoodsId) {
    if (goods?.id == nextGoodsId) return;
    overReceiptPrefillConsumed = false;
    if (termsAutofilled.contains('allowedOverReceipt')) {
      allowedOverReceiptPct.clear();
      clearTermsAutofilled('allowedOverReceipt');
    }
  }

  /// 库位号（只读，货品主档带出；收货上架/退货拣货指引，异步补全后自动刷新）。
  final ValueNotifier<String?> stockPlaceNotifier = ValueNotifier<String?>(
    null,
  );

  /// 上游明细 id（引入时回填，保存时按 cfg.linkTo* 映射为
  /// requestItemId/orderItemId/receiptItemId）。
  String? documentItemId;
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

  /// 从上游引入项构造（货品/数量/单价/upstream/颜色/单位 预填）。
  factory PurchaseGridRow.fromLinked(
    LinkedItem li,
    GoodsOption goods, {
    bool supportsTotalInput = false,
  }) {
    final r =
        PurchaseGridRow(
            sourceLocked: true,
            supportsTotalInput: supportsTotalInput,
          )
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
    r.qty.text = financeExactTrimmed(li.qty.toString()) ?? '';
    if (li.price != null) {
      r.price.text = financeExactTrimmed(li.price.toString()) ?? '';
    }
    return r;
  }

  /// 原币总金额预览：按单价派生，或采用原始总额；来源分摊认服务端记录。
  final ValueNotifier<String?> amountExactNotifier = ValueNotifier<String?>(
    null,
  );

  String? _sourceAmount;
  String? _sourceQty;
  String? _sourcePrice;
  String? _sourceColumns;
  bool get hasSourceAmount => !supportsTotalInput && upstreamItemId != null;
  bool get sourceAmountPending =>
      hasSourceAmount &&
      (_sourceAmount == null ||
          _sourceQty != financeExactTrimmed(qty.text) ||
          _sourcePrice != financeExactTrimmed(price.text) ||
          (_sourceColumns != null && _sourceColumns != extraColumnsSignature));

  /// Source amounts are allocated by the server; a reference price is not a valuation basis.
  void recordSourceAmount(String? amount) {
    _sourceAmount = financeExactDecimal(amount);
    _sourceQty = financeExactTrimmed(qty.text);
    _sourcePrice = financeExactTrimmed(price.text);
    _sourceColumns = extraColumnsSignature;
    _recalc();
  }

  void _recalc() {
    if (pricing.mode != LinePricingMode.calculateAmount &&
        termsAutofilled.contains('price')) {
      clearTermsAutofilled('price');
    }
    amountExactNotifier.value = sourceAmountPending
        ? null
        : hasSourceAmount
        ? _sourceAmount
        : pricing.amountExact;
    recalcAmount(() => double.tryParse(amountExactNotifier.value ?? '') ?? 0);
  }

  Map<String, TextEditingController> get _draftTextControllers => {
    'qty': qty,
    'weight': weight,
    'price': price,
    'allowedOverReceiptPct': allowedOverReceiptPct,
    'remark': remark,
  };

  Iterable<Listenable> get draftListenables => [
    pricing,
    ..._draftTextControllers.values,
    ...extraColumnListenables,
    goodsNotifier,
    stockPlaceNotifier,
    supplierIdNotifier,
    currencyIdNotifier,
    settlementMethodIdNotifier,
    termsAutofilledNotifier,
    exchangeRate,
    taxRate,
  ];

  Map<String, dynamic> exportDraft() => {
    'sourceAmount': _sourceAmount,
    'sourceQty': _sourceQty,
    'sourcePrice': _sourcePrice,
    'sourceColumns': _sourceColumns,
    'pricing': pricing.exportState(),
    'supportsTotalInput': supportsTotalInput,
    'text': draftTextValues(_draftTextControllers),
    'extraColumns': exportExtraColumns(),
    'documentItemId': documentItemId,
    'goods': draftGoods(goods),
    'stockPlace': stockPlaceNotifier.value,
    'unitRate': unitRate,
    'upstreamItemId': upstreamItemId,
    'sourceDocNo': sourceDocNo,
    'sourceRequestNo': sourceRequestNo,
    'sourceRequestId': sourceRequestId,
    'colorId': colorId,
    'unitId': unitId,
    'supplierId': supplierId,
    'sourceLocked': sourceLocked,
    'maxQty': maxQty,
    'overReceiptPrefillConsumed': overReceiptPrefillConsumed,
    'upstreamItemIds': [...upstreamItemIds],
    'commercial': exportCommercialDraft(),
    'sourceDocs': [
      for (final source in sourceDocs)
        {
          'requestItemId': source.requestItemId,
          'requestId': source.requestId,
          'billNo': source.billNo,
        },
    ],
  };

  factory PurchaseGridRow.fromDraft(
    Map<String, dynamic> data, {
    bool supportsTotalInput = false,
  }) {
    final row =
        PurchaseGridRow(
            sourceLocked: data['sourceLocked'] == true,
            supportsTotalInput:
                supportsTotalInput || data['supportsTotalInput'] == true,
          )
          ..documentItemId = data['documentItemId'] as String?
          ..goods = restoreDraftGoods(data['goods'])
          ..stockPlaceNotifier.value = data['stockPlace'] as String?
          ..unitRate = (data['unitRate'] as num?)?.toDouble()
          ..upstreamItemId = data['upstreamItemId'] as String?
          ..sourceDocNo = data['sourceDocNo'] as String?
          ..sourceRequestNo = data['sourceRequestNo'] as String?
          ..sourceRequestId = data['sourceRequestId'] as String?
          ..colorId = data['colorId'] as String?
          ..unitId = data['unitId'] as String?
          ..supplierId = data['supplierId'] as String?;
    restoreDraftTextValues(row._draftTextControllers, draftMap(data['text']));
    row.restoreExtraColumns(data['extraColumns']);
    row.maxQty = (data['maxQty'] as num?)?.toDouble();
    row.overReceiptPrefillConsumed = data['overReceiptPrefillConsumed'] == true;
    row.upstreamItemIds = draftStrings(data['upstreamItemIds']);
    row.sourceDocs = draftMaps(
      data['sourceDocs'],
    ).map(PurchaseSourceRequestRef.fromJson).toList();
    row.restoreCommercialDraft(
      draftMap(data['commercial']),
      price: row.price,
      supplier: row.supplierIdNotifier,
      currentGoodsId: () => row.goods?.id,
      currentColorId: () => row.colorId,
      currentUnitId: () => row.unitId,
    );
    if (row.termsAutofilled.contains('allowedOverReceipt')) {
      row.markAllowedOverReceiptAutofilled(row.allowedOverReceiptPct.text);
    }
    row.pricing.restoreState(data['pricing']);
    row._sourceAmount = data['sourceAmount'] as String?;
    row._sourceQty = data['sourceQty'] as String?;
    row._sourcePrice = data['sourcePrice'] as String?;
    row._sourceColumns = data['sourceColumns'] as String?;
    row._recalc();
    return row;
  }

  /// 深拷贝（明细复制/粘贴用）：拷用户录入（数量/重量/单价/行供应商/行级商业条款/
  /// 备注）与货品主档透传描述（颜色/单位/换算率/库位显示）。不拷上游明细 id、来源谱系、
  /// 数量门控 maxQty——粘贴行是自由新明细，不得双引用上游行；sourceLocked
  /// 也不拷（无上游绑定的行可改货品）。
  PurchaseGridRow clone() {
    final c = PurchaseGridRow(supportsTotalInput: supportsTotalInput)
      ..goods = goods
      ..stockPlaceNotifier.value = stockPlaceNotifier.value
      ..colorId = colorId
      ..unitId = unitId
      ..unitRate = unitRate
      ..supplierId = supplierId;
    copyExtraColumnsTo(c);
    c.qty.text = qty.text;
    c.weight.text = weight.text;
    c.price.text = price.text;
    c.allowedOverReceiptPct.text = allowedOverReceiptPct.text;
    // 同货品的复制行沿用原行的预填状态：原行清空(不允许超收)的，复制行也不回填。
    c.overReceiptPrefillConsumed = overReceiptPrefillConsumed;
    c.copyCommercialFrom(this);
    c.copyDefaultPriceFrom(
      this,
      price: c.price,
      supplier: c.supplierIdNotifier,
      currentGoodsId: () => c.goods?.id,
      currentColorId: () => c.colorId,
      currentUnitId: () => c.unitId,
    );
    c.remark.text = remark.text;
    pricing.copyStateTo(c.pricing);
    return c;
  }

  @override
  void dispose() {
    pricing.dispose();
    goodsNotifier.dispose();
    amountExactNotifier.dispose();
    qty.dispose();
    weight.dispose();
    price.dispose();
    allowedOverReceiptPct.dispose();
    stockPlaceNotifier.dispose();
    supplierIdNotifier.dispose();
    super.dispose();
  }
}

/// 采购明细列：货品（点选）/ 数量 / 单价 / 金额（自动）。
/// [onPickGoods] 由编辑页提供（弹货品选择器并写回 row.goods）。
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
/// [showAllowedOverReceipt]（订货单，ADR-144）：金额列后加「允许超收%」列
/// （货品主档记忆预填带黄标，改值即清）。
/// 列序（2026-09-04 口径）：数量之后紧跟单位（实际重量列已下线，行模型 weight
/// 字段保留供既有单回填/保存透传）。
List<EditableGridColumn<PurchaseGridRow>> purchaseGridColumns(
  Future<void> Function(PurchaseGridRow row) onPickGoods, {
  required BuildContext context,
  List<PurchaseGridRow> rows = const [],
  bool showStockPlace = false,
  bool showSource = false,
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
  bool showAllowedOverReceipt = false,
}) {
  final showSupplier = supplierEntries.isNotEmpty;
  // 列说明统一挂表头 ⓘ（2026-09-09 口径）：每行重复的 ⓘ 既冗余又挤占格宽。
  final l10n = workflowFieldText(context);
  // 货品身份列的颜色名（2026-09-14 口径）：行模型只透传 colorId，这里按需解析。
  // 延迟到取值/渲染时才读字典容器——列定义本身不碰 Provider，裸 MaterialApp
  // 构列的列序契约测试不受影响。未维护颜色返回 null（身份格自然省略，不占位）。
  String? colorNameOf(PurchaseGridRow row) {
    final id = row.colorId;
    if (id == null || id.isEmpty) return null;
    final name = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(masterNameServiceProvider).color(id);
    return name == '—' ? null : name;
  }

  return [
    EditableGridColumn<PurchaseGridRow>(
      key: 'goods',
      label: '货品名称',
      width: 200,
      required: true,
      // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色**各占一列**，
      // 不把编号颜色拼进名称格——拼在一起既不能各自排序筛选，列窄时编号还先
      // 被省略号吃掉。这里只放名称，编号与颜色见紧随其后的两列。
      textOf: (r) => r.goods?.name ?? '',
      listenableOf: (r) => r.goodsNotifier,
      // 格尾搜索/锁图标(16)计入自动加宽量宽（2026-09-16），不再吃文本宽。
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
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
                    builder: (context, g, _) => g == null
                        ? Text(
                            '点击选择',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          )
                        : UtenGoodsIdentityCell(name: g.name),
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
    EditableGridColumn<PurchaseGridRow>(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      textOf: (r) => r.goods?.code ?? '',
      listenableOf: (r) => r.goodsNotifier,
      cellBuilder: (context, row) => ValueListenableBuilder<GoodsOption?>(
        valueListenable: row.goodsNotifier,
        builder: (context, goods, _) => UtenGoodsAttributeCell(goods?.code),
      ),
    ),
    EditableGridColumn<PurchaseGridRow>(
      key: 'colorName',
      label: '颜色',
      width: 110,
      textOf: (r) => colorNameOf(r) ?? '',
      listenableOf: (r) => r.goodsNotifier,
      cellBuilder: (context, row) => ValueListenableBuilder<GoodsOption?>(
        valueListenable: row.goodsNotifier,
        builder: (context, _, _) => UtenGoodsAttributeCell(colorNameOf(row)),
      ),
    ),
    if (showSource)
      EditableGridColumn<PurchaseGridRow>(
        key: 'source',
        label: '申请来源',
        width: 150,
        textOf: (r) => r.sourceDocsLabel,
        // 可点行尾的外链图标(12+间距)计入量宽。
        chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
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
    if (showSupplier)
      EditableGridColumn<PurchaseGridRow>(
        key: 'supplier',
        label: '供应商',
        width: 170,
        required: supplierRequired,
        // 展开箭头(20) + 学习预填黄标 ⓘ(44) 都计入自动加宽量宽（2026-09-10）。
        chromeWidth:
            UtenEditableGridCellSpec.dropdownChevronWidth +
            UtenEditableGridCellSpec.hintIconWidth,
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
    EditableGridColumn<PurchaseGridRow>(
      key: 'qty',
      label: '数量',
      width: 128,
      numeric: true,
      required: true,
      headerInfo: l10n.workflowQuantityHint,
      frozenTextOf: (r) => r.qty.text,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.qty,
        isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
        child: TextField(
          controller: row.qty,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const UtenInputDecoration(
            InputDecoration(isDense: true, hintText: '0'),
          ),
        ),
      ),
    ),
    // 单位紧跟数量（2026-09-04 口径）：单位已表达重量，实际重量列下线。
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
    EditableGridColumn<PurchaseGridRow>(
      key: 'price',
      label: '单价',
      width: 128,
      numeric: true,
      required: true,
      headerInfo: l10n.workflowPriceHint,
      frozenTextOf: (r) => r.price.text,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.price,
        isEmpty: () =>
            row.price.text.trim().isEmpty ||
            double.tryParse(row.price.text.trim()) == null,
        child: TextField(
          controller: row.price,
          onChanged: (_) => row.clearTermsAutofilled('price'),
          onSubmitted: (_) => row.clearTermsAutofilled('price'),
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const UtenInputDecoration(
            InputDecoration(isDense: true, hintText: '0'),
          ),
        ),
      ),
    ),
    EditableGridColumn<PurchaseGridRow>(
      key: 'amount',
      label: '总金额',
      width: 190,
      numeric: true,
      headerInfo: linePricingAmountHeaderHint,
      textOf: (r) => r.hasSourceAmount
          ? (r.amountExactNotifier.value ?? '')
          : r.pricing.totalAmount.text,
      listenableOf: (r) => r.pricing,
      frozenTextOf: (r) => r.amountExactNotifier.value == null
          ? ''
          : '¥${financeExactMoneyDisplay(r.amountExactNotifier.value!)}',
      cellBuilder: (context, row) => row.hasSourceAmount
          ? ValueListenableBuilder<String?>(
              valueListenable: row.amountExactNotifier,
              builder: (_, amount, _) => Tooltip(
                message: '按来源单据总金额分摊，保存时由服务端计算',
                child: Text(
                  amount == null
                      ? '保存后按来源计算'
                      : financeExactMoneyDisplay(amount),
                ),
              ),
            )
          : LinePricingAmountCell(controller: row.pricing),
    ),
    // ADR-144 允许超收%（订货单）：货品主档记忆预填（黄标提醒核对，改值即清）；
    // 累计收货在 数量×(1+允许超收) 以内照常入库立应付，超出部分才转财务。空 = 0%。
    if (showAllowedOverReceipt)
      EditableGridColumn<PurchaseGridRow>(
        key: 'allowedOverReceiptPct',
        label: '允许超收%',
        width: 120,
        numeric: true,
        headerInfo:
            '供应商送货允许多于订货量的比例。例如填 5，订 100 件累计最多可收 105 件，'
            '在这以内照常入库、立应付；超过的部分才转财务审批。留空 = 不允许超收(按 0%)。'
            '按货品主档记忆预填，保存后记住本次填写值；财务批准后不能再改。',
        textOf: (r) => r.allowedOverReceiptPct.text,
        listenableOf: (r) => r.allowedOverReceiptPct,
        cellBuilder: (context, row) => ValueListenableBuilder<Set<String>>(
          valueListenable: row.termsAutofilledNotifier,
          builder: (context, marks, _) => TextField(
            key: ValueKey('purchase-allowed-over-receipt-${row.hashCode}'),
            controller: row.allowedOverReceiptPct,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: applyAutofillHint(
              const UtenInputDecoration(
                InputDecoration(isDense: true, hintText: '0'),
              ),
              Theme.of(context),
              autofilled: marks.contains('allowedOverReceipt'),
            ),
          ),
        ),
      ),
    // 订货单行级商业条款（2026-09）：单头不再录，逐行选择/填写，保存按组合拆单。
    if (showCommercial)
      ...procurementCommercialColumns<PurchaseGridRow>(
        context: context,
        currencyEntries: currencyEntries,
        settlementEntries: settlementEntries,
        onPickCurrency: onPickCurrency ?? (row) => (value) {},
        onPickSettlement: onPickSettlement ?? (row) => (value) {},
      ),
    // 每行末尾备注列：随行提交 remark。
    if (showRemark) procurementRemarkColumn<PurchaseGridRow>(),
    ...businessEditableColumns<PurchaseGridRow>(
      businessColumnsOf(rows),
      rowOf: (row) => row,
      amountHint: l10n.businessColumnAmountHint,
    ),
  ];
}
