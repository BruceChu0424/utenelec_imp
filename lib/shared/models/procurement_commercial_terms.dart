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
  });

  factory ProcurementLastTerms.fromJson(Map<String, dynamic> json) =>
      ProcurementLastTerms(
        supplierId: json['supplierId'] as String?,
        settlementMethodId: json['settlementMethodId'] as String?,
        currencyId: json['currencyId'] as String?,
        exchangeRate: (json['exchangeRate'] as num?)?.toDouble(),
        taxRate: (json['taxRate'] as num?)?.toDouble(),
      );

  final String? supplierId;
  final String? settlementMethodId;
  final String? currencyId;
  final double? exchangeRate;
  final double? taxRate;
}
