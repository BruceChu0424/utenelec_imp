// 货品主档模型（对应后端 GoodsListItem / GoodsDetail / GoodsFacets）。
//
// 数值字段一律走 (json['x'] as num?)?.toInt()/toDouble()，避免 int/double 被后端
// 序列化成 String（或 null）时直接 cast 崩溃——老库迁移常踩这个坑。
// price 为后端 BigDecimal（DOUBLE PRECISION 列转 BigDecimal），前端按 double 解析。

import 'master_facet.dart';

/// 货品列表项（含筛选/展示所需的核心字段）。
class GoodsListItem {
  const GoodsListItem({
    required this.id,
    this.code,
    this.name,
    this.spec,
    this.model,
    this.price,
    this.status,
    this.legacyId,
    this.series,
    this.material,
    this.cNumber,
    this.requireRemark,
    this.colorLegacyId,
    this.unitLegacyId,
    this.colorName,
    this.unitName,
    this.sourceType,
    this.categoryId,
    this.autoCreated = false,
  });

  final String id;
  final String? code;
  final String? name;
  final String? spec;
  final String? model;
  final double? price;
  final String? status;
  final int? legacyId;
  final String? series;
  final String? material;
  final String? cNumber;
  final String? requireRemark;
  final int? colorLegacyId;
  final int? unitLegacyId;
  final String? colorName;
  final String? unitName;
  final String? sourceType; // 来源（自制/采购/委外；V128）

  final String? categoryId; // 所属分类 id（货品资料页"搜货品定位分类"用）

  final bool autoCreated; // 迁移兜底占位货品标记（V177；auto_created 列）

  factory GoodsListItem.fromJson(Map<String, dynamic> json) => GoodsListItem(
    id: json['id'] as String,
    code: json['code'] as String?,
    name: json['name'] as String?,
    spec: json['spec'] as String?,
    model: json['model'] as String?,
    price: (json['price'] as num?)?.toDouble(),
    status: json['status'] as String?,
    legacyId: (json['legacyId'] as num?)?.toInt(),
    series: json['series'] as String?,
    material: json['material'] as String?,
    // 后端 @JsonProperty("cNumber") 输出 cNumber；兼容小写兜底。
    cNumber: (json['cNumber'] ?? json['cnumber']) as String?,
    requireRemark: json['requireRemark'] as String?,
    colorLegacyId: (json['colorLegacyId'] as num?)?.toInt(),
    unitLegacyId: (json['unitLegacyId'] as num?)?.toInt(),
    colorName: json['colorName'] as String?,
    unitName: json['unitName'] as String?,
    sourceType: json['sourceType'] as String?,
    categoryId: json['categoryId'] as String?,
    autoCreated: json['autoCreated'] as bool? ?? false,
  );
}

/// 货品详情（列表字段 + 关键业务字段，够看即可）。
class GoodsDetail {
  const GoodsDetail({
    required this.id,
    this.code,
    this.name,
    this.spec,
    this.model,
    this.price,
    this.status,
    this.legacyId,
    this.shortName,
    this.categoryId,
    this.categoryName,
    this.pack,
    this.material,
    this.thickness,
    this.unitLegacyId,
    this.mWeight,
    this.pieces,
    this.colorName,
    this.unitName,
    this.colorLegacyId,
    this.sourceE,
    this.machiningE,
    this.incidentalE,
    this.lacquerE,
    this.platingE,
    this.casingE,
    this.polishE,
    this.total,
    this.workRate,
    this.workE,
    this.lostRate,
    this.lostE,
    this.rentRate,
    this.rentE,
    this.makeRate,
    this.makeE,
    this.cTotal,
    this.gTotal,
    this.sourceType,
  });

  final String id;
  final String? code;
  final String? name;
  final String? spec;
  final String? model;
  final double? price;
  final String? status;
  final int? legacyId;
  final String? shortName;
  final String? categoryId;
  final String? categoryName;
  final String? pack;
  final String? material;
  final double? thickness;
  final int? unitLegacyId;
  final double? mWeight;
  final int? pieces;
  final String? colorName;
  final String? unitName;
  final int? colorLegacyId;

  // ===== 成本预算（「成本预算」页签；对应后端 GoodsDetail 成本字段） =====
  final double? sourceE; // 材料合计
  final double? machiningE; // 加工费
  final double? incidentalE; // 杂费
  final double? lacquerE; // 喷漆、朔费
  final double? platingE; // 电镀费
  final double? casingE; // 包装费
  final double? polishE; // 抛光费
  final double? total; // 成品价
  final double? workRate; // 人工比率(%)
  final double? workE; // 人工费
  final double? lostRate; // 损耗比率(%)
  final double? lostE; // 损耗费
  final double? rentRate; // 厂租比率(%)
  final double? rentE; // 厂房租金
  final double? makeRate; // 生产利率(%)
  final double? makeE; // 生产利润
  final double? cTotal; // 成本价
  final double? gTotal; // 出厂价

  final String? sourceType; // 来源（自制/采购/委外；V128）

  factory GoodsDetail.fromJson(Map<String, dynamic> json) => GoodsDetail(
    id: json['id'] as String,
    code: json['code'] as String?,
    name: json['name'] as String?,
    spec: json['spec'] as String?,
    model: json['model'] as String?,
    price: (json['price'] as num?)?.toDouble(),
    status: json['status'] as String?,
    legacyId: (json['legacyId'] as num?)?.toInt(),
    shortName: json['shortName'] as String?,
    categoryId: json['categoryId'] as String?,
    categoryName: json['categoryName'] as String?,
    pack: json['pack'] as String?,
    material: json['material'] as String?,
    thickness: (json['thickness'] as num?)?.toDouble(),
    unitLegacyId: (json['unitLegacyId'] as num?)?.toInt(),
    // 后端 Jackson 对连续大写字段 mWeight（getter getMWeight）序列化为 "mweight"，
    // 与字段名不符；兼容两种写法，避免"单重"始终取不到值。
    mWeight: ((json['mWeight'] ?? json['mweight']) as num?)?.toDouble(),
    pieces: (json['pieces'] as num?)?.toInt(),
    colorName: json['colorName'] as String?,
    unitName: json['unitName'] as String?,
    colorLegacyId: (json['colorLegacyId'] as num?)?.toInt(),
    sourceE: (json['sourceE'] as num?)?.toDouble(),
    machiningE: (json['machiningE'] as num?)?.toDouble(),
    incidentalE: (json['incidentalE'] as num?)?.toDouble(),
    lacquerE: (json['lacquerE'] as num?)?.toDouble(),
    platingE: (json['platingE'] as num?)?.toDouble(),
    casingE: (json['casingE'] as num?)?.toDouble(),
    polishE: (json['polishE'] as num?)?.toDouble(),
    total: (json['total'] as num?)?.toDouble(),
    workRate: (json['workRate'] as num?)?.toDouble(),
    workE: (json['workE'] as num?)?.toDouble(),
    lostRate: (json['lostRate'] as num?)?.toDouble(),
    lostE: (json['lostE'] as num?)?.toDouble(),
    rentRate: (json['rentRate'] as num?)?.toDouble(),
    rentE: (json['rentE'] as num?)?.toDouble(),
    makeRate: (json['makeRate'] as num?)?.toDouble(),
    makeE: (json['makeE'] as num?)?.toDouble(),
    // 后端 @JsonProperty 已锁定 cTotal/gTotal；兼容小写兜底（同 mWeight quirk）。
    cTotal: ((json['cTotal'] ?? json['ctotal']) as num?)?.toDouble(),
    gTotal: ((json['gTotal'] ?? json['gtotal']) as num?)?.toDouble(),
    sourceType: json['sourceType'] as String?,
  );
}

/// 字段 facet 结果：各筛选字段的可选值桶 + 各字段空值计数。
///
/// fields 以字段 key（与 query 参数名一致：code/series/model/name/spec/material/
/// requireRemark/colorLegacyId/unitLegacyId/sourceType）索引，便于 [MasterDataTableView] 通用查找。
class GoodsFacets {
  const GoodsFacets({required this.fields, required this.nullCounts});

  final Map<String, List<MasterFacetBucket>> fields;
  final Map<String, int> nullCounts;

  static const _keys = [
    'code',
    'series',
    'model',
    'name',
    'spec',
    'material',
    'requireRemark',
    'colorLegacyId',
    'unitLegacyId',
    'sourceType',
  ];

  factory GoodsFacets.fromJson(Map<String, dynamic> json) {
    final fields = <String, List<MasterFacetBucket>>{};
    for (final k in _keys) {
      final list = json[k];
      fields[k] = list is List
          ? list
                .map(
                  (e) => MasterFacetBucket.fromJson(e as Map<String, dynamic>),
                )
                .toList()
          : const [];
    }
    final ncRaw = json['nullCounts'];
    final nullCounts = <String, int>{};
    if (ncRaw is Map) {
      ncRaw.forEach((k, v) {
        nullCounts[k.toString()] = (v is num ? v.toInt() : 0);
      });
    }
    return GoodsFacets(fields: fields, nullCounts: nullCounts);
  }
}
