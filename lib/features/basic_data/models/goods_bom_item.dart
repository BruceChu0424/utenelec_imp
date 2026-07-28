// 货品组装信息（BOM）行模型（对应后端 BomItemView）。
//
// 数值字段一律 (json['x'] as num?)?.toDouble()，防 int/double/String 序列化差异。
// hasChildren = 组件自身也有 BOM（组装树可继续展开，懒加载子级）。

/// 组装信息行：BOM 行 + 组件货品展示信息。
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
  });

  final String id;
  final String componentGoodsId;
  final String? componentCode;      // 组件编号（唯一关联键）
  final String? componentName;
  final String? componentModel;
  final String? componentSpec;
  final String? componentMaterial;  // 材质
  final String? componentUnitName;
  final String? componentColorName; // 行级颜色优先，空回落组件主颜色（后端已解析）
  final int? colorLegacyId;
  final double? qty;
  final double? price;
  final double? total;
  final String? summary;            // 备注（外购/外加工...）
  final int? legacyId;
  final bool hasChildren;

  factory GoodsBomItem.fromJson(Map<String, dynamic> json) => GoodsBomItem(
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
      );
}
