// 销售订货单财务确认任务模型（V294 闸门，V300 补驳回与审核详情）。
//
// 后端 SalesOrderFinanceConfirmService 返回的待确认列表行：已审核但未财务确认的
// 销售订货单。确认后订单才对计划部可见（物料分析/待排产/MRP/计划关联）。
// V300：财务可驳回（必填原因，通知归属销售修正）；列表行携带驳回标记/原因与
// 客户应收余额快照，审核详情另见 [SalesOrderFinanceReview]（含产品明细与客户财务快照）。

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
    this.clientOutstanding,
    this.financeRejected = false,
    this.financeRejectedReason,
    this.financeRejectedAt,
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

  /// 客户当前应收余额（本币，ar_ap_ledger 未结口径；服务端字符串保精度）。
  final String? clientOutstanding;

  /// 财务驳回（V300）：已驳回待销售修正；确认后自动清除。
  final bool financeRejected;
  final String? financeRejectedReason;
  final String? financeRejectedAt;

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
      clientOutstanding: _string(json['clientOutstanding']),
      financeRejected: json['financeRejected'] == true,
      financeRejectedReason: _string(json['financeRejectedReason']),
      financeRejectedAt: _string(json['financeRejectedAt']),
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
    this.clientOutstanding,
    this.clientCredit,
    this.clientCreditFloor,
    this.clientOverCredit = false,
    this.financeConfirmed = false,
    this.financeConfirmedAt,
    this.financeConfirmedByName,
    this.financeConfirmRemark,
    this.financeRejected = false,
    this.financeRejectedReason,
    this.financeRejectedByName,
    this.financeRejectedAt,
    this.items = const [],
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

  /// 客户应收余额（本币未结口径）。
  final String? clientOutstanding;

  /// 信用额度 / 铺底额（客户主档；未配置为 null）。
  final String? clientCredit;
  final String? clientCreditFloor;

  /// 应收余额是否已超信用额度（信用额度未配置时恒 false）。
  final bool clientOverCredit;

  final bool financeConfirmed;
  final String? financeConfirmedAt;
  final String? financeConfirmedByName;
  final String? financeConfirmRemark;
  final bool financeRejected;
  final String? financeRejectedReason;
  final String? financeRejectedByName;
  final String? financeRejectedAt;

  final List<SalesOrderFinanceReviewLine> items;

  factory SalesOrderFinanceReview.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
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
      clientOutstanding: _string(json['clientOutstanding']),
      clientCredit: _string(json['clientCredit']),
      clientCreditFloor: _string(json['clientCreditFloor']),
      clientOverCredit: json['clientOverCredit'] == true,
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
    );
  }
}

/// 审核明细行（货品快照优先；颜色/单位已按主档解析名称）。
class SalesOrderFinanceReviewLine {
  const SalesOrderFinanceReviewLine({
    required this.itemId,
    this.lineNo,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitName,
    this.clientModel,
    this.qty,
    this.weight,
    this.price,
    this.discount,
    this.amountOriginal,
    this.remark,
  });

  final String itemId;
  final int? lineNo;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
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
      itemId: _string(json['itemId']) ?? '',
      lineNo: _int(json['lineNo']),
      goodsCode: _string(json['goodsCode']),
      goodsName: _string(json['goodsName']),
      colorName: _string(json['colorName']),
      unitName: _string(json['unitName']),
      clientModel: _string(json['clientModel']),
      qty: _string(json['qty']),
      weight: _string(json['weight']),
      price: _string(json['price']),
      discount: _string(json['discount']),
      amountOriginal: _string(json['amountOriginal']),
      remark: _string(json['remark']),
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
