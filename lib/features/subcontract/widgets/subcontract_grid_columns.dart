import '../../../shared/pricing/procurement_price_check.dart';
// 委外单据明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// 与采购 purchase_grid_columns 同构（货品 ValueNotifier / 数量 / 单价→金额自动），
// 但委外 8 单据差异更大，列由 SubcontractDocConfig 显隐：
//  - 货品 / 数量 永远在；数量内联单位(2026-10-10 口径：单位放输入框 suffixText，
//    独立单位列已删)；
//  - 单价 / 金额 仅 itemHasPrice（询价/申请/订货/进仓/退货）；
//  - 重量列已下线（2026-09-04：单位已表达重量；itemHasWeight 仍驱动保存透传）；
//  围数 itemHasGirth；胶箱数 itemHasBoxQty；
//  - 损耗 4 列（标准用量/结存数/损耗率/损耗原因）仅 itemHasWasteFields（损耗单）。
// 颜色/单位/上游明细 id 为透传（引入或回填时预填，保存时随行写回，UI 不单独编辑）。
import 'package:flutter/material.dart';
import 'package:uten_imp/components/inputs/uten_field_placeholder.dart';
import '../../../shared/business_columns/business_columns_row.dart';
import '../../../shared/drafts/form_draft_values.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/inputs/required_field_decoration.dart'
    show applyAutofillHint;
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_multi_value_cell.dart';

import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/providers/master_name_provider.dart'
    show GoodsOption, masterNameServiceProvider;
import '../../../shared/widgets/procurement_commercial_grid.dart';
import '../../../shared/widgets/procurement_document_layout.dart';
import '../../../shared/widgets/procurement_supplier_cell.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart' show SubcontractSourceApplicationRef;
import 'subcontract_link_picker.dart' show LinkedItem;
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/pricing/line_pricing_controller.dart';
import '../../../shared/pricing/line_pricing_amount_cell.dart';

/// 委外明细行。货品用 [ValueNotifier]（点选后单元格自动刷新，无需 setState）；
/// 数量/单价控制器变更 → 自动重算金额（amountNotifier，仅 itemHasPrice 时有意义）。
/// 2026-09 起：币种/汇率/税率/结算方式与备注为行级（订货单），见
/// [CommercialTermsRowMixin]/[RemarkRowMixin]。
class SubcontractGridRow extends EditableGridRow
    with
        AmountRowMixin,
        CommercialTermsRowMixin,
        RemarkRowMixin,
        BusinessColumnsRow {
  SubcontractGridRow({
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
    // 查重标红（保存前查重被拦回时标记）：改动货品/数量/单价/委外商即消除，
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

  final ValueNotifier<GoodsOption?> goodsNotifier = ValueNotifier<GoodsOption?>(
    null,
  );
  GoodsOption? get goods => goodsNotifier.value;
  set goods(GoodsOption? v) {
    if (goods?.id != v?.id) unitRateText = null;
    goodsNotifier.value = v;
  }

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

  /// 订货明细允许损耗%（ADR-098）：货品主档记忆预填带黄标；用户改成别的值即清黄标。
  final TextEditingController allowedLossPct = TextEditingController();
  String? _allowedLossAutofillValue;

  /// 标记允许损耗为主档记忆带入值（黄框提醒核对）；改动≠带入值时自动清除。
  void markAllowedLossAutofilled(String value) {
    _allowedLossAutofillValue = value;
    markTermsAutofilled('allowedLoss', value);
    if (!_allowedLossWatchAttached) {
      _allowedLossWatchAttached = true;
      allowedLossPct.addListener(_checkAllowedLossAutofill);
    }
  }

  bool _allowedLossWatchAttached = false;

  void _checkAllowedLossAutofill() {
    if (termsAutofilled.contains('allowedLoss') &&
        allowedLossPct.text != _allowedLossAutofillValue) {
      clearTermsAutofilled('allowedLoss');
    }
  }

  /// 上游明细 id（引入时回填，保存时按 cfg.linkTo* 映射为
  /// applicationItemId/orderItemId/receiptItemId/materialIssueItemId）。
  String? documentItemId;
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
  double? _unitRate;
  double? get unitRate => _unitRate;
  set unitRate(double? value) {
    _unitRate = value;
    unitRateText = null;
  }

  String? unitRateText;
  String? sourceDocNo;

  /// 明细级委外商（订货单可逐行选不同委外商，保存时按委外商自动拆单；为空回落表头）。
  /// ValueNotifier：多选统一设委外商/记忆预填后单元格与必填提示即时刷新。
  final ValueNotifier<String?> supplierIdNotifier = ValueNotifier<String?>(
    null,
  );
  String? get supplierId => supplierIdNotifier.value;
  set supplierId(String? v) => supplierIdNotifier.value = v;

  /// 从上游引入项构造（货品/数量/单价/upstream/颜色/单位 预填）。
  factory SubcontractGridRow.fromLinked(
    LinkedItem li,
    GoodsOption goods, {
    bool supportsTotalInput = false,
  }) {
    final r =
        SubcontractGridRow(
            sourceLocked: li.upstreamItemId != null,
            supportsTotalInput: supportsTotalInput,
          )
          ..goods = goods
          ..upstreamItemId = li.upstreamItemId
          ..maxQty = li.maxQty
          ..colorId = li.colorId
          ..unitId = li.unitId
          ..unitRate = li.unitRate
          ..unitRateText = li.unitRateText;
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
  final bool supportsTotalInput;
  late final LinePricingController pricing;

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
    'price': price,
    'weight': weight,
    'girth': girth,
    'boxQty': boxQty,
    'endingQty': endingQty,
    'standardQty': standardQty,
    'wasteRate': wasteRate,
    'cause': cause,
    'allowedLossPct': allowedLossPct,
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
    'unitRateText': unitRateText,
    'upstreamItemId': upstreamItemId,
    'planItemId': planItemId,
    'colorId': colorId,
    'unitId': unitId,
    'sourceDocNo': sourceDocNo,
    'supplierId': supplierId,
    'sourceLocked': sourceLocked,
    'maxQty': maxQty,
    'upstreamItemIds': [...upstreamItemIds],
    'commercial': exportCommercialDraft(),
    'sourceDocs': [
      for (final source in sourceDocs)
        {
          'applicationItemId': source.applicationItemId,
          'applicationId': source.applicationId,
          'billNo': source.billNo,
        },
    ],
  };

  factory SubcontractGridRow.fromDraft(
    Map<String, dynamic> data, {
    bool supportsTotalInput = false,
  }) {
    final row =
        SubcontractGridRow(
            sourceLocked: data['sourceLocked'] == true,
            supportsTotalInput:
                supportsTotalInput || data['supportsTotalInput'] == true,
          )
          ..documentItemId = data['documentItemId'] as String?
          ..goods = restoreDraftGoods(data['goods'])
          ..stockPlaceNotifier.value = data['stockPlace'] as String?
          ..unitRate = (data['unitRate'] as num?)?.toDouble()
          ..unitRateText = data['unitRateText'] as String?
          ..upstreamItemId = data['upstreamItemId'] as String?
          ..planItemId = data['planItemId'] as String?
          ..colorId = data['colorId'] as String?
          ..unitId = data['unitId'] as String?
          ..sourceDocNo = data['sourceDocNo'] as String?
          ..supplierId = data['supplierId'] as String?;
    restoreDraftTextValues(row._draftTextControllers, draftMap(data['text']));
    row.restoreExtraColumns(data['extraColumns']);
    row.maxQty = (data['maxQty'] as num?)?.toDouble();
    row.upstreamItemIds = draftStrings(data['upstreamItemIds']);
    row.sourceDocs = draftMaps(
      data['sourceDocs'],
    ).map(SubcontractSourceApplicationRef.fromJson).toList();
    row.restoreCommercialDraft(
      draftMap(data['commercial']),
      price: row.price,
      supplier: row.supplierIdNotifier,
      currentGoodsId: () => row.goods?.id,
      currentColorId: () => row.colorId,
      currentUnitId: () => row.unitId,
    );
    if (row.termsAutofilled.contains('allowedLoss')) {
      row.markAllowedLossAutofilled(row.allowedLossPct.text);
    }
    row.pricing.restoreState(data['pricing']);
    row._sourceAmount = data['sourceAmount'] as String?;
    row._sourceQty = data['sourceQty'] as String?;
    row._sourcePrice = data['sourcePrice'] as String?;
    row._sourceColumns = data['sourceColumns'] as String?;
    row._recalc();
    return row;
  }

  /// 深拷贝（明细复制/粘贴用）：语义同 PurchaseGridRow.clone——拷用户录入（数量/
  /// 单价/重量/围数/胶箱数/行委外商/行级商业条款/备注/损耗单四列）与主档透传；
  /// 不拷上游 id、planItemId、来源谱系、数量门控 maxQty 与 sourceLocked。
  SubcontractGridRow clone() {
    final c = SubcontractGridRow(supportsTotalInput: supportsTotalInput)
      ..goods = goods
      ..stockPlaceNotifier.value = stockPlaceNotifier.value
      ..colorId = colorId
      ..unitId = unitId
      ..unitRate = unitRate
      ..unitRateText = unitRateText
      ..supplierId = supplierId;
    copyExtraColumnsTo(c);
    c.qty.text = qty.text;
    c.price.text = price.text;
    c.weight.text = weight.text;
    c.girth.text = girth.text;
    c.boxQty.text = boxQty.text;
    c.endingQty.text = endingQty.text;
    c.standardQty.text = standardQty.text;
    c.wasteRate.text = wasteRate.text;
    c.cause.text = cause.text;
    c.allowedLossPct.text = allowedLossPct.text;
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
    price.dispose();
    weight.dispose();
    girth.dispose();
    boxQty.dispose();
    stockPlaceNotifier.dispose();
    endingQty.dispose();
    standardQty.dispose();
    wasteRate.dispose();
    cause.dispose();
    allowedLossPct.dispose();
    supplierIdNotifier.dispose();
    super.dispose();
  }
}

/// 委外明细列：货品（点选）/ 数量(内联单位) / 单价? / 金额? / 围数? / 胶箱数? /
/// 损耗(标准用量?/结存数?/损耗率?/损耗原因?)，全部按 [cfg] 的 itemHas* 显隐。
/// [onPickGoods] 由编辑页提供（弹货品选择器并写回 row.goods）。
/// [showCommercial]+[currencyEntries]/[settlementEntries]/[onPickCurrency]/[onPickSettlement]
/// （订货单）：金额列后加「币种/汇率/税率/结算方式」四列（行级商业条款，保存按组合拆单）。
/// [showRemark]：明细末尾加「备注」列（随行提交 remark）。
/// 单位内联在数量输入框 suffixText（2026-10-10 口径，独立单位列已删）；实际重量列
/// 下线（cfg.itemHasWeight 仍驱动保存透传，行模型 weight 保留既有单回填/回写）。
List<EditableGridColumn<SubcontractGridRow>> subcontractGridColumns(
  Future<void> Function(SubcontractGridRow row) onPickGoods,
  SubcontractDocConfig cfg, {
  required BuildContext context,
  List<SubcontractGridRow> rows = const [],
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
  final showSupplier =
      cfg.hasSupplier && (supplierRequired || supplierEntries.isNotEmpty);
  // 列说明统一挂表头 ⓘ（2026-09-09 口径）：每行重复的 ⓘ 既冗余又挤占格宽。
  final l10n = workflowFieldText(context);
  // 2026-10-10 数量+单位口径：单位内联在数量输入框 suffixText（行单位由货品带出，
  // 字典缺项时退显原 id；未维护单位则无后缀），独立「单位」列删除。
  String? unitSuffixOf(SubcontractGridRow row) {
    final id = row.unitId;
    if (id == null || id.isEmpty) return null;
    final name = unitEntries[id]?.trim();
    return name == null || name.isEmpty ? id : name;
  }

  // 货品身份列的颜色名（2026-09-14 口径）：行模型只透传 colorId，这里按需解析。
  // 延迟到取值/渲染时才读字典容器——列定义本身不碰 Provider，裸 MaterialApp
  // 构列的列序契约测试不受影响。未维护颜色返回 null（身份格自然省略，不占位）。
  String? colorNameOf(SubcontractGridRow row) {
    final id = row.colorId;
    if (id == null || id.isEmpty) return null;
    final name = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(masterNameServiceProvider).color(id);
    return name == '—' ? null : name;
  }

  final columns = <EditableGridColumn<SubcontractGridRow>>[
    EditableGridColumn<SubcontractGridRow>(
      key: 'goods',
      label: '货品名称',
      width: 200,
      required: true,
      // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色**各占一列**，
      // 不把编号颜色拼进名称格——拼在一起既不能各自排序筛选，列窄时编号还先
      // 被省略号吃掉。这里只放名称，编号与颜色见紧随其后的两列。
      textOf: (r) => r.goods?.name ?? '',
      listenableOf: (r) => r.goodsNotifier,
      // 格尾搜索/锁图标(16)计入自动加宽量宽（2026-09-16）。
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.goodsNotifier,
        isEmpty: () => row.goods == null,
        child: InkWell(
          onTap: row.sourceLocked ? null : () => onPickGoods(row),
          child: InputDecorator(
            // 选择格统一内边距（2026-10-06 表格控件统一口径）：名称保持
            // 身份格字号（bodyMedium w600），垫高到与数量/单价等格同高。
            decoration: InputDecoration(
              isDense: true,
              contentPadding: UtenEditableGridCellSpec.contentPaddingOf(
                context,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: ValueListenableBuilder<GoodsOption?>(
                    valueListenable: row.goodsNotifier,
                    builder: (context, g, _) => g == null
                        ? Text(
                            utenFieldPlaceholder(label: '货品名称')!,
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
    EditableGridColumn<SubcontractGridRow>(
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
    EditableGridColumn<SubcontractGridRow>(
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
    if (showCommercial)
      EditableGridColumn<SubcontractGridRow>(
        key: 'source',
        label: '申请来源',
        width: 150,
        // textOf（导出/复制）保留全量；屏幕格走多值截断+弹窗口径（2026-10-29）。
        textOf: (row) => row.sourceDocs
            .map((source) => source.billNo)
            .whereType<String>()
            .where((no) => no.isNotEmpty)
            .toSet()
            .join('、'),
        cellBuilder: (context, row) => UtenMultiValueCell(
          values: [
            for (final source in row.sourceDocs)
              if (source.billNo?.isNotEmpty == true) source.billNo!,
          ],
          title: '申请来源',
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
        width: 170,
        required: supplierRequired,
        // 展开箭头(20) + 学习预填黄标 ⓘ(44) 都计入自动加宽量宽（2026-09-10）。
        chromeWidth:
            UtenEditableGridCellSpec.dropdownChevronWidth +
            UtenEditableGridCellSpec.hintIconWidth,
        textOf: (r) => supplierEntries[r.supplierId ?? headerSupplierId] ?? '',
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
      width: 128,
      numeric: true,
      required: true,
      headerInfo: l10n.workflowQuantityHint,
      frozenTextOf: (r) => r.qty.text,
      exactValueOf: (r) => r.qty.text,
      exactListenableOf: (r) => r.qty,
      listenableOf: (r) => r.qty,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.qty,
        isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
        child: TextField(
          controller: row.qty,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          // 单位内联在数量输入框后（2026-10-10 口径，替代原独立单位列）。
          decoration: UtenInputDecoration(
            InputDecoration(
              isDense: true,
              labelText: '数量',
              suffixText: unitSuffixOf(row),
            ),
          ),
        ),
      ),
    ),
    // 新批准的领料计划冻结正常损耗加成；旧计划保留原始单耗。
    // ADR-098 的短交容差仍保留，不用它减少订货目标数量。
    if (cfg.itemHasAllowedLossPct)
      EditableGridColumn<SubcontractGridRow>(
        key: 'allowedLossPct',
        label: '允许损耗%',
        width: 120,
        numeric: true,
        headerInfo:
            '新批准时按此比例增加直属物料领料量，成品目标数量不变。'
            '例如订 100 件、损耗 10%，基准用料 100 的物料领 110，仍应回厂 100 件。'
            '正常损耗已包含在回厂材料估算核销中，不要重复登记损耗单。'
            '已加损耗用料的新单若成品短交，须补齐或由负责人明确接受，不能自动减交。'
            '历史已批准计划不补增用料。留空 = 不增加。'
            '按货品主档记忆预填，保存后记住本次填写值。',
        textOf: (r) => r.allowedLossPct.text,
        exactValueOf: (r) => r.allowedLossPct.text,
        exactListenableOf: (r) => r.allowedLossPct,
        listenableOf: (r) => r.allowedLossPct,
        cellBuilder: (context, row) => ValueListenableBuilder<Set<String>>(
          valueListenable: row.termsAutofilledNotifier,
          builder: (context, marks, _) => TextField(
            key: ValueKey('subcontract-allowed-loss-${row.hashCode}'),
            controller: row.allowedLossPct,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: applyAutofillHint(
              const UtenInputDecoration(
                InputDecoration(isDense: true, labelText: '允许损耗%'),
              ),
              Theme.of(context),
              autofilled: marks.contains('allowedLoss'),
            ),
          ),
        ),
      ),
    if (cfg.itemHasPrice)
      EditableGridColumn<SubcontractGridRow>(
        key: 'price',
        label: '单价',
        width: 128,
        numeric: true,
        required: true,
        headerInfo: l10n.workflowPriceHint,
        frozenTextOf: (r) => r.price.text,
        textOf: (r) => r.price.text,
        exactValueOf: (r) => r.price.text,
        exactListenableOf: (r) => r.price,
        listenableOf: (r) => r.price,
        chromeWidthOf: PriceCheckCell.evidenceExtentOf,
        cellBuilder: (context, row) => PriceCheckCell(
          row: row,
          showUnavailableInfo: false,
          child: RequiredCellFrame(
            listenable: row.price,
            isEmpty: () =>
                row.price.text.trim().isEmpty ||
                double.tryParse(row.price.text.trim()) == null,
            child: TextField(
              controller: row.price,
              onChanged: (_) => row.clearTermsAutofilled('price'),
              onSubmitted: (_) => row.clearTermsAutofilled('price'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const UtenInputDecoration(
                InputDecoration(isDense: true, labelText: '单价'),
              ),
            ),
          ),
        ),
      ),
    if (cfg.itemHasPrice)
      EditableGridColumn<SubcontractGridRow>(
        key: 'amount',
        label: '总金额',
        width: 190,
        numeric: true,
        headerInfo: linePricingAmountHeaderHint,
        textOf: (r) => r.hasSourceAmount
            ? (r.amountExactNotifier.value ?? '')
            : r.pricing.totalAmount.text,
        listenableOf: (r) =>
            Listenable.merge([r.pricing, r.amountExactNotifier]),
        exactValueOf: (r) => r.amountExactNotifier.value,
        exactListenableOf: (r) => r.amountExactNotifier,
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
    if (cfg.itemHasGirth)
      EditableGridColumn<SubcontractGridRow>(
        key: 'girth',
        label: '围数',
        width: 96,
        numeric: true,
        frozenTextOf: (r) => r.girth.text,
        exactValueOf: (r) => r.girth.text,
        exactListenableOf: (r) => r.girth,
        listenableOf: (r) => r.girth,
        cellBuilder: (context, row) => TextField(
          controller: row.girth,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const UtenInputDecoration(
            InputDecoration(isDense: true, labelText: '围数'),
          ),
        ),
      ),
    if (cfg.itemHasBoxQty)
      EditableGridColumn<SubcontractGridRow>(
        key: 'boxQty',
        label: '胶箱数',
        width: 96,
        numeric: true,
        frozenTextOf: (r) => r.boxQty.text,
        exactValueOf: (r) => r.boxQty.text,
        exactListenableOf: (r) => r.boxQty,
        listenableOf: (r) => r.boxQty,
        cellBuilder: (context, row) => TextField(
          controller: row.boxQty,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const UtenInputDecoration(
            InputDecoration(isDense: true, labelText: '胶箱数'),
          ),
        ),
      ),
    if (cfg.itemHasWasteFields) ...[
      EditableGridColumn<SubcontractGridRow>(
        key: 'standardQty',
        label: '标准用量',
        width: 110,
        numeric: true,
        frozenTextOf: (r) => r.standardQty.text,
        exactValueOf: (r) => r.standardQty.text,
        exactListenableOf: (r) => r.standardQty,
        listenableOf: (r) => r.standardQty,
        cellBuilder: (context, row) => TextField(
          controller: row.standardQty,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          // 单位内联在数量输入框后（2026-10-10 口径）。
          decoration: UtenInputDecoration(
            InputDecoration(
              isDense: true,
              labelText: '标准用量',
              suffixText: unitSuffixOf(row),
            ),
          ),
        ),
      ),
      EditableGridColumn<SubcontractGridRow>(
        key: 'endingQty',
        label: '结存数',
        width: 100,
        numeric: true,
        frozenTextOf: (r) => r.endingQty.text,
        exactValueOf: (r) => r.endingQty.text,
        exactListenableOf: (r) => r.endingQty,
        listenableOf: (r) => r.endingQty,
        cellBuilder: (context, row) => TextField(
          controller: row.endingQty,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: UtenInputDecoration(
            InputDecoration(
              isDense: true,
              labelText: '结存数',
              suffixText: unitSuffixOf(row),
            ),
          ),
        ),
      ),
      EditableGridColumn<SubcontractGridRow>(
        key: 'wasteRate',
        label: '损耗率%',
        width: 100,
        numeric: true,
        frozenTextOf: (r) => r.wasteRate.text,
        exactValueOf: (r) => r.wasteRate.text,
        exactListenableOf: (r) => r.wasteRate,
        listenableOf: (r) => r.wasteRate,
        cellBuilder: (context, row) => TextField(
          controller: row.wasteRate,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const UtenInputDecoration(
            InputDecoration(isDense: true, labelText: '损耗率%'),
          ),
        ),
      ),
      EditableGridColumn<SubcontractGridRow>(
        key: 'cause',
        label: '损耗原因',
        width: 200,
        frozenTextOf: (r) => r.cause.text,
        listenableOf: (r) => r.cause,
        cellBuilder: (context, row) => TextField(
          controller: row.cause,
          // 单行（2026-09-09 统一口径）：双行把整行撑高，与数量/单价格不同高。
          decoration: const UtenInputDecoration(
            InputDecoration(isDense: true, labelText: '损耗原因'),
          ),
        ),
      ),
    ],
    // 订货单行级商业条款（2026-09）：单头不再录，逐行选择/填写，保存按组合拆单。
    if (showCommercial)
      ...procurementCommercialColumns<SubcontractGridRow>(
        context: context,
        currencyEntries: currencyEntries,
        settlementEntries: settlementEntries,
        settlementLabel: '结算方式',
        onPickCurrency: onPickCurrency ?? (row) => (value) {},
        onPickSettlement: onPickSettlement ?? (row) => (value) {},
      ),
    // 每行末尾备注列：随行提交 remark。
    if (showRemark) procurementRemarkColumn<SubcontractGridRow>(),
    ...businessEditableColumns<SubcontractGridRow>(
      businessColumnsOf(rows),
      rowOf: (row) => row,
      amountHint: l10n.businessColumnAmountHint,
    ),
  ];
  return showCommercial
      ? canonicalProcurementColumns(columns, keyOf: (column) => column.key)
      : columns;
}

PriceCheckBinding subcontractPriceCheckBinding(
  SubcontractGridRow row, {
  String? supplierId,
  String? currencyId,
  String? taxRate,
}) => PriceCheckBinding(
  contextKey: (
    row.colorId,
    row.unitId,
    row.unitRateText ?? row.unitRate?.toString(),
  ),
  listenables: [
    row.goodsNotifier,
    row.pricing,
    row.supplierIdNotifier,
    row.currencyIdNotifier,
    row.taxRate,
    row.extraColumnsChanged,
  ],
  payload: () =>
      row.goods == null ||
          !priceCheckOperandsReady(row.qty.text, row.price.text)
      ? null
      : {
          'goodsId': row.goods!.id,
          'supplierId': row.supplierId ?? supplierId,
          'colorId': row.colorId,
          'unitId': row.unitId,
          'unitRate': row.unitRateText ?? row.unitRate?.toString(),
          'currencyId': row.currencyId ?? currencyId,
          'taxRate': row.taxRate.text.trim().isNotEmpty
              ? row.taxRate.text.trim()
              : taxRate,
          'quantity': row.qty.text.trim(),
          'unitPrice': row.price.text.trim(),
          'totalAmountInput': row.pricing.totalAmountInput,
          'giftQuantity': '0',
          'extraColumns': row.exportExtraColumns(),
        },
);
