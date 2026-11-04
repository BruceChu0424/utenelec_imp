import '../formatters/exact_decimal.dart';

// 采购/委外订货单行级商业条款的主档默认值模型 (/last-terms 返回体)。
//
// 类名 ProcurementLastTerms 与端点路径 /last-terms 都是历史遗留: 语义自 V592/V593
// 起是**主档默认值**, 不再是「按上次单据推导」——读货品与供应商主档的默认条款
// (默认供应商/结账方式/币种/汇率/税率/默认单价), 每次保存订单由服务端写回主档。
// 仅在当前行供应商一致且字典有效时参考条款；单价还须匹配完整商业上下文。
class ProcurementLastTerms {
  const ProcurementLastTerms({
    this.supplierId,
    this.settlementMethodId,
    this.currencyId,
    this.exchangeRate,
    this.exchangeRateExact,
    this.taxRate,
    this.taxRateExact,
    // V593：货品主档默认单价（采购=purchasePrice / 委外=subcontractPrice），
    // 随 /last-terms 一起带回，订货行单价预填用。
    this.purchasePrice,
    this.purchasePriceExact,
    this.subcontractPrice,
    this.subcontractPriceExact,
    this.priceContext,
    // ADR-098：货品主档「委外允许损耗」默认值（记忆），委外订货行允许损耗列预填用。
    this.allowedLossPct,
    this.allowedLossPctExact,
    this.allowedLossPctSource,
    // ADR-144：货品主档「采购允许超收」默认值（记忆），采购订货行允许超收列预填用。
    this.allowedOverReceiptPct,
    this.allowedOverReceiptPctExact,
    this.allowedOverReceiptPctSource,
  });

  factory ProcurementLastTerms.fromJson(
    Map<String, dynamic> json,
  ) => ProcurementLastTerms(
    supplierId: json['supplierId'] as String?,
    settlementMethodId: json['settlementMethodId'] as String?,
    currencyId: json['currencyId'] as String?,
    exchangeRate: double.tryParse(json['exchangeRate']?.toString() ?? ''),
    exchangeRateExact: (json['exchangeRateExact'] ?? json['exchangeRate'])
        ?.toString(),
    taxRate: double.tryParse(json['taxRate']?.toString() ?? ''),
    taxRateExact: (json['taxRateExact'] ?? json['taxRate'])?.toString(),
    purchasePrice: double.tryParse(json['purchasePrice']?.toString() ?? ''),
    purchasePriceExact: (json['purchasePriceExact'] ?? json['purchasePrice'])
        ?.toString(),
    subcontractPrice: double.tryParse(
      json['subcontractPrice']?.toString() ?? '',
    ),
    subcontractPriceExact:
        (json['subcontractPriceExact'] ?? json['subcontractPrice'])?.toString(),
    priceContext: json['priceContext'] is Map<String, dynamic>
        ? ProcurementPriceContext.fromJson(
            json['priceContext'] as Map<String, dynamic>,
          )
        : null,
    allowedLossPct: (json['allowedLossPct'] as num?)?.toDouble(),
    allowedLossPctExact: (json['allowedLossPctExact'] ?? json['allowedLossPct'])
        ?.toString(),
    allowedLossPctSource: json['allowedLossPctSource'] as String?,
    allowedOverReceiptPct: (json['allowedOverReceiptPct'] as num?)?.toDouble(),
    allowedOverReceiptPctExact:
        (json['allowedOverReceiptPctExact'] ?? json['allowedOverReceiptPct'])
            ?.toString(),
    allowedOverReceiptPctSource: json['allowedOverReceiptPctSource'] as String?,
  );

  final String? supplierId;
  final String? settlementMethodId;
  final String? currencyId;
  final double? exchangeRate;
  final String? exchangeRateExact;
  String? get exchangeRateText =>
      financeExactDecimal(exchangeRateExact ?? exchangeRate);
  final double? taxRate;
  final String? taxRateExact;
  String? get taxRateText => financeExactDecimal(taxRateExact ?? taxRate);
  final double? purchasePrice;
  final String? purchasePriceExact;
  String? get purchasePriceText =>
      financeExactDecimal(purchasePriceExact ?? purchasePrice);
  final double? subcontractPrice;
  final String? subcontractPriceExact;
  String? get subcontractPriceText =>
      financeExactDecimal(subcontractPriceExact ?? subcontractPrice);
  final ProcurementPriceContext? priceContext;

  /// 委外允许损耗默认值(%)；来源目前只有 GOODS_MASTER（货品主档记忆）。
  final double? allowedLossPct;
  final String? allowedLossPctExact;
  String? get allowedLossPctText =>
      allowedLossPctExact ?? allowedLossPct?.toString();
  final String? allowedLossPctSource;

  /// 采购允许超收默认值(%)；来源目前只有 GOODS_MASTER（货品主档记忆）。不受价格遮蔽。
  final double? allowedOverReceiptPct;
  final String? allowedOverReceiptPctExact;
  String? get allowedOverReceiptPctText =>
      allowedOverReceiptPctExact ?? allowedOverReceiptPct?.toString();
  final String? allowedOverReceiptPctSource;
}

/// 单价必须在原供应商、颜色、单位、币种和税率下使用；缺证据的旧值不猜测。
class ProcurementPriceContext {
  const ProcurementPriceContext({
    this.supplierId,
    this.colorId,
    this.unitId,
    this.currencyId,
    this.taxRate,
    this.taxRateExact,
  });

  factory ProcurementPriceContext.fromJson(Map<String, dynamic> json) =>
      ProcurementPriceContext(
        supplierId: json['supplierId'] as String?,
        colorId: json['colorId'] as String?,
        unitId: json['unitId'] as String?,
        currencyId: json['currencyId'] as String?,
        taxRate: double.tryParse(json['taxRate']?.toString() ?? ''),
        taxRateExact: (json['taxRateExact'] ?? json['taxRate'])?.toString(),
      );

  final String? supplierId;
  final String? colorId;
  final String? unitId;
  final String? currencyId;
  final double? taxRate;
  final String? taxRateExact;
  String? get taxRateText => financeExactDecimal(taxRateExact ?? taxRate);

  bool matches({
    required String? supplierId,
    required String? colorId,
    required String? unitId,
    required String? currencyId,
    required Object? taxRate,
  }) =>
      this.supplierId != null &&
      this.unitId != null &&
      this.currencyId != null &&
      taxRateText != null &&
      this.supplierId == supplierId &&
      this.colorId == colorId &&
      this.unitId == unitId &&
      this.currencyId == currencyId &&
      financeAmountUnits(taxRateText) != null &&
      financeAmountUnits(taxRateText) ==
          financeAmountUnits(financeExactDecimal(taxRate));
}
