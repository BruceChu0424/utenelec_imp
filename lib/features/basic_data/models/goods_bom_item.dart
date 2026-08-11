// 货品组装信息（BOM）行模型（对应后端 BomItemView）。
//
// 数值字段一律 (json['x'] as num?)?.toDouble()，防 int/double/String 序列化差异。
// hasChildren = 组件自身也有 BOM（组装树可继续展开，懒加载子级）。

/// 组装信息行：BOM 行 + 组件货品展示信息。
enum BomControlStage {
  start('START', '开工前', '缺料时阻止本批开始生产'),
  assembly('ASSEMBLY', '装配时', '前段可先做，进入装配前必须备齐'),
  finish('FINISH', '完工/包装前', '不阻止前段生产，但完工或包装前必须备齐'),
  ship(
    'SHIP',
    '发货参考',
    '发货参考，不预留包材、不阻止实际发货；纸箱/包装若生产包装必须消耗，请选“完工/包装前（FINISH）”并搭配“按包装（PER_PACKAGE）”或“固定批耗（FIXED_BATCH）”',
  ),
  reference('REFERENCE', '仅参考', '只展示提醒，不预留物料，也不阻断生产或实际发货');

  const BomControlStage(this.code, this.label, this.description);

  final String code;
  final String label;
  final String description;

  bool get supportsHardGate =>
      this == BomControlStage.start ||
      this == BomControlStage.assembly ||
      this == BomControlStage.finish;

  static BomControlStage fromCode(Object? value) => values.firstWhere(
    (item) => item.code == value,
    orElse: () => BomControlStage.start,
  );
}

enum BomConsumptionBasis {
  perUnit('PER_UNIT', '按每件', 'BOM 用量按产品件数成比例计算'),
  perPackage('PER_PACKAGE', '按包装', '每个包装单位消耗一次，并按基准产量换算'),
  fixedBatch('FIXED_BATCH', '固定批耗', '每个生产批次固定消耗一次');

  const BomConsumptionBasis(this.code, this.label, this.description);

  final String code;
  final String label;
  final String description;

  static BomConsumptionBasis fromCode(Object? value) => values.firstWhere(
    (item) => item.code == value,
    orElse: () => BomConsumptionBasis.perUnit,
  );
}

class GoodsBomItem {
  const GoodsBomItem({
    required this.id,
    required this.componentGoodsId,
    this.componentCode,
    this.componentName,
    this.componentModel,
    this.componentSpec,
    this.componentMaterial,
    this.componentUnitName,
    this.componentColorName,
    this.colorLegacyId,
    this.qty,
    this.price,
    this.total,
    this.summary,
    this.legacyId,
    this.hasChildren = false,
    this.componentSourceType,
    this.controlStage = BomControlStage.start,
    this.consumptionBasis = BomConsumptionBasis.perUnit,
    this.basisOutputQty = 1,
    this.allowPartialPackage = true,
    this.hardGate = true,
  });

  final String id;
  final String componentGoodsId;
  final String? componentCode; // 组件编号（唯一关联键）
  final String? componentName;
  final String? componentModel;
  final String? componentSpec;
  final String? componentMaterial; // 材质
  final String? componentUnitName;
  final String? componentColorName; // 行级颜色优先，空回落组件主颜色（后端已解析）
  final int? colorLegacyId;
  final double? qty;
  final double? price;
  final double? total;
  final String? summary; // 备注（外购/外加工...）
  final int? legacyId;
  final bool hasChildren;
  final String? componentSourceType; // 组件来源（自制/采购/委外）
  final BomControlStage controlStage;
  final BomConsumptionBasis consumptionBasis;
  final double basisOutputQty;
  final bool allowPartialPackage;
  final bool hardGate;

  factory GoodsBomItem.fromJson(Map<String, dynamic> json) {
    final controlStage = BomControlStage.fromCode(json['controlStage']);
    return GoodsBomItem(
      id: json['id'] as String,
      componentGoodsId: json['componentGoodsId'] as String,
      componentCode: json['componentCode'] as String?,
      componentName: json['componentName'] as String?,
      componentModel: json['componentModel'] as String?,
      componentSpec: json['componentSpec'] as String?,
      componentMaterial: json['componentMaterial'] as String?,
      componentUnitName: json['componentUnitName'] as String?,
      componentColorName: json['componentColorName'] as String?,
      colorLegacyId: (json['colorLegacyId'] as num?)?.toInt(),
      qty: (json['qty'] as num?)?.toDouble(),
      price: (json['price'] as num?)?.toDouble(),
      total: (json['total'] as num?)?.toDouble(),
      summary: json['summary'] as String?,
      legacyId: (json['legacyId'] as num?)?.toInt(),
      hasChildren: json['hasChildren'] as bool? ?? false,
      componentSourceType: json['componentSourceType'] as String?,
      controlStage: controlStage,
      consumptionBasis: BomConsumptionBasis.fromCode(json['consumptionBasis']),
      basisOutputQty: (json['basisOutputQty'] as num?)?.toDouble() ?? 1,
      allowPartialPackage: json['allowPartialPackage'] as bool? ?? true,
      hardGate:
          controlStage.supportsHardGate && (json['hardGate'] as bool? ?? true),
    );
  }
}
