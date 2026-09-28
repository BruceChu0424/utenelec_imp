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
    '发货参考，不预留包材、不阻止实际发货；纸箱/包装若生产包装必须消耗，请选“完工/包装前(FINISH)”并搭配“按包装(PER_PACKAGE)”或“固定批耗(FIXED_BATCH)”',
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
    this.colorId,
    this.colorLegacyId,
    this.defaultSupplierId,
    this.vendLegacyId,
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
    this.auditedAt,
    this.componentIssueMethod,
    this.unitWeightGrams,
    this.warnings = const [],
  });

  final String id;
  final String componentGoodsId;
  final String? componentCode; // 组件显示编号/历史快照；关联键是 componentGoodsId UUID
  final String? componentName;
  final String? componentModel;
  final String? componentSpec;
  final String? componentMaterial; // 材质
  final String? componentUnitName;
  final String? componentColorName; // 行级颜色优先，空回落组件主颜色（后端已解析）
  final String? colorId; // 行级颜色 UUID 真源
  final int? colorLegacyId;
  final String? defaultSupplierId; // 默认供应商 UUID 真源
  final int? vendLegacyId;
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

  /// 审计标记时间（V256）：非空 = 该组件已核对无误（行内容被编辑后服务端清空）。
  final DateTime? auditedAt;

  /// 组件的发料方式 (ADR-131)：PERIODIC = 整批领到车间内料仓的料 (颗粒等)，
  /// 这一行是「期间边」：数量只表示单个重量，管控阶段/计量方式/齐套门槛固定。
  final String? componentIssueMethod;

  /// 服务端给出的单个重量 (克)；旧响应没有时按 [qty] 与组件单位换算。
  final double? unitWeightGrams;

  /// 保存后服务端给的提醒 (如与货品资料单重相差 20% 以上)；只提示，不拦截。
  final List<String> warnings;

  /// 已审 = 审计标记非空。
  bool get audited => auditedAt != null;

  /// 组件是整批领料的料 (这一行是期间边)。
  bool get isPeriodicEdge => componentIssueMethod == 'PERIODIC';

  /// 期间边的单个重量 (克)：服务端值优先，否则按组件基本单位把 [qty] 换算成克；
  /// 单位不是千克/克 (无法换算) 时为 null，界面按原单位显示 [qty]。
  double? get periodicUnitWeightGrams {
    if (!isPeriodicEdge) return null;
    if (unitWeightGrams != null) return unitWeightGrams;
    final q = qty;
    final factor = periodicGramsPerBaseUnit(componentUnitName);
    if (q == null || factor == null) return null;
    return q * factor;
  }

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
      colorId: json['colorId'] as String?,
      colorLegacyId: (json['colorLegacyId'] as num?)?.toInt(),
      defaultSupplierId: json['defaultSupplierId'] as String?,
      vendLegacyId: (json['vendLegacyId'] as num?)?.toInt(),
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
      auditedAt: DateTime.tryParse(json['auditedAt'] as String? ?? ''),
      componentIssueMethod: json['componentIssueMethod'] as String?,
      unitWeightGrams: (json['unitWeightGrams'] as num?)?.toDouble(),
      warnings: [
        for (final w in (json['warnings'] as List?) ?? const [])
          if (w is String && w.trim().isNotEmpty) w.trim(),
      ],
    );
  }
}

/// 质量单位名 → 每 1 基本单位是多少克 (ADR-131 期间边「按克输入显示」)。
///
/// 颗粒基本单位一般是千克；少数按克记。其它单位 (吨、磅、非质量单位) 返回 null，
/// 界面不做换算、按原单位显示数量。
double? periodicGramsPerBaseUnit(String? unitName) {
  final n = unitName?.trim().toLowerCase();
  if (n == null || n.isEmpty) return null;
  const kilograms = {'kg', 'kgs', '千克', '公斤'};
  const grams = {'g', '克', '公克'};
  if (kilograms.contains(n)) return 1000;
  if (grams.contains(n)) return 1;
  return null;
}

/// 单个重量 (克) 的显示文本：最多 3 位小数，去掉补齐的 0。
String periodicGramsText(double grams) {
  final fixed = grams.toStringAsFixed(3);
  return fixed.contains('.')
      ? fixed.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
      : fixed;
}

/// 单个重量是否在常理之外 (小于 0.1 克或大于 5000 克)，保存前要二次确认。
bool periodicGramsUnusual(double grams) => grams < 0.1 || grams > 5000;

/// 单个重量与货品资料单重相差是否超过 20% (标黄待核对)。
bool periodicGramsDeviates(double grams, double? referenceGrams) {
  if (referenceGrams == null || referenceGrams <= 0) return false;
  return (grams - referenceGrams).abs() / referenceGrams > 0.2;
}
