// 货品组装信息(BOM)行模型(对应后端 BomItemView)+ 「BOM 学习记录」模型。
//
// 数值字段一律 (json['x'] as num?)?.toDouble()，防 int/double/String 序列化差异。
// hasChildren = 组件自身也有 BOM（组装树可继续展开，懒加载子级）。
//
// ADR-129 两个数：qty = 设计使用数量(工程人员维护)；真实使用数量来自学习
// 累计(服务端视图 v_goods_bom_item_usage 一次算好)。组装信息行与学习记录
// 共用 [BomActualUsage]，页面只展示、不重算。日报登记的不良数只作记录：
// 真实使用数量仍按良品，不良数、实产单耗与不良率由服务端一并给出作说明。
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/measurement/measurement_totals.dart';

/// BOM 用量展示(设计/真实使用数量、基准产量、学习累计)：固定 6 位再去尾零，
/// 与服务端 6 位计算口径一致，不出现浮点噪声或科学计数法。
String formatBomQty(double value) => formatMeasurementValue(value, scale: 6);

/// 不良率(0..1)展示为百分数：最多 2 位小数再去尾零，如 0.0325 → 3.25%、
/// 0.1 → 10%。凡展示不良率的页面都用这一处，不各写一份。
String formatBomDefectRate(double rate) {
  final percent = rate * 100;
  // 有不良但不到 0.01% 时不显示成 0%。
  if (percent > 0 && percent < 0.005) return '<0.01%';
  return '${formatMeasurementValue(percent, scale: 2)}%';
}

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

/// 真实使用数量状态(ADR-129，v_goods_bom_item_usage.actual_status)。
enum BomActualStatus {
  /// 有真实数据，计算按真实使用数量。
  actual('ACTUAL'),

  /// 还没有已完工且核清余料的生产数据。
  noData('NO_DATA'),

  /// 整包(不允许尾包)或固定批次：平均单耗不能代替非线性规则。
  notLinear('NOT_LINEAR'),

  /// 父件基本单位在学习后变了，需重新学习。
  outputUnitChanged('OUTPUT_UNIT_CHANGED');

  const BomActualStatus(this.code);

  final String code;

  /// 未知或缺省返回 null。
  static BomActualStatus? fromCode(Object? value) {
    for (final item in values) {
      if (item.code == value) return item;
    }
    return null;
  }
}

/// 物料分析节点独有的原因代码(usage_reason)：本次由委外单一子件发料。
const _reasonSubcontractOutbound = 'SUBCONTRACT_OUTBOUND';

/// 为什么按设计使用数量算：原因代码 → 人话(只是原因本身，不带「计算按设计」)。
///
/// 代码与服务端同一词表：[BomActualStatus] 里「不采用真实值」的三种状态，外加
/// 物料分析节点的 SUBCONTRACT_OUTBOUND；未知或缺省给通用说法。组装信息、
/// 学习记录与物料分析的说明都走这一个映射，不各写一份。
String bomDesignReasonText(AppLocalizations l10n, String? code) {
  if (code == _reasonSubcontractOutbound) {
    return l10n.bomDesignReasonSubcontractOutbound;
  }
  return switch (BomActualStatus.fromCode(code)) {
    BomActualStatus.noData => l10n.bomDesignReasonNoData,
    BomActualStatus.notLinear => l10n.bomDesignReasonNotLinear,
    BomActualStatus.outputUnitChanged => l10n.bomDesignReasonOutputUnitChanged,
    BomActualStatus.actual || null => l10n.bomDesignReasonOther,
  };
}

/// 真实使用数量(ADR-129)：学习累计 + 本边计算采用哪个数。
///
/// 组装信息行(BomItemView)与「BOM 学习记录」组件行用同一组 actual* 字段，
/// 统一由 [BomActualUsage.fromJson] 解析，悬停说明与表格展示只写一份。
class BomActualUsage {
  const BomActualUsage({
    this.qty,
    this.perUnitQty,
    this.status,
    this.usesActual = false,
    this.netQty = 0,
    this.outputQty = 0,
    this.sampleCount = 0,
    this.defectQty = 0,
    this.perProducedQty,
    this.defectRate,
    this.updatedAt,
    this.relearnedAt,
  });

  /// 没有任何学习记录。
  static const none = BomActualUsage();

  /// 真实使用数量(与设计使用数量同一计量口径；BOM 外的料没有边，是每个父件
  /// 基本单位的平均用量)；只有 [status] 为 actual 才有值。
  final double? qty;

  /// 每个父件基本单位平均用多少(组件基本单位)：学习累计可用时才有值，
  /// 整包/固定批次也照常给出；没有数据或父件单位变了为空。
  final double? perUnitQty;

  final BomActualStatus? status;

  /// 计算采用真实使用数量(usageBasis=ACTUAL)；否则按设计使用数量。
  final bool usesActual;

  /// 累计净耗料(重新学习后只算新数据)。
  final double netQty;

  /// 累计产量(只算用到该物料的生产批次)。
  final double outputQty;

  /// 有效生产批次。
  final int sampleCount;

  /// 累计不良数(父件单位，与 [outputQty] 同一批次范围)：日报登记的不良只作
  /// 记录，不计入 [outputQty]，真实使用数量仍按良品算。
  final double defectQty;

  /// 按实产(良品+不良)每件用量，与 [qty] 同一计量口径；只有 [status] 为
  /// actual 才有值。
  final double? perProducedQty;

  /// 不良率(0..1) = 不良 ÷ (良品+不良)；这段累计里没有产出时为空。
  final double? defectRate;

  /// 学习累计最近更新时间；为空 = 还没有累计记录。
  final DateTime? updatedAt;

  /// 最近一次重新累计的起点(中国墙上时间)：有人「从现在起重新学习」，
  /// 或系统升级时统一从头累计(后者没有操作人)。
  final DateTime? relearnedAt;

  /// 组装信息行与学习记录组件行共用的 actual* 字段(服务端同一个 BomItemUsage)。
  factory BomActualUsage.fromJson(Map<String, dynamic> json) => BomActualUsage(
    qty: (json['actualQty'] as num?)?.toDouble(),
    perUnitQty: (json['actualPerUnitQty'] as num?)?.toDouble(),
    status: BomActualStatus.fromCode(json['actualStatus']),
    usesActual: json['usageBasis'] == 'ACTUAL',
    netQty: (json['actualNetQty'] as num?)?.toDouble() ?? 0,
    outputQty: (json['actualOutputQty'] as num?)?.toDouble() ?? 0,
    sampleCount: (json['actualSampleCount'] as num?)?.toInt() ?? 0,
    defectQty: (json['actualDefectQty'] as num?)?.toDouble() ?? 0,
    perProducedQty: (json['actualPerProducedQty'] as num?)?.toDouble(),
    defectRate: (json['actualDefectRate'] as num?)?.toDouble(),
    updatedAt: ChinaDateTime.tryParse(json['actualUpdatedAt'] as String?),
    relearnedAt: ChinaDateTime.tryParse(json['relearnedAt'] as String?),
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
    this.actual = BomActualUsage.none,
    this.systemLearned = false,
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

  /// 设计使用数量(goods_bom_items.qty，工程人员维护)。
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

  /// 真实使用数量与学习累计(只读，服务端视图给出)。
  final BomActualUsage actual;

  /// 系统按真实用料学出的组件(人改了设计使用数量等配方列后转为人工维护)。
  final bool systemLearned;

  /// 组件的发料方式 (ADR-131)：PERIODIC = 整批领到车间内料仓的料 (颗粒等)，
  /// 这一行是「期间边」：数量只表示单个重量，管控阶段/计量方式/齐套门槛固定。
  final String? componentIssueMethod;

  /// 服务端给出的单个重量 (克)；旧响应没有时按 [qty] 与组件单位换算。
  final double? unitWeightGrams;

  /// 保存后服务端给的提醒 (如与货品资料单重相差 20% 以上)；只提示，不拦截。
  final List<String> warnings;

  /// 已审 = 审计标记非空。
  bool get audited => auditedAt != null;

  /// 设计使用数量展示。
  String get designQtyText => qty == null ? '' : formatBomQty(qty!);

  /// 真实使用数量展示：没有数据或不适用显示「—」(原因见 [actual] 的 status)。
  String get actualQtyText =>
      actual.qty == null ? '—' : formatBomQty(actual.qty!);

  String get basisOutputQtyText => formatBomQty(basisOutputQty);

  /// 尾包展示：只有「按包装」显示 允许/整包，其余 —(表格/预览/PDF 同口径)。
  String get partialPackageLabel =>
      consumptionBasis == BomConsumptionBasis.perPackage
      ? (allowPartialPackage ? '允许' : '整包')
      : '—';

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
      actual: BomActualUsage.fromJson(json),
      systemLearned: json['systemLearned'] as bool? ?? false,
      componentIssueMethod: json['componentIssueMethod'] as String?,
      unitWeightGrams: (json['unitWeightGrams'] as num?)?.toDouble(),
      warnings: [
        for (final w in (json['warnings'] as List?) ?? const [])
          if (w is String && w.trim().isNotEmpty) w.trim(),
      ],
    );
  }
}

/// 「BOM 学习记录」父件累计(GET /master/goods/{id}/bom-learning 的 profile)。
class GoodsBomLearningProfile {
  const GoodsBomLearningProfile({
    required this.totalOutputQty,
    required this.sampleCount,
    this.totalDefectQty = 0,
    this.blockedReason,
    this.outputUnitName,
  });

  /// 累计实际产量(父件基本单位，良品)。
  final double totalOutputQty;

  /// 有效生产批次。
  final int sampleCount;

  /// 累计不良数(父件基本单位)：只作记录，不计入 [totalOutputQty]。
  final double totalDefectQty;

  /// 为什么没有自动建立学习组件(只拦自动建组件，不影响真实使用数量累计)。
  final String? blockedReason;
  final String? outputUnitName;

  factory GoodsBomLearningProfile.fromJson(Map<String, dynamic> json) =>
      GoodsBomLearningProfile(
        totalOutputQty: (json['totalOutputQty'] as num?)?.toDouble() ?? 0,
        sampleCount: (json['sampleCount'] as num?)?.toInt() ?? 0,
        totalDefectQty: (json['totalDefectQty'] as num?)?.toDouble() ?? 0,
        blockedReason: json['blockedReason'] as String?,
        outputUnitName: json['outputUnitName'] as String?,
      );
}

/// 「BOM 学习记录」逐组件一行：组装信息里的组件、BOM 外实际用过的料、
/// 人工删除后不再自动加入的料。
class GoodsBomLearningComponent {
  const GoodsBomLearningComponent({
    required this.componentGoodsId,
    this.componentCode,
    this.componentName,
    this.unitId,
    this.unitName,
    this.inBom = false,
    this.bomItemId,
    this.systemLearned = false,
    this.released = false,
    this.designQty,
    this.actual = BomActualUsage.none,
  });

  final String componentGoodsId;
  final String? componentCode;
  final String? componentName;
  final String? unitId;
  final String? unitName;

  /// 当前在组装信息里(有 BOM 边)。
  final bool inBom;
  final String? bomItemId;
  final bool systemLearned;

  /// 人工删除过，系统不再自动加入。
  final bool released;

  /// 设计使用数量(BOM 外的料为空)。
  final double? designQty;
  final BomActualUsage actual;

  factory GoodsBomLearningComponent.fromJson(Map<String, dynamic> json) =>
      GoodsBomLearningComponent(
        componentGoodsId: json['componentGoodsId'] as String,
        componentCode: json['componentCode'] as String?,
        componentName: json['componentName'] as String?,
        unitId: json['unitId'] as String?,
        unitName: json['unitName'] as String?,
        inBom: json['inBom'] as bool? ?? false,
        bomItemId: json['bomItemId'] as String?,
        systemLearned: json['systemLearned'] as bool? ?? false,
        released: json['released'] as bool? ?? false,
        designQty: (json['designQty'] as num?)?.toDouble(),
        actual: BomActualUsage.fromJson(json),
      );
}

/// 「BOM 学习记录」整体(profile 为 null = 该父件还没有任何学习样本)。
class GoodsBomLearningSummary {
  const GoodsBomLearningSummary({
    this.profile,
    this.components = const [],
    this.canRelearn = false,
  });

  final GoodsBomLearningProfile? profile;
  final List<GoodsBomLearningComponent> components;

  /// 当前账号能否「从现在起重新学习」(服务端按权限算好下发，页面不自己判)。
  final bool canRelearn;

  factory GoodsBomLearningSummary.fromJson(Map<String, dynamic> json) {
    final profile = json['profile'];
    return GoodsBomLearningSummary(
      canRelearn: json['canRelearn'] as bool? ?? false,
      profile: profile is Map
          ? GoodsBomLearningProfile.fromJson(Map<String, dynamic>.from(profile))
          : null,
      components: [
        for (final row in json['components'] as List? ?? const [])
          GoodsBomLearningComponent.fromJson(
            Map<String, dynamic>.from(row as Map),
          ),
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
