import '../../../shared/business_columns/business_column.dart';
// 销售订货单财务确认任务模型（V294 闸门，V300 补驳回与审核详情）。
//
// 后端 SalesOrderFinanceConfirmService 返回的待确认列表行：已审核但未财务确认的
// 销售订货单。确认后订单才对计划部可见（物料分析/待排产/MRP/计划关联）。
// V300：财务可驳回（必填原因，通知归属销售修正）；列表行携带驳回标记/原因与
// 客户应收余额快照，审核详情另见 [SalesOrderFinanceReview]（含产品明细与客户财务快照）。
// ADR-128(2026-09-27)：客户应收改为服务端共用余额视图 [PartyOpenBalance]，按本单币种显示。

import '../../../shared/formatters/money_display.dart';
import '../../../shared/models/party_open_balance.dart';

/// 订单的来源报价(ADR-134)：报价须财务核价确认后才能转订货单，
/// 这里带出核价人/时间，列表与审核页据此显示「报价已核价」。
///
/// 契约(SPEC §6.1 + 服务端 SalesOrderFinanceReviewDto.SourceQuote)：列表行与审核详情都用
/// `sourceQuote{id, billNo, financeConfirmedByName, financeConfirmedAt}`, 「全部行都与报价核定
/// 一致」在同级 `matchesQuote`(列表「报价已核价 · 一致」); 旧形态把它放在
/// `sourceQuote.allLinesMatch`, 解析时两处都认, 同级优先。
class SalesOrderSourceQuote {
  const SalesOrderSourceQuote({
    required this.id,
    this.billNo,
    this.financeConfirmedByName,
    this.financeConfirmedAt,
    this.allLinesMatch,
  });

  final String id;
  final String? billNo;
  final String? financeConfirmedByName;
  final String? financeConfirmedAt;

  /// 旧形态 `sourceQuote.allLinesMatch`(全部行的单价与折扣都与来源报价一致)；未给为 null。
  /// 页面请读外层的 `matchesQuote`。
  final bool? allLinesMatch;

  static SalesOrderSourceQuote? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final map = json.cast<String, dynamic>();
    final id = _string(map['id']);
    if (id == null) return null;
    return SalesOrderSourceQuote(
      id: id,
      billNo: _string(map['billNo']),
      financeConfirmedByName: _string(map['financeConfirmedByName']),
      financeConfirmedAt: _string(map['financeConfirmedAt']),
      allLinesMatch: map['allLinesMatch'] is bool
          ? map['allLinesMatch'] as bool
          : null,
    );
  }
}

class SalesOrderFinancePendingItem {
  const SalesOrderFinancePendingItem({
    required this.orderId,
    required this.billNo,
    this.billDate,
    this.clientName,
    this.sellerName,
    this.deliverDate,
    this.itemCount = 0,
    this.totalOriginal,
    this.currencyCode,
    this.currencyName,
    this.shipmentPolicy,
    this.clientBalance,
    this.financeRejected = false,
    this.financeRejectedReason,
    this.financeRejectedAt,
    this.changeCount = 0,
    this.financeReviewRevision = 0,
    this.sourceQuote,
    this.matchesQuote,
  });

  final String orderId;
  final String billNo;
  final String? billDate;
  final String? clientName;
  final String? sellerName;
  final String? deliverDate;
  final int itemCount;

  /// 金额保留服务端字符串，避免大额或小数在客户端转换时丢精度。
  final String? totalOriginal;
  final String? currencyCode;

  /// 币种显示名（主档 name：人民币/美金…）；展示优先于 [currencyCode] 编号。
  final String? currencyName;

  /// 发运策略（ALLOW_PARTIAL / REQUIRE_COMPLETE / 历史值；标签用 salesShipmentPolicyLabel）。
  final String? shipmentPolicy;

  /// 客户在本单币种下还差多少(ADR-128)：其它币种与原币未核实部分另列，
  /// 是否超信用由服务端按全部币种正式应收(折本币，不扣预收)判定。
  final PartyOpenBalance? clientBalance;

  /// 财务驳回（V300）：已驳回待销售修正；确认后自动清除。
  final bool financeRejected;
  final String? financeRejectedReason;
  final String? financeRejectedAt;

  /// 上次财务确认之后的改量处数（>0 = 确认后修改、待重新确认）。
  final int changeCount;
  final int financeReviewRevision;

  /// 来源报价(ADR-134)；非报价转入为 null。
  final SalesOrderSourceQuote? sourceQuote;

  /// 全部行的单价与折扣都与来源报价一致；非报价转入或服务端未给为 null。
  final bool? matchesQuote;

  bool get canConfirm => orderId.isNotEmpty;

  String get detailRoute =>
      '/finance/sales-order-confirmations/${Uri.encodeComponent(orderId)}';

  factory SalesOrderFinancePendingItem.fromJson(Map<String, dynamic> json) {
    return SalesOrderFinancePendingItem(
      orderId: _string(json['orderId']) ?? '',
      billNo: _string(json['billNo']) ?? '未生成单号',
      billDate: _string(json['billDate']),
      clientName: _string(json['clientName']),
      sellerName: _string(json['sellerName']),
      deliverDate: _string(json['deliverDate']),
      itemCount: _int(json['itemCount']) ?? 0,
      totalOriginal: _string(json['totalOriginal']),
      currencyCode: _string(json['currencyCode']),
      currencyName: _string(json['currencyName']),
      shipmentPolicy: _string(json['shipmentPolicy']),
      clientBalance: PartyOpenBalance.fromJson(json['clientBalance']),
      financeRejected: json['financeRejected'] == true,
      financeRejectedReason: _string(json['financeRejectedReason']),
      financeRejectedAt: _string(json['financeRejectedAt']),
      changeCount: _int(json['changeCount']) ?? 0,
      financeReviewRevision: _int(json['financeReviewRevision']) ?? 0,
      sourceQuote: SalesOrderSourceQuote.tryFromJson(json['sourceQuote']),
      matchesQuote: _matchesQuote(json),
    );
  }
}

class SalesOrderFinancePendingPage {
  const SalesOrderFinancePendingPage({
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
  });

  final List<SalesOrderFinancePendingItem> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;

  factory SalesOrderFinancePendingPage.fromJson(Map<String, dynamic> json) {
    final nested = json['data'];
    final root = nested is Map<String, dynamic>
        ? nested
        : nested is Map
        ? nested.cast<String, dynamic>()
        : json;
    final rawItems = root['items'];
    final items = rawItems is List
        ? rawItems
              .whereType<Map<Object?, Object?>>()
              .map(
                (item) => SalesOrderFinancePendingItem.fromJson(
                  item.cast<String, dynamic>(),
                ),
              )
              .toList(growable: false)
        : const <SalesOrderFinancePendingItem>[];
    final page = _int(root['page']) ?? 1;
    final size = _int(root['size']) ?? items.length;
    final total = _int(root['total']) ?? items.length;
    final totalPages =
        _int(root['totalPages']) ??
        (size <= 0 ? 1 : ((total + size - 1) ~/ size).clamp(1, 1 << 30));
    return SalesOrderFinancePendingPage(
      items: items,
      page: page < 1 ? 1 : page,
      size: size,
      total: total < 0 ? 0 : total,
      totalPages: totalPages < 1 ? 1 : totalPages,
    );
  }
}

/// 财务审核详情（V300 专用审核页）：订单信息 + 产品明细 + 客户财务快照。
class SalesOrderFinanceReview {
  const SalesOrderFinanceReview({
    required this.orderId,
    required this.billNo,
    this.billDate,
    this.clientId,
    this.clientName,
    this.clientCode,
    this.sellerName,
    this.makerName,
    this.createdAt,
    this.deliverDate,
    this.currencyCode,
    this.currencyName,
    this.shipmentPolicy,
    this.shipmentPolicyName,
    this.settlementMethodName,
    this.contractNo,
    this.legacyDepositSnapshot,
    this.remark,
    this.itemCount = 0,
    this.totalOriginal,
    this.clientBalance,
    this.clientCreditFloor,
    this.financeConfirmed = false,
    this.financeConfirmedAt,
    this.financeConfirmedByName,
    this.financeConfirmRemark,
    this.financeRejected = false,
    this.financeRejectedReason,
    this.financeRejectedByName,
    this.financeRejectedAt,
    this.items = const [],
    this.qtyChanges = const [],
    this.commercialChanges = const [],
    this.revisionDiff,
    this.financeReviewRevision = 0,
    this.sourceQuote,
    this.clientFileCurrency,
    this.matchesQuote,
  });

  final String orderId;
  final String billNo;
  final String? billDate;
  final String? clientId;
  final String? clientName;
  final String? clientCode;
  final String? sellerName;
  final String? makerName;
  final String? createdAt;
  final String? deliverDate;
  final String? currencyCode;

  /// 币种显示名（主档 name：人民币/美金…）；展示优先于 [currencyCode] 编号。
  final String? currencyName;
  final String? shipmentPolicy;

  /// 发运策略显示名（服务端解析下发，前端不跨 feature 复用销售标签函数）。
  final String? shipmentPolicyName;
  final String? settlementMethodName;
  final String? contractNo;

  /// 历史订单订金快照；不是资金到账事实，审核 UI 不展示。
  final String? legacyDepositSnapshot;
  final String? remark;
  final int itemCount;
  final String? totalOriginal;

  /// 客户在本单币种下的应收 / 可用预收 / 还差多少(ADR-128)；
  /// 信用额度(`creditLimitLocal`，未设置为 null)与是否超信用(`overCredit`)也在里面。
  final PartyOpenBalance? clientBalance;

  /// 铺底额(客户主档，本币；未配置为 null)。
  final String? clientCreditFloor;

  /// 订单币种显示名：主档名称优先，缺名称退回可读代码，都没有时写「订单币种」。
  String get currencyLabel => financeCurrencyText(
    name: currencyName,
    code: currencyCode,
    fallback: '订单币种',
  );

  final bool financeConfirmed;
  final String? financeConfirmedAt;
  final String? financeConfirmedByName;
  final String? financeConfirmRemark;
  final bool financeRejected;
  final String? financeRejectedReason;
  final String? financeRejectedByName;
  final String? financeRejectedAt;

  final List<SalesOrderFinanceReviewLine> items;

  /// 修改清单（2026-09-05 确认后改量）：上次确认以后每行 以前→现在 数量。
  final List<SalesOrderFinanceQtyChange> qtyChanges;
  final List<SalesOrderCommercialChange> commercialChanges;
  final SalesOrderRevisionDiff? revisionDiff;
  final int financeReviewRevision;

  /// 来源报价(ADR-134，含「全部行与报价一致」标记)；客户文件币种(文件单价列标题用)。
  final SalesOrderSourceQuote? sourceQuote;
  final String? clientFileCurrency;

  /// 全部行的单价与折扣都与来源报价一致；非报价转入或服务端未给为 null。
  final bool? matchesQuote;

  factory SalesOrderFinanceReview.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final rawChanges = json['qtyChanges'];
    return SalesOrderFinanceReview(
      orderId: _string(json['orderId']) ?? '',
      billNo: _string(json['billNo']) ?? '未生成单号',
      billDate: _string(json['billDate']),
      clientId: _string(json['clientId']),
      clientName: _string(json['clientName']),
      clientCode: _string(json['clientCode']),
      sellerName: _string(json['sellerName']),
      makerName: _string(json['makerName']),
      createdAt: _string(json['createdAt']),
      deliverDate: _string(json['deliverDate']),
      currencyCode: _string(json['currencyCode']),
      currencyName: _string(json['currencyName']),
      shipmentPolicy: _string(json['shipmentPolicy']),
      shipmentPolicyName: _string(json['shipmentPolicyName']),
      settlementMethodName: _string(json['settlementMethodName']),
      contractNo: _string(json['contractNo']),
      legacyDepositSnapshot: _string(
        json['legacyDepositSnapshot'] ?? json['deposit'],
      ),
      remark: _string(json['remark']),
      itemCount: _int(json['itemCount']) ?? 0,
      totalOriginal: _string(json['totalOriginal']),
      clientBalance: PartyOpenBalance.fromJson(json['clientBalance']),
      clientCreditFloor: _string(json['clientCreditFloor']),
      financeConfirmed: json['financeConfirmed'] == true,
      financeConfirmedAt: _string(json['financeConfirmedAt']),
      financeConfirmedByName: _string(json['financeConfirmedByName']),
      financeConfirmRemark: _string(json['financeConfirmRemark']),
      financeRejected: json['financeRejected'] == true,
      financeRejectedReason: _string(json['financeRejectedReason']),
      financeRejectedByName: _string(json['financeRejectedByName']),
      financeRejectedAt: _string(json['financeRejectedAt']),
      items: rawItems is List
          ? rawItems
                .whereType<Map<Object?, Object?>>()
                .map(
                  (e) => SalesOrderFinanceReviewLine.fromJson(
                    e.cast<String, dynamic>(),
                  ),
                )
                .toList(growable: false)
          : const [],
      qtyChanges: rawChanges is List
          ? rawChanges
                .whereType<Map<Object?, Object?>>()
                .map(
                  (e) => SalesOrderFinanceQtyChange.fromJson(
                    e.cast<String, dynamic>(),
                  ),
                )
                .toList(growable: false)
          : const [],
      commercialChanges: (json['commercialChanges'] as List? ?? const [])
          .whereType<Map<Object?, Object?>>()
          .map((row) => SalesOrderCommercialChange.fromJson(row))
          .toList(growable: false),
      financeReviewRevision: _int(json['financeReviewRevision']) ?? 0,
      sourceQuote: SalesOrderSourceQuote.tryFromJson(json['sourceQuote']),
      clientFileCurrency: _string(json['clientFileCurrency']),
      matchesQuote: _matchesQuote(json),
      revisionDiff: json['revisionDiff'] is Map
          ? SalesOrderRevisionDiff.fromJson(
              (json['revisionDiff'] as Map).cast<String, dynamic>(),
            )
          : null,
    );
  }
}

/// Immutable first-before / latest-after rows for the pending finance review.
class SalesOrderRevisionDiff {
  const SalesOrderRevisionDiff({
    required this.beforeItems,
    required this.afterItems,
    required this.changedItemIds,
    required this.headerChanges,
    this.baselineComplete = true,
  });

  final List<SalesOrderRevisionLine> beforeItems;
  final List<SalesOrderRevisionLine> afterItems;
  final Set<String> changedItemIds;
  final List<SalesOrderCommercialChange> headerChanges;

  /// False only for old quantity ledgers that never retained full before-images.
  final bool baselineComplete;

  bool get hasChanges => changedItemIds.isNotEmpty || headerChanges.isNotEmpty;

  factory SalesOrderRevisionDiff.fromJson(Map<String, dynamic> json) {
    List<SalesOrderRevisionLine> lines(Object? value) => value is List
        ? value
              .whereType<Map<Object?, Object?>>()
              .map(
                (row) => SalesOrderRevisionLine.fromJson(
                  row.cast<String, dynamic>(),
                ),
              )
              .toList(growable: false)
        : const [];
    return SalesOrderRevisionDiff(
      beforeItems: lines(json['beforeItems']),
      afterItems: lines(json['afterItems']),
      changedItemIds: (json['changedItemIds'] as List? ?? const [])
          .map((value) => value.toString())
          .toSet(),
      headerChanges: (json['headerChanges'] as List? ?? const [])
          .whereType<Map<Object?, Object?>>()
          .map(SalesOrderCommercialChange.fromJson)
          .toList(growable: false),
      baselineComplete: json['baselineComplete'] != false,
    );
  }
}

class SalesOrderRevisionLine {
  const SalesOrderRevisionLine({
    required this.itemId,
    this.extraColumns = const [],
    this.lineNo,
    this.goodsCode,
    this.goodsName,
    required this.values,
  });

  final List<BusinessColumn> extraColumns;
  final String itemId;
  final int? lineNo;
  final String? goodsCode;
  final String? goodsName;

  /// Display values come directly from typed immutable snapshots, not diff prose.
  final Map<String, String?> values;

  factory SalesOrderRevisionLine.fromJson(Map<String, dynamic> json) =>
      SalesOrderRevisionLine(
        extraColumns: BusinessColumn.read(json['extraColumns']),
        itemId: _string(json['itemId']) ?? '',
        lineNo: _int(json['lineNo']),
        goodsCode: _string(json['goodsCode']),
        goodsName: _string(json['goodsName']),
        values: json['values'] is Map
            ? (json['values'] as Map).map(
                (key, value) => MapEntry(key.toString(), value?.toString()),
              )
            : const {},
      );
}

class SalesOrderCommercialChange {
  const SalesOrderCommercialChange({
    required this.field,
    required this.beforeValue,
    required this.afterValue,
    required this.changedByName,
    required this.changedAt,
  });

  factory SalesOrderCommercialChange.fromJson(Map<Object?, Object?> json) =>
      SalesOrderCommercialChange(
        field: json['field']?.toString() ?? '',
        beforeValue: json['beforeValue']?.toString() ?? '',
        afterValue: json['afterValue']?.toString() ?? '',
        changedByName: json['changedByName']?.toString() ?? '',
        changedAt: json['changedAt']?.toString() ?? '',
      );

  final String field;
  final String beforeValue;
  final String afterValue;
  final String changedByName;
  final String changedAt;
}

/// 修改清单行（确认后改量）：货品 + 以前数量 → 现在数量 + 修改人/时间。
class SalesOrderFinanceQtyChange {
  const SalesOrderFinanceQtyChange({
    required this.orderItemId,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitName,
    this.oldQty,
    this.newQty,
    this.changedByName,
    this.changedAt,
  });

  final String orderItemId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitName;
  final String? oldQty;
  final String? newQty;
  final String? changedByName;
  final String? changedAt;

  factory SalesOrderFinanceQtyChange.fromJson(Map<String, dynamic> json) {
    return SalesOrderFinanceQtyChange(
      orderItemId: _string(json['orderItemId']) ?? '',
      goodsCode: _string(json['goodsCode']),
      goodsName: _string(json['goodsName']),
      colorName: _string(json['colorName']),
      unitName: _string(json['unitName']),
      oldQty: _string(json['oldQty']),
      newQty: _string(json['newQty']),
      changedByName: _string(json['changedByName']),
      changedAt: _string(json['changedAt']),
    );
  }
}

/// 审核明细行（货品快照优先；颜色/单位已按主档解析名称）。
class SalesOrderFinanceReviewLine {
  const SalesOrderFinanceReviewLine({
    this.extraColumns = const [],
    this.goodsNameEn,
    required this.itemId,
    this.lineNo,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitId,
    this.unitName,
    this.clientModel,
    this.qty,
    this.weight,
    this.price,
    this.discount,
    this.amountOriginal,
    this.remark,
    this.quotePrice,
    this.quoteDiscount,
    this.matchesQuote,
    this.clientPrice,
    this.clientGoodsName,
  });

  final List<BusinessColumn> extraColumns;
  final String? goodsNameEn;
  final String itemId;
  final int? lineNo;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;

  /// 来源报价行的单价与财务核定折扣(ADR-134)；非报价转入行为 null。
  final String? quotePrice;
  final String? quoteDiscount;

  /// 本行单价与折扣都与来源报价行一致；非报价转入行为 null。
  final bool? matchesQuote;

  /// 客户文件里的单价(文件币种原币，只作对照)与品名。
  final String? clientPrice;
  final String? clientGoodsName;

  /// 单位主键：「合计数量」按它分组，不同单位的数量绝不相加。
  final String? unitId;
  final String? unitName;
  final String? clientModel;
  final String? qty;
  final String? weight;
  final String? price;
  final String? discount;
  final String? amountOriginal;
  final String? remark;

  factory SalesOrderFinanceReviewLine.fromJson(Map<String, dynamic> json) {
    return SalesOrderFinanceReviewLine(
      extraColumns: BusinessColumn.read(json['extraColumns']),
      goodsNameEn: json['goodsNameEn']?.toString(),
      itemId: _string(json['itemId']) ?? '',
      lineNo: _int(json['lineNo']),
      goodsCode: _string(json['goodsCode']),
      goodsName: _string(json['goodsName']),
      colorName: _string(json['colorName']),
      unitId: _string(json['unitId']),
      unitName: _string(json['unitName']),
      clientModel: _string(json['clientModel']),
      qty: _string(json['qty']),
      weight: _string(json['weight']),
      price: _string(json['price']),
      discount: _string(json['discount']),
      amountOriginal: _string(json['amountOriginal']),
      remark: _string(json['remark']),
      quotePrice: _string(json['quotePrice']),
      quoteDiscount: _string(json['quoteDiscount']),
      matchesQuote: json['matchesQuote'] is bool
          ? json['matchesQuote'] as bool
          : null,
      clientPrice: _string(json['clientPrice']),
      clientGoodsName: _string(json['clientGoodsName']),
    );
  }
}

String? _string(Object? value) {
  if (value == null) return null;
  final result = value.toString().trim();
  return result.isEmpty ? null : result;
}

int? _int(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

/// 订单级「全部行都与来源报价核定一致」: 同级 `matchesQuote` 优先, 旧形态
/// `sourceQuote.allLinesMatch` 兜底; 非报价转入(没有 sourceQuote)为 null。
bool? _matchesQuote(Map<String, dynamic> json) {
  final quote = json['sourceQuote'];
  if (quote is! Map) return null;
  final top = json['matchesQuote'];
  if (top is bool) return top;
  final legacy = quote['allLinesMatch'];
  return legacy is bool ? legacy : null;
}
