// 采购/委外订货单行级商业条款「学习记忆」模型（/last-terms 返回体）。
//
// 同一货品下次建单自动带出上次的供应商/结账方式(结算方式)/币种/汇率/税率；
// 供应商是否可回填（停用）由前端在落值时判断，其余条款无条件参考。
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
      );

  final String? supplierId;
  final String? settlementMethodId;
  final String? currencyId;
  final double? exchangeRate;
  final double? taxRate;
  final double? purchasePrice;
  final double? subcontractPrice;
}
