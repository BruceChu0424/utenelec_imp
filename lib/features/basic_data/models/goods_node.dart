// 货品主档模型（对应后端 GoodsListItem / GoodsDetail）。
//
// 数值字段一律走 (json['x'] as num?)?.toInt()/toDouble()，避免 int/double 被后端
// 序列化成 String（或 null）时直接 cast 崩溃——老库迁移常踩这个坑。
// price 为后端 BigDecimal（DOUBLE PRECISION 列转 BigDecimal），前端按 double 解析。

/// 货品列表项（轻量摘要）。
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
  });

  final String id;
  final String? code;
  final String? name;
  final String? spec;
  final String? model;
  final double? price;
  final String? status;
  final int? legacyId;

  factory GoodsListItem.fromJson(Map<String, dynamic> json) => GoodsListItem(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        spec: json['spec'] as String?,
        model: json['model'] as String?,
        price: (json['price'] as num?)?.toDouble(),
        status: json['status'] as String?,
        legacyId: (json['legacyId'] as num?)?.toInt(),
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
      );
}
