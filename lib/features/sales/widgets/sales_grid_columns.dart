// 销售单据明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// SalesGridRow：货品(选择)/数量/单位/单价→金额自动（AmountRowMixin）；
// 颜色/单位换算率 + 上游明细 id
// 为透传（从上游引入或详情回填时预填，保存时随行写回）；报表补列（机加价/围数/进仓/
// 材料价/压铸价/折扣）按 docType 显隐对应列。
// 2026-09-04 口径：实际重量列下线（单位已表达重量；行模型 weight 保留透传），
// 单位列紧跟数量。折扣列表头 ⓘ 悬停说明「1 = 原价；0.9 = 9折」。
// salesGridColumns：货品/颜色/数量/单位/单价/金额 + 补列（条件）。
// 2026-09-27(ADR-134)：报价/订货加「文件型号 / 文件品名 / 文件单价」三列(客户文件原文,
// 识别客户文件导入或手填; 文件单价只读、仅有值时出现); 报价单价可议价，订货锁定、
// 折扣可编辑(可留空交财务核价); 识别结果里需要核对的行货品格黄框提醒。
import 'package:flutter/material.dart';
import '../../../shared/business_columns/business_columns_row.dart';
import '../intake/sales_intake_l10n.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../shared/drafts/form_draft_values.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../shared/ai/page_context/ai_page_context.dart';

import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/pricing/line_pricing_amount_cell.dart';
import '../../../shared/pricing/line_pricing_controller.dart';
import '../intake/sales_intake_apply.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import 'sales_doc_link_picker.dart';

final _salesOrderDiscountPattern = RegExp(r'^(?:0\.\d{1,4}|1(?:\.0{1,4})?)$');

/// 销售订单折扣的新写口径：倍率大于 0 且不大于 1，最多四位小数。
/// 科学计数法、NaN/Infinity 和超过数据库 NUMERIC(18,4) 精度的输入均拒绝，
/// 避免客户端预览与服务端落库舍入不一致。
bool isValidSalesOrderDiscountText(String raw) {
  final text = raw.trim();
  final value = double.tryParse(text);
  if (value == null || !value.isFinite || value <= 0 || value > 1) {
    return false;
  }
  return _salesOrderDiscountPattern.hasMatch(text);
}

/// 销售明细行。货品用 [ValueNotifier]（点选后单元格自动刷新，无需 setState）；
/// 数量/单价控制器变更 → 自动重算金额（amountNotifier）。
///
/// [documentItemId] 是当前单据自身明细 UUID；orderItemId/outItemId 只表示上游来源。
/// 颜色/单位 + 上游明细 id 为透传字段（详情回填或上游引入时预填，保存时随行写回，
/// UI 单元格只读/下拉同步到 row 字段）。报表补列（ machiningPrice 等）
/// 按 docType 在列定义中显隐对应列。
class SalesGridRow extends EditableGridRow
    with AmountRowMixin, BusinessColumnsRow {
  /// 适用折扣的商业单据按数量 × 单价 × 折扣计算；履约出货沿用来源金额。
  final bool amountUsesDiscount;
  final bool allowPricingInput;

  SalesGridRow({
    this.amountUsesDiscount = false,
    this.allowPricingInput = false,
  }) {
    pricing = LinePricingController(
      qty: qty,
      price: price,
      discount: amountUsesDiscount ? discount : null,
      extraColumns: () => extraColumnSnapshots,
      extraColumnsChanged: extraColumnsChanged,
      canCalculatePrice: () => canEditTotal,
      canCalculateQuantity: () => canEditTotal,
    )..addListener(_recalc);
    // 校验红标（保存时标记，用户改动任一必填内容即自动消除）。
    goodsNotifier.addListener(_clearInvalid);
    qty.addListener(_clearInvalid);
    price.addListener(_clearInvalid);
    pricing.totalAmount.addListener(_clearInvalid);
    discount.addListener(_clearInvalid);
    // 查重标红（保存前查重被拦回时标记）同样「改动即消除」，下次保存重新判定。
    goodsNotifier.addListener(_clearFlagged);
    qty.addListener(_clearFlagged);
    price.addListener(_clearFlagged);
    pricing.totalAmount.addListener(_clearFlagged);
    discount.addListener(_clearFlagged);
    remark.addListener(_clearFlagged);
    // 识别结果黄标：用户改了货品/数量/折扣即视为已核对(只看内容变化，点进输入框不算)。
    goodsNotifier.addListener(_clearAiReviewIfChanged);
    qty.addListener(_clearAiReviewIfChanged);
    discount.addListener(_clearAiReviewIfChanged);
    // AI 助手填入的格子(ADR-150)：用户再改这一格即视为已核对，黄框消失。
    for (final controller in _aiFillableControllers.values) {
      controller.addListener(_clearAiFilledIfEdited);
    }
    // 新销售订单默认原价倍率；货品主档折扣或用户输入随后可覆盖。
    if (amountUsesDiscount) discount.text = '1';
  }

  final ValueNotifier<GoodsOption?> goodsNotifier = ValueNotifier<GoodsOption?>(
    null,
  );
  GoodsOption? get goods => goodsNotifier.value;
  set goods(GoodsOption? v) => goodsNotifier.value = v;

  final TextEditingController qty = TextEditingController();
  final TextEditingController weight = TextEditingController();
  final TextEditingController price = TextEditingController();
  late final LinePricingController pricing;

  /// 来源单据的价格与金额由履约/退货链路决定，不能用总金额覆盖。
  bool get canEditTotal =>
      allowPricingInput &&
      (orderItemId?.isEmpty ?? true) &&
      (outItemId?.isEmpty ?? true);

  /// 复制既有销售订货行时，冻结价不能直接成为“新行”的价格预览。
  /// true 表示必须重新选择货品，从当前主档取得价格后才允许保存。
  bool requiresOrderPriceRefresh = false;

  /// 货品选择后的只读价格预览。即使当前货品未维护售价也必须清空旧值，
  /// 避免换货后仍显示上一货品的价格。
  void applyLockedPricePreview(Object? value) {
    requiresOrderPriceRefresh = false;
    // 展示口径统一去尾随零：主档价 10.0 显示 "10" 而非 "10.0"。
    price.text = financeExactTrimmed(value?.toString()) ?? '';
  }

  /// 当前单据自身明细 UUID。仅受控更新既有销售订货行时回传为 JSON `id`。
  ///
  /// 不可与 [orderItemId] 混用：后者是出货/退货等下游单据对来源订货行的引用。
  String? documentItemId;

  /// 上游明细 id（引入时回填，保存时按 cfg.linkTo* 直接映射为
  /// orderItemId/outItemId —— 销售双挂所以两 id 各自独立透传，不像采购三选一）。
  String? orderItemId;
  String? outItemId;

  /// 颜色/单位（选货品后自动回填或上游引入预填；单元格只读显示）。
  /// 用 ValueNotifier：选货品后单元格即时刷新（与 goodsNotifier 同款），无需整页 setState。
  final colorIdNotifier = ValueNotifier<String?>(null);
  String? get colorId => colorIdNotifier.value;
  set colorId(String? v) => colorIdNotifier.value = v;
  final unitIdNotifier = ValueNotifier<String?>(null);
  String? get unitId => unitIdNotifier.value;
  set unitId(String? v) => unitIdNotifier.value = v;
  double? unitRate;
  String? unitRateExact;

  /// 库位号（只读，货品主档带出；出货/其它出货/退货实物单据的拣货/上架指引，
  /// 异步补全后自动刷新）。
  final stockPlaceNotifier = ValueNotifier<String?>(null);

  /// 退货专属：处理方案 / 责任单位（仅 returnDoc 显列）。
  final solutionNotifier = ValueNotifier<String?>(null);
  String? get solution => solutionNotifier.value;
  set solution(String? v) => solutionNotifier.value = v;
  final responsibleNotifier = ValueNotifier<String?>(null);
  String? get responsible => responsibleNotifier.value;
  set responsible(String? v) => responsibleNotifier.value = v;

  // 报表补列：成本分项/包装派生/折扣。空文本不随 body 提交（后端按 nullable 处理）。
  // order：机加价/围数；进仓数量仅保留旧数据参考，不入录或提交。
  // other_shipment：材料价/压铸价/机加价/围数/折扣；shipment 已精简，不展示这些补列。
  // return：折扣。
  final machiningPrice = TextEditingController();
  final circumference = TextEditingController();
  final inboundQty = TextEditingController();
  final materialPrice = TextEditingController();
  final dieCastPrice = TextEditingController();
  final discount = TextEditingController();

  /// 行备注（5 类单据通用，网格末列；空文本不随 body 提交）。
  final remark = TextEditingController();

  // ---- 客户文件原文(报价/订货，ADR-134)----

  /// 文件型号(客户的型号/货号，可编辑；保存后系统学习客户叫法)。
  final clientModel = TextEditingController();

  /// 文件品名(客户文件原文或用户明确输入，不从主档英文名称填充)。
  final clientGoodsName = TextEditingController();

  /// 文件单价(文件币种，只读参考；折扣按它反推，单价始终以标价为准)。
  String? clientPrice;

  /// 旧草稿的英文预填标记，只用于防止把旧主档名称学习为客户别名。
  String? prefilledNameEn;

  /// 客户编号(历史字段，不展示，仅随保存原样回传避免被清空)。
  String? clientNo;

  /// 报价行定价来源：FINANCE = 财务定价(单价格显示「财务定价」)。
  String? priceSource;

  /// 报价转入的订货行：折扣已由财务在报价中核定，只读。
  bool quoteDiscountLocked = false;

  /// 识别作业里的行键(保存时回传 intakeLineKey，服务端据此学习)。
  String? intakeLineKey;

  /// 用户明确选过/改过这一行的货品(学习时算「人工确认」)。
  bool userConfirmed = false;

  /// 保存后把文件品名写成该货品的英文名称(核对面板里勾的)。
  bool setNameEn = false;

  /// 识别结果需要核对的原因(非 null = 货品格黄框提醒)。
  final aiReviewNotifier = ValueNotifier<String?>(null);
  String? get aiReview => aiReviewNotifier.value;
  String? _aiReviewGoodsId;
  String? _aiReviewQty;
  String? _aiReviewDiscount;

  /// 黄标原因里属于「货品没对准」的那一段(在原因开头; 核对面板的「确认」只清它)。
  String? _aiReviewGoodsMatch;

  /// 当前黄标里的货品对应提醒; 只有单位/金额/重复/定价提醒时为 null。
  String? get aiReviewGoodsMatch =>
      aiReview == null ? null : _aiReviewGoodsMatch;

  /// 标记(或清除)识别黄标：记下当前内容，之后内容一变就自动清除。
  /// [goodsMatch] 是 [reason] 开头那段货品对应提醒(没有就不传)。
  void markAiReview(String? reason, {String? goodsMatch}) {
    aiReviewNotifier.value = reason;
    _aiReviewGoodsMatch =
        reason != null && goodsMatch != null && reason.startsWith(goodsMatch)
        ? goodsMatch
        : null;
    _aiReviewGoodsId = goods?.id;
    _aiReviewQty = qty.text;
    _aiReviewDiscount = discount.text;
  }

  /// 用户确认「这一行的货品对得上」(ADR-150 确认卡, 与核对面板的「确认」同口径):
  /// 只去掉货品对应提醒并记为人工确认(保存时据此学习客户料号); 单位换算、金额对不上、
  /// 重复货品和定价提醒照样保留, 要核对数量/货品后直接改。没有货品对应提醒时返回 false。
  bool confirmGoodsMatch() {
    final reason = aiReview;
    final match = aiReviewGoodsMatch;
    if (reason == null || match == null) return false;
    var rest = reason.substring(match.length).trim();
    if (rest.startsWith('/')) rest = rest.substring(1).trim();
    userConfirmed = true;
    markAiReview(rest.isEmpty ? null : rest);
    return true;
  }

  void _clearAiReviewIfChanged() {
    if (aiReviewNotifier.value == null) return;
    if (goods?.id != _aiReviewGoodsId ||
        qty.text != _aiReviewQty ||
        discount.text != _aiReviewDiscount) {
      aiReviewNotifier.value = null;
      _aiReviewGoodsMatch = null;
    }
  }

  /// AI 助手(确认卡确认后)填入、等用户核对的格子：列键 -> 填入时的文本(ADR-150)。
  /// 对应格子显示黄框「AI 填入，请核对」；用户改动该格后自动去掉。
  final aiFilledNotifier = ValueNotifier<Map<String, String>>(const {});

  /// AI 可以按行改写的文本格(列键 -> 控制器)。
  Map<String, TextEditingController> get _aiFillableControllers => {
    'qty': qty,
    'price': price,
    'discount': discount,
    'remark': remark,
    'clientModel': clientModel,
    'clientGoodsName': clientGoodsName,
  };

  /// 由 AI 写入 [key] 格并标黄。识别黄标(aiReview)保留：AI 改值不算人工核对。
  void applyAiValue(String key, String value) {
    final controller = _aiFillableControllers[key];
    if (controller == null) return;
    final review = aiReview;
    final goodsMatch = aiReviewGoodsMatch;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    if (review != null) markAiReview(review, goodsMatch: goodsMatch);
    aiFilledNotifier.value = {...aiFilledNotifier.value, key: value};
  }

  void _clearAiFilledIfEdited() {
    final filled = aiFilledNotifier.value;
    if (filled.isEmpty) return;
    final controllers = _aiFillableControllers;
    final kept = {
      for (final entry in filled.entries)
        if (controllers[entry.key]?.text == entry.value) entry.key: entry.value,
    };
    if (kept.length != filled.length) aiFilledNotifier.value = kept;
  }

  /// 行级校验红标：保存拦截时置 true（货品/数量/单价缺失的格变红），
  /// 用户改货品/数量/单价即自动清除。
  final invalidNotifier = ValueNotifier<bool>(false);

  void _clearInvalid() {
    if (invalidNotifier.value) invalidNotifier.value = false;
  }

  /// 清除整行查重标红（[EditableGridRow.flagged]）：货品/数量/单价/折扣/备注任一
  /// 被改动即视为用户已处理该行。
  void _clearFlagged() {
    if (flaggedNotifier.value) flaggedNotifier.value = false;
  }

  /// 从上游引入项构造（货品/数量/单价/upstream/颜色/单位 预填）。
  factory SalesGridRow.fromLinked(
    SalesLinkedItem li,
    GoodsOption goods, {
    bool amountUsesDiscount = false,
    bool allowPricingInput = false,
  }) {
    final r =
        SalesGridRow(
            amountUsesDiscount: amountUsesDiscount,
            allowPricingInput: allowPricingInput,
          )
          ..goods = goods
          ..orderItemId = li.orderItemId
          ..outItemId = li.outItemId
          ..colorId = li.colorId
          ..unitId = li.unitId
          ..unitRate = li.unitRate;
    r.qty.text = li.qty.toString();
    if (li.price != null) r.price.text = li.price.toString();
    return r;
  }

  /// 识别客户文件导入的一行：货品/颜色/单位、数量、标价预览(只读)、折扣、
  /// 文件原文与学习标记；需要核对的行带黄标。单价永远来自标价，不用文件单价。
  factory SalesGridRow.fromIntake(
    SalesIntakePatchRow p, {
    bool amountUsesDiscount = true,
    bool allowPricingInput = false,
  }) {
    final r =
        SalesGridRow(
            amountUsesDiscount: amountUsesDiscount,
            allowPricingInput: allowPricingInput,
          )
          ..goods = GoodsOption(
            id: p.goodsId,
            code: p.goodsCode,
            name: p.goodsName,
            nameEn: p.goodsNameEn,
          )
          ..colorId = p.colorId
          ..unitId = p.unitId
          ..unitRate = 1
          ..clientPrice = p.clientPrice
          ..intakeLineKey = p.intakeLineKey
          ..userConfirmed = p.userConfirmed
          ..setNameEn = p.setNameEn;
    r.qty.text = p.qty;
    r.applyLockedPricePreview(p.listPrice);
    r.discount.text = p.discount ?? '';
    r.clientModel.text = p.clientModel ?? '';
    r.clientGoodsName.text = p.clientGoodsName ?? '';
    r.remark.text = p.remark ?? '';
    r.markAiReview(p.reviewReason, goodsMatch: p.goodsMatchReason);
    return r;
  }

  /// 行金额预览(十进制精确乘积, ADR-112, 订单含折扣倍率); 数量或单价未填时为空。
  /// 只用于显示, 保存不上送金额, 金额由服务端派生。
  final ValueNotifier<String?> amountExactNotifier = ValueNotifier<String?>(
    null,
  );

  void _recalc() {
    // Source-derived display facts retain their original decimal precision.
    // Editable pricing still enforces the quantity/price input contract.
    amountExactNotifier.value = allowPricingInput
        ? pricing.amountExact
        : applyExtraColumnAmount(
            exactLineAmountText(
              qty.text,
              price.text,
              discount: amountUsesDiscount ? discount.text : null,
            ),
          );
    recalcAmount(() => double.tryParse(amountExactNotifier.value ?? '') ?? 0);
  }

  Map<String, TextEditingController> get _draftTextControllers => {
    'qty': qty,
    'weight': weight,
    'price': price,
    'machiningPrice': machiningPrice,
    'circumference': circumference,
    'inboundQty': inboundQty,
    'materialPrice': materialPrice,
    'dieCastPrice': dieCastPrice,
    'discount': discount,
    'remark': remark,
    'clientModel': clientModel,
    'clientGoodsName': clientGoodsName,
  };

  Iterable<Listenable> get draftListenables => [
    ..._draftTextControllers.values,
    ...extraColumnListenables,
    pricing,
    aiReviewNotifier,
    goodsNotifier,
    colorIdNotifier,
    unitIdNotifier,
    stockPlaceNotifier,
    solutionNotifier,
    responsibleNotifier,
  ];

  Map<String, dynamic> exportDraft() => {
    'text': draftTextValues(_draftTextControllers),
    'extraColumns': exportExtraColumns(),
    'pricing': pricing.exportState(),
    'goods': draftGoods(goods),
    'stockPlace': stockPlaceNotifier.value,
    'unitRate': unitRate,
    'documentItemId': documentItemId,
    'orderItemId': orderItemId,
    'outItemId': outItemId,
    'colorId': colorId,
    'unitId': unitId,
    'unitRateExact': unitRateExact,
    'solution': solution,
    'responsible': responsible,
    'amountUsesDiscount': amountUsesDiscount,
    'requiresOrderPriceRefresh': requiresOrderPriceRefresh,
    'clientPrice': clientPrice,
    'clientNo': clientNo,
    'priceSource': priceSource,
    'quoteDiscountLocked': quoteDiscountLocked,
    'intakeLineKey': intakeLineKey,
    'userConfirmed': userConfirmed,
    'setNameEn': setNameEn,
    'aiReview': aiReview,
    'aiReviewGoodsMatch': aiReviewGoodsMatch,
    'prefilledNameEn': prefilledNameEn,
  };

  factory SalesGridRow.fromDraft(
    Map<String, dynamic> data, {
    bool allowPricingInput = false,
    bool? amountUsesDiscount,
  }) {
    final row =
        SalesGridRow(
            amountUsesDiscount:
                amountUsesDiscount ?? data['amountUsesDiscount'] == true,
            allowPricingInput: allowPricingInput,
          )
          ..goods = restoreDraftGoods(data['goods'])
          ..stockPlaceNotifier.value = data['stockPlace'] as String?
          ..unitRate = (data['unitRate'] as num?)?.toDouble()
          ..documentItemId = data['documentItemId'] as String?
          ..orderItemId = data['orderItemId'] as String?
          ..outItemId = data['outItemId'] as String?
          ..colorId = data['colorId'] as String?
          ..unitId = data['unitId'] as String?
          ..unitRateExact = data['unitRateExact'] as String?
          ..solution = data['solution'] as String?
          ..responsible = data['responsible'] as String?
          ..clientPrice = data['clientPrice'] as String?
          ..clientNo = data['clientNo'] as String?
          ..priceSource = data['priceSource'] as String?
          ..quoteDiscountLocked = data['quoteDiscountLocked'] == true
          ..intakeLineKey = data['intakeLineKey'] as String?
          ..userConfirmed = data['userConfirmed'] == true
          ..setNameEn = data['setNameEn'] == true
          ..prefilledNameEn = data['prefilledNameEn'] as String?;
    restoreDraftTextValues(row._draftTextControllers, draftMap(data['text']));
    row.restoreExtraColumns(data['extraColumns']);
    if (row.canEditTotal) row.pricing.restoreState(data['pricing']);
    row.requiresOrderPriceRefresh = data['requiresOrderPriceRefresh'] == true;
    row.markAiReview(
      data['aiReview'] as String?,
      goodsMatch: data['aiReviewGoodsMatch'] as String?,
    );
    return row;
  }

  /// 深拷贝（明细复制/粘贴用）：新建行 + 拷贝各控制器文本 + 透传字段 + 自动重算金额。
  SalesGridRow clone({bool requireOrderPriceRefresh = false}) {
    // 复制产生的是新明细，绝不能复制当前单据行 UUID；否则受控修订会覆盖原行。
    final c =
        SalesGridRow(
            amountUsesDiscount: amountUsesDiscount,
            allowPricingInput: allowPricingInput,
          )
          ..goods = goods
          ..orderItemId = orderItemId
          ..outItemId = outItemId
          ..colorId = colorId
          ..unitId = unitId
          ..unitRate = unitRate
          ..unitRateExact = unitRateExact;
    copyExtraColumnsTo(c);
    c.qty.text = qty.text;
    c.weight.text = weight.text;
    c.requiresOrderPriceRefresh =
        requireOrderPriceRefresh && amountUsesDiscount && goods != null;
    if (!c.requiresOrderPriceRefresh) c.price.text = price.text;
    c.machiningPrice.text = machiningPrice.text;
    c.circumference.text = circumference.text;
    c.inboundQty.text = inboundQty.text;
    c.materialPrice.text = materialPrice.text;
    c.dieCastPrice.text = dieCastPrice.text;
    c.discount.text = discount.text;
    c.remark.text = remark.text;
    // 文件原文随行复制；识别行键/人工确认/英文名勾选/财务定价/报价核定属于原行，不复制。
    c.clientModel.text = clientModel.text;
    c.clientGoodsName.text = clientGoodsName.text;
    c.clientPrice = clientPrice;
    if (c.canEditTotal) pricing.copyStateTo(c.pricing);
    return c;
  }

  @override
  void dispose() {
    pricing.dispose();
    goodsNotifier.dispose();
    amountExactNotifier.dispose();
    colorIdNotifier.dispose();
    unitIdNotifier.dispose();
    stockPlaceNotifier.dispose();
    solutionNotifier.dispose();
    responsibleNotifier.dispose();
    qty.dispose();
    weight.dispose();
    price.dispose();
    machiningPrice.dispose();
    circumference.dispose();
    inboundQty.dispose();
    materialPrice.dispose();
    dieCastPrice.dispose();
    discount.dispose();
    remark.dispose();
    clientModel.dispose();
    clientGoodsName.dispose();
    aiReviewNotifier.dispose();
    aiFilledNotifier.dispose();
    invalidNotifier.dispose();
    super.dispose();
  }
}

/// 已填写的可选业务列必须随草稿重开显现；仍使用原有列布局和真实行字段。
Set<String> filledSalesOptionalColumnKeys(Iterable<SalesGridRow> rows) => {
  ...filledBusinessColumnKeys(rows),
  for (final row in rows) ...{
    if (row.clientModel.text.trim().isNotEmpty) 'clientModel',
    if (row.clientGoodsName.text.trim().isNotEmpty) 'clientGoodsName',
    if (row.clientPrice != null) 'clientPrice',
    if (row.machiningPrice.text.trim().isNotEmpty) 'machiningPrice',
    if (row.circumference.text.trim().isNotEmpty) 'circumference',
    if (row.inboundQty.text.trim().isNotEmpty) 'inboundQty',
    if (row.materialPrice.text.trim().isNotEmpty) 'materialPrice',
    if (row.dieCastPrice.text.trim().isNotEmpty) 'dieCastPrice',
  },
};

/// 销售明细列：货品（点选）/ 颜色 / 单位 / 数量 / 单价 / 金额（自动）+ 报表补列（按
/// [docType] 条件追加）。[onPickGoods] 由编辑页提供（弹货品选择器并写回 row.goods）。
/// [colorEntries]/[unitEntries] 由编辑页从 SalesMasterNameService 注入（单元格下拉用）。
///
/// 报价/订货(ADR-134)：[showClientPrice] 有文件单价时显示「文件单价」列(表头带
/// [clientFileCurrency])；[priceMasked] 看不到价格的账号单价格显示 ***、折扣格只读
/// (保存时由服务端按文件单价计算)。
List<EditableGridColumn<SalesGridRow>> salesGridColumns({
  required BuildContext context,
  List<SalesGridRow> rows = const [],
  required Future<void> Function(SalesGridRow row) onPickGoods,
  required SalesDocType docType,
  required Map<String, String> colorEntries,
  required Map<String, String> unitEntries,
  bool freeCustomerShipment = false,
  bool showClientPrice = false,
  String? clientFileCurrency,
  bool priceMasked = false,
}) {
  final isQuote = docType == SalesDocType.quote;
  final allowsTotalInput =
      !priceMasked &&
      (docType == SalesDocType.customerShipment ||
          docType == SalesDocType.returnDoc);
  final hasClientText = isQuote || docType == SalesDocType.order;
  final priceRequired =
      docType != SalesDocType.otherShipment &&
      !isQuote &&
      !freeCustomerShipment &&
      !priceMasked;
  final intakeText = salesIntakeL10n(context);
  // 列说明统一挂表头 ⓘ（2026-09-09 口径）：每行重复的 ⓘ 既冗余又挤占格宽。
  final l10n = workflowFieldText(context);
  final qtyHint = switch (docType) {
    SalesDocType.order => l10n.workflowOrderQuantityHint,
    SalesDocType.returnDoc => l10n.workflowReturnQuantityHint,
    _ => l10n.workflowQuantityHint,
  };
  final priceHint = isQuote
      ? intakeText.salesIntakeQuotePriceHint
      : (docType == SalesDocType.order || docType == SalesDocType.shipment)
      ? _lockedPriceHint
      : docType == SalesDocType.returnDoc
      ? l10n.workflowReturnPriceHint
      : l10n.workflowPriceHint;
  return [
    EditableGridColumn<SalesGridRow>(
      key: 'goods',
      label: '货品名称',
      // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色**各占一列**，
      // 不把编号拼进名称格——拼在一起既不能各自排序筛选，列窄时编号还先被
      // 省略号吃掉。这里只放名称，编号见右边「编号」列、颜色见「颜色」列。
      width: 200,
      required: true,
      textOf: (r) => r.goods?.name ?? '',
      listenableOf: (r) => r.goodsNotifier,
      // ADR-150：识别结果的待核对原因(含标价/单位等 warnings)进入 AI 页面快照。
      reviewReasonOf: (r) => r.aiReview == null
          ? null
          : priceMasked
          ? intakeText.salesIntakeStatusReview
          : r.aiReview,
      // 格尾搜索图标(16)计入自动加宽量宽，不再吃文本宽；识别黄标另占一个状态图标位。
      chromeWidth: hasClientText
          ? UtenEditableGridCellSpec.dropdownChevronWidth +
                UtenEditableGridCellSpec.hintIconWidth
          : UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.goodsNotifier,
        isEmpty: () => row.goods == null,
        child: InkWell(
          onTap: () => onPickGoods(row),
          child: ValueListenableBuilder<String?>(
            valueListenable: row.aiReviewNotifier,
            builder: (context, review, child) => InputDecorator(
              key: review == null
                  ? null
                  : ValueKey('sales-goods-ai-review-${row.goods?.id}'),
              decoration: review == null
                  // 选择格统一内边距（2026-10-06 表格控件统一口径）：
                  // 与同行输入格等高。
                  ? const InputDecoration(
                      isDense: true,
                      contentPadding:
                          UtenEditableGridCellSpec.pickerCellPadding,
                    )
                  // 原因走 UtenFieldMessage.autofill(格内黄标披露, 与带记忆的框同款)。
                  : applyAutofillHint(
                      UtenInputDecoration(
                        InputDecoration(
                          isDense: true,
                          contentPadding:
                              UtenEditableGridCellSpec.pickerCellPadding,
                          helper: UtenFieldMessage.autofill(
                            priceMasked
                                ? intakeText.salesIntakeStatusReview
                                : review,
                          ),
                        ),
                      ),
                      Theme.of(context),
                      autofilled: true,
                    ),
              child: child,
            ),
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
                const Icon(Icons.search_rounded, size: 16),
              ],
            ),
          ),
        ),
      ),
    ),
    EditableGridColumn<SalesGridRow>(
      key: 'nameEn',
      label: intakeText.businessColumnNameEn,
      width: 180,
      textOf: (r) => r.goods?.nameEn ?? '',
      listenableOf: (r) => r.goodsNotifier,
      cellBuilder: (context, row) => ValueListenableBuilder<GoodsOption?>(
        valueListenable: row.goodsNotifier,
        builder: (context, goods, _) => UtenGoodsAttributeCell(goods?.nameEn),
      ),
    ),
    EditableGridColumn<SalesGridRow>(
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
    EditableGridColumn<SalesGridRow>(
      key: 'color',
      label: '颜色',
      width: 130,
      textOf: (r) => colorEntries[r.colorId ?? ''] ?? '',
      listenableOf: (r) => r.colorIdNotifier,
      cellBuilder: (context, row) =>
          _readOnlyMasterCell(context, row.colorIdNotifier, colorEntries),
    ),
    // 报价/订货：客户文件原文(识别导入或手填，可改；保存后系统学习客户叫法)。
    if (hasClientText) ...[
      EditableGridColumn<SalesGridRow>(
        key: 'clientModel',
        defaultVisible: false,
        label: intakeText.salesIntakeColClientModel,
        width: 130,
        headerInfo: intakeText.salesIntakeColClientModelInfo,
        textOf: (r) => r.clientModel.text,
        listenableOf: (r) => r.clientModel,
        cellBuilder: (context, row) => _aiFilledField(
          row,
          'clientModel',
          (decorate) => TextField(
            controller: row.clientModel,
            decoration: decorate(const InputDecoration(isDense: true)),
          ),
        ),
      ),
      EditableGridColumn<SalesGridRow>(
        key: 'clientGoodsName',
        defaultVisible: false,
        label: intakeText.salesIntakeColClientGoodsName,
        width: 180,
        headerInfo: intakeText.salesIntakeColClientGoodsNameInfo,
        textOf: (r) => r.clientGoodsName.text,
        listenableOf: (r) => r.clientGoodsName,
        cellBuilder: (context, row) => _aiFilledField(
          row,
          'clientGoodsName',
          (decorate) => TextField(
            controller: row.clientGoodsName,
            decoration: decorate(const InputDecoration(isDense: true)),
          ),
        ),
      ),
    ],
    // 实物出入库单据（出货/其它出货/退货=hasWarehouse）：库位号（主档带出，拣货/上架指引）。
    if (const [
      SalesDocType.otherShipment,
      SalesDocType.returnDoc,
    ].contains(docType))
      EditableGridColumn<SalesGridRow>(
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
    EditableGridColumn<SalesGridRow>(
      key: 'qty',
      label: '数量',
      width: 128,
      numeric: true,
      required: true,
      headerInfo: qtyHint,
      frozenTextOf: (r) => r.qty.text,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.qty,
        isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
        child: _aiFilledField(
          row,
          'qty',
          (decorate) => TextField(
            controller: row.qty,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: decorate(
              const UtenInputDecoration(
                InputDecoration(isDense: true, hintText: '0'),
              ),
            ),
          ),
        ),
      ),
    ),
    // 单位紧跟数量（2026-09-04 口径）：单位已表达重量，实际重量列下线（行模型
    // weight 字段保留，编辑既有单回填并随保存透传，不丢历史数据）。
    EditableGridColumn<SalesGridRow>(
      key: 'unit',
      label: '单位',
      width: 110,
      textOf: (r) => unitEntries[r.unitId ?? ''] ?? '',
      listenableOf: (r) => r.unitIdNotifier,
      cellBuilder: (context, row) =>
          _readOnlyMasterCell(context, row.unitIdNotifier, unitEntries),
    ),
    if (!freeCustomerShipment)
      EditableGridColumn<SalesGridRow>(
        key: 'price',
        label: '单价',
        width: 128,
        numeric: true,
        required: priceRequired,
        // 锁定/可编辑两种分支共用表头说明（锁定口径 + 录入口径按 docType 择一）。
        headerInfo: priceHint,
        frozenTextOf: (r) => priceMasked ? '***' : r.price.text,
        cellBuilder: (context, row) => priceMasked
            ? const Text('***', textAlign: TextAlign.right)
            : RequiredCellFrame(
                listenable: row.price,
                isEmpty: () =>
                    priceRequired &&
                    (row.price.text.trim().isEmpty ||
                        double.tryParse(row.price.text.trim()) == null),
                // 订货/出货锁价；报价可协商单据价格，保存不改变货品主档。
                // 复制订单行会清空冻结价；重新选择货品即可取得当前主档价。
                child:
                    (docType == SalesDocType.order ||
                        docType == SalesDocType.shipment)
                    ? _lockedCell(
                        context,
                        row.price,
                        // 复制出来的报价行单价已清空、须重新选货取价: 不显示「待财务定价」误导。
                        hint:
                            isQuote &&
                                row.goods != null &&
                                !row.requiresOrderPriceRefresh
                            ? intakeText.salesIntakePendingFinancePrice
                            : null,
                        tag: row.priceSource == 'FINANCE'
                            ? intakeText.salesIntakeFinancePriced
                            : null,
                        info: isQuote
                            ? intakeText.salesIntakeQuotePriceHint
                            : null,
                      )
                    : _aiFilledField(
                        row,
                        'price',
                        (decorate) => TextField(
                          key: ValueKey(
                            'sales-price-${row.documentItemId ?? row.goods?.id ?? 'new'}',
                          ),
                          controller: row.price,
                          textAlign: TextAlign.right,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: decorate(
                            const UtenInputDecoration(
                              InputDecoration(isDense: true, hintText: '0'),
                            ),
                          ),
                        ),
                      ),
              ),
      ),
    // 订单/报价折扣：紧跟单价；货品主档 zk 或按文件单价反推的值作为初始建议，销售可调整
    //(报价可留空交财务核价)。看不到价格的账号只读(保存时服务端按文件单价计算)；
    // 报价转入的订货行只读(财务已在报价中核定)。
    if (!freeCustomerShipment &&
        (docType == SalesDocType.order ||
            docType == SalesDocType.customerShipment ||
            isQuote))
      EditableGridColumn<SalesGridRow>(
        key: 'discount',
        label: '折扣',
        // 报价的空折扣格显示「财务核价时填写」, 识别导入的行还带黄标图标(占 44):
        // 默认列宽要把这句话和图标一起装下, 不被省略号吃成「财…」。
        width: isQuote ? 188 : 128,
        numeric: true,
        required: !isQuote && !priceMasked,
        // 表头 ⓘ 悬停说明折扣口径（2026-09-04 用户口径）；格内不再重复 ⓘ。
        headerInfo: l10n.workflowDiscountHint,
        frozenTextOf: (r) => priceMasked
            ? '***'
            : r.quoteDiscountLocked
            ? '${r.discount.text} ${intakeText.salesIntakeQuoteLockedDiscount}'
            : r.discount.text,
        cellBuilder: (context, row) {
          if (priceMasked) {
            // 不能把旧草稿控制器挂到只读框：hint 不会遮住已有文字。
            return Tooltip(
              message: intakeText.salesIntakeMaskedDiscount,
              child: const Text('***', textAlign: TextAlign.right),
            );
          }
          if (row.quoteDiscountLocked) {
            return _lockedCell(
              context,
              row.discount,
              tag: intakeText.salesIntakeQuoteLockedDiscount,
              info: intakeText.salesIntakeQuoteLockedDiscountInfo,
            );
          }
          return RequiredCellFrame(
            listenable: row.discount,
            isEmpty: () => isQuote
                ? row.discount.text.trim().isNotEmpty &&
                      !isValidSalesOrderDiscountText(row.discount.text)
                : !isValidSalesOrderDiscountText(row.discount.text),
            child: _aiFilledField(
              row,
              'discount',
              (decorate) => ValueListenableBuilder<String?>(
                valueListenable: row.aiReviewNotifier,
                builder: (context, review, _) => TextField(
                  controller: row.discount,
                  textAlign: TextAlign.right,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: decorate(
                    applyAutofillHint(
                      InputDecoration(
                        isDense: true,
                        hintText: isQuote
                            ? intakeText.salesIntakeQuoteDiscountPending
                            : null,
                      ),
                      Theme.of(context),
                      autofilled:
                          review != null && row.discount.text.trim().isEmpty,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    // 文件单价：客户文件里的单价(文件币种)，只读参考，仅在有值时出现。
    if (hasClientText && showClientPrice)
      EditableGridColumn<SalesGridRow>(
        key: 'clientPrice',
        label: clientFileCurrency == null
            ? intakeText.salesIntakeColClientPrice
            : intakeText.salesIntakeColClientPriceWithCurrency(
                clientFileCurrency,
              ),
        width: 120,
        numeric: true,
        headerInfo: intakeText.salesIntakeColClientPriceInfo,
        frozenTextOf: (r) => r.clientPrice ?? '',
        cellBuilder: (context, row) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            row.clientPrice ?? '—',
            textAlign: TextAlign.right,
            style: TextStyle(
              color: row.clientPrice == null
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : null,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    if (!freeCustomerShipment)
      EditableGridColumn<SalesGridRow>(
        key: 'amount',
        // 销售订单金额是所选订单币种的原币金额；销售端不展示人民币换算，
        // 也不要用“¥”让外币订单看起来像人民币。
        label: docType == SalesDocType.order
            ? '总金额(订单币种)'
            : docType == SalesDocType.customerShipment
            ? '总金额预览(所选币种)'
            : '总金额',
        width: allowsTotalInput ? 188 : 150,
        numeric: true,
        headerInfo: allowsTotalInput
            ? '可输入数量和总金额计算单价，也可选择按单价和总金额计算数量。'
                  '有关联来源的行沿用来源金额。'
            : '总金额随数量、单价和适用折扣自动计算；单价沿用主档或来源单据。',
        frozenTextOf: (r) => priceMasked
            ? '***'
            : r.amountExactNotifier.value == null
            ? ''
            : docType == SalesDocType.order ||
                  docType == SalesDocType.customerShipment ||
                  isQuote
            ? financeExactMoneyDisplay(r.amountExactNotifier.value!)
            : '¥${financeExactMoneyDisplay(r.amountExactNotifier.value!)}',
        cellBuilder: (context, row) => priceMasked
            ? const Text('***', textAlign: TextAlign.right)
            : allowsTotalInput && row.canEditTotal
            ? LinePricingAmountCell(controller: row.pricing)
            : ValueListenableBuilder<String?>(
                valueListenable: row.amountExactNotifier,
                builder: (_, v, _) => Text(
                  v == null
                      ? '—'
                      : docType == SalesDocType.order ||
                            docType == SalesDocType.customerShipment ||
                            isQuote
                      ? financeExactMoneyDisplay(v)
                      : '¥${financeExactMoneyDisplay(v)}',
                ),
              ),
      ),
    // 报表补列（与 _save/_init 字段映射一致；按 docType 显隐）。
    // 出货单(shipment)只留 货品/颜色/单位/数量/单价/金额/备注：成本分项/折扣等补列不展示
    //（出货是发货履约，价格/折扣沿用订货单）。隐藏列的字段仍在行模型里，编辑既有出货单时
    // 回填并随保存回写，不丢数据。
    if (docType == SalesDocType.order || docType == SalesDocType.otherShipment)
      _extraNumericColumn(
        '机加价',
        'machiningPrice',
        (r) => r.machiningPrice,
        priceMasked: priceMasked,
      ),
    if (docType == SalesDocType.order || docType == SalesDocType.otherShipment)
      _extraNumericColumn('围数', 'circumference', (r) => r.circumference),
    if (docType == SalesDocType.order)
      EditableGridColumn<SalesGridRow>(
        key: 'inboundQty',
        label: '进仓数量(历史参考)',
        width: 160,
        numeric: true,
        defaultVisible: false,
        headerInfo:
            '保留历史单据或旧草稿的参考值；实际进仓数量以入库事实为准，'
            '不在销售订单录入，也不随订单保存。',
        frozenTextOf: (row) => row.inboundQty.text,
        cellBuilder: (context, row) => Text(
          row.inboundQty.text.isEmpty ? '—' : row.inboundQty.text,
          textAlign: TextAlign.right,
        ),
      ),
    if (docType == SalesDocType.otherShipment)
      _extraNumericColumn(
        '材料价',
        'materialPrice',
        (r) => r.materialPrice,
        priceMasked: priceMasked,
      ),
    if (docType == SalesDocType.otherShipment)
      _extraNumericColumn(
        '压铸价',
        'dieCastPrice',
        (r) => r.dieCastPrice,
        priceMasked: priceMasked,
      ),
    if (docType == SalesDocType.otherShipment ||
        docType == SalesDocType.returnDoc)
      _extraNumericColumn(
        '折扣',
        'discount',
        (r) => r.discount,
        priceMasked: priceMasked,
      ),
    // 退货专属：处理方案 / 责任单位（无字典端点，用预置业务选项）。
    if (docType == SalesDocType.returnDoc) ...[
      EditableGridColumn<SalesGridRow>(
        key: 'solution',
        label: '处理方案',
        width: 124,
        textOf: (r) => r.solutionNotifier.value ?? '',
        listenableOf: (r) => r.solutionNotifier,
        chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
        cellBuilder: (context, row) => _returnDropdown(
          row.solutionNotifier,
          const ['退款', '换货', '补发', '维修后返还', '其他'],
        ),
      ),
      EditableGridColumn<SalesGridRow>(
        key: 'responsible',
        label: '责任单位',
        width: 110,
        textOf: (r) => r.responsibleNotifier.value ?? '',
        listenableOf: (r) => r.responsibleNotifier,
        chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
        cellBuilder: (context, row) => _returnDropdown(
          row.responsibleNotifier,
          const ['本公司', '客户', '物流', '供应商', '其他'],
        ),
      ),
    ],
    // 行备注：5 类单据通用，固定放网格末列。随输入自动加宽（封顶 480 后格内滚动）。
    EditableGridColumn<SalesGridRow>(
      key: 'remark',
      label: '备注',
      width: 160,
      textOf: (r) => r.remark.text,
      listenableOf: (r) => r.remark,
      cellBuilder: (context, row) => _aiFilledField(
        row,
        'remark',
        (decorate) => TextField(
          controller: row.remark,
          decoration: decorate(const InputDecoration(isDense: true)),
        ),
      ),
    ),
    ...businessEditableColumns<SalesGridRow>(
      businessColumnsOf(rows),
      rowOf: (row) => row,
      amountHint: intakeText.businessColumnAmountHint,
      priceMasked: priceMasked,
    ),
  ];
}

/// 只读主档字段单元格（颜色/单位自动回填后用）：显示 entries[id] 名，空显示「—」。
Widget _readOnlyMasterCell(
  BuildContext context,
  ValueNotifier<String?> notifier,
  Map<String, String> entries,
) {
  final theme = Theme.of(context);
  return ValueListenableBuilder<String?>(
    valueListenable: notifier,
    builder: (context, id, _) {
      final name = (id != null && id.isNotEmpty) ? entries[id] : null;
      final hasName = name != null && name.isNotEmpty;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          hasName ? name : '—',
          style: TextStyle(
            color: hasName ? null : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    },
  );
}

/// 锁定单元格(订单/出货单价)：readOnly 保持正文字色，不用 enabled:false 的禁用浅灰；
/// 点击弹说明权威来源（格内 ⓘ 已上移表头，见 salesGridColumns 的 priceHint）。
/// 控制器值可用于客户端预览，但服务端不信任请求体中的单价/金额。
/// 锁定单价说明：表头 ⓘ 与只读格点按提示同一份口径（2026-09-11 去重，
/// 此前两处各硬编码一份易改漏；暂无 l10n key，待补 arb 后统一换成 l10n）。
const String _lockedPriceHint =
    '单价由货品资料或来源单据带入，并由服务端锁定，不可在订货单修改。'
    '复制的新行如单价为空，请重新选择货品取得当前价格';

/// [hint] 空值时的占位(默认「重新选货取价」)；[tag] 值后的小字标记(如「财务定价」
/// 「(报价核定)」)；[info] 点按提示(默认锁定单价说明)。
Widget _lockedCell(
  BuildContext context,
  TextEditingController ctl, {
  String? hint,
  String? tag,
  String? info,
}) {
  final theme = Theme.of(context);
  return TextField(
    controller: ctl,
    readOnly: true,
    textAlign: TextAlign.right,
    style: TextStyle(color: theme.colorScheme.onSurface),
    decoration: UtenInputDecoration(
      InputDecoration(
        isDense: true,
        hintText: hint ?? '重新选货取价',
        suffix: tag == null
            ? null
            : Text(
                tag,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
      ),
    ),
    onTap: () => context.appInfo(info ?? _lockedPriceHint),
  );
}

/// 补列 numeric 列工厂：右对齐数字输入框（与数量/单价同款）。
EditableGridColumn<SalesGridRow> _extraNumericColumn(
  String label,
  String key,
  TextEditingController Function(SalesGridRow row) controller, {
  bool priceMasked = false,
}) {
  return EditableGridColumn<SalesGridRow>(
    key: key,
    label: label,
    width: 100,
    numeric: true,
    defaultVisible: false,
    frozenTextOf: (row) => priceMasked ? '***' : controller(row).text,
    cellBuilder: (context, row) => priceMasked
        ? const Text('***', textAlign: TextAlign.right)
        : TextField(
            controller: controller(row),
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(isDense: true, hintText: '0'),
          ),
  );
}

/// 退货「处理方案 / 责任单位」下拉单元格：订阅 [notifier]，预置业务选项。
/// 2026-09-16 起本文件内统一用自家 UtenDropdownField（单行省略号 + 列宽自适应 +
/// 统一弹层），不再出现原生 DropdownButtonFormField（全站其余处的替换由下拉
/// 组件批次负责）。空格占位用组件默认「请选择」——格内提示字已按 2026-09-27
/// 口径清掉（列头已表意）。
Widget _returnDropdown(ValueNotifier<String?> notifier, List<String> options) {
  return ValueListenableBuilder<String?>(
    valueListenable: notifier,
    builder: (context, value, _) => UtenDropdownField(
      dense: true,
      value: value,
      items: [for (final o in options) UtenDropdownItem(value: o, label: o)],
      onChanged: (v) => notifier.value = v,
    ),
  );
}

/// AI 助手填入的格子黄框「AI 填入，请核对」(ADR-150)：[build] 拿到一个装饰函数，
/// 未被 AI 填入时原样返回传入的装饰(一字不变)。控件结构恒定，黄框出现/消失不重建
/// 输入框、不丢焦点。
Widget _aiFilledField(
  SalesGridRow row,
  String key,
  Widget Function(InputDecoration Function(InputDecoration base) decorate)
  build,
) => ValueListenableBuilder<Map<String, String>>(
  valueListenable: row.aiFilledNotifier,
  builder: (context, filled, _) => build((base) {
    if (!filled.containsKey(key)) return base;
    final message = UtenFieldMessage.autofill(
      aiPageL10n(context).fieldAiFilledReview,
    );
    return applyAutofillHint(
      base is UtenInputDecoration
          ? base.copyWith(helper: message)
          : UtenInputDecoration(base.copyWith(helper: message)),
      Theme.of(context),
      autofilled: true,
    );
  }),
);
