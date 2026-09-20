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
    this.taxRate,
    // V593：货品主档默认单价（采购=purchasePrice / 委外=subcontractPrice），
    // 随 /last-terms 一起带回，订货行单价预填用。
    this.purchasePrice,
    this.subcontractPrice,
    this.priceContext,
  });

  factory ProcurementLastTerms.fromJson(Map<String, dynamic> json) =>
      ProcurementLastTerms(
        supplierId: json['supplierId'] as String?,
        settlementMethodId: json['settlementMethodId'] as String?,
        currencyId: json['currencyId'] as String?,
        exchangeRate: (json['exchangeRate'] as num?)?.toDouble(),
        taxRate: (json['taxRate'] as num?)?.toDouble(),
        purchasePrice: (json['purchasePrice'] as num?)?.toDouble(),
        subcontractPrice: (json['subcontractPrice'] as num?)?.toDouble(),
        priceContext: json['priceContext'] is Map<String, dynamic>
            ? ProcurementPriceContext.fromJson(
                json['priceContext'] as Map<String, dynamic>,
              )
            : null,
      );

  final String? supplierId;
  final String? settlementMethodId;
  final String? currencyId;
  final double? exchangeRate;
  final double? taxRate;
  final double? purchasePrice;
  final double? subcontractPrice;
  final ProcurementPriceContext? priceContext;
}

/// 单价必须在原供应商、颜色、单位、币种和税率下使用；缺证据的旧值不猜测。
class ProcurementPriceContext {
  const ProcurementPriceContext({
    this.supplierId,
    this.colorId,
    this.unitId,
    this.currencyId,
    this.taxRate,
  });

  factory ProcurementPriceContext.fromJson(Map<String, dynamic> json) =>
      ProcurementPriceContext(
        supplierId: json['supplierId'] as String?,
        colorId: json['colorId'] as String?,
        unitId: json['unitId'] as String?,
        currencyId: json['currencyId'] as String?,
        taxRate: (json['taxRate'] as num?)?.toDouble(),
      );

  final String? supplierId;
  final String? colorId;
  final String? unitId;
  final String? currencyId;
  final double? taxRate;

  bool matches({
    required String? supplierId,
    required String? colorId,
    required String? unitId,
    required String? currencyId,
    required double? taxRate,
  }) =>
      this.supplierId != null &&
      this.unitId != null &&
      this.currencyId != null &&
      this.taxRate != null &&
      this.supplierId == supplierId &&
      this.colorId == colorId &&
      this.unitId == unitId &&
      this.currencyId == currencyId &&
      this.taxRate == taxRate;
}
