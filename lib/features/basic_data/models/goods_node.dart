// 货品主档模型（对应后端 GoodsListItem / GoodsDetail / GoodsFacets）。
//
// 数值字段一律走 (json['x'] as num?)?.toInt()/toDouble()，避免 int/double 被后端
// 序列化成 String（或 null）时直接 cast 崩溃——老库迁移常踩这个坑。
// price 为后端 BigDecimal / PostgreSQL NUMERIC(18,4)，前端仅为表单展示按 double 解析；
// 服务端计算和落库不经过二进制浮点，也不对金额做破坏聚合/约束的字段级随机加密。

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
    this.discount,
    this.status,
    this.legacyId,
    this.series,
    this.material,
    this.cNumber,
    this.requireRemark,
    this.colorId,
    this.unitId,
    this.colorLegacyId,
    this.unitLegacyId,
    this.colorName,
    this.unitName,
    this.sourceType,
    this.categoryId,
    this.autoCreated = false,
    this.stockQty,
    this.stockPlace,
  });

  final String id;
  final String? code;
  final String? name;
  final String? spec;
  final String? model;
  final double? price;
  final double? discount; // 折扣倍率 1.0=原价 0.9=9折（复用老库 B_Goods.zk）
  final String? status;
  final int? legacyId;
  final String? series;
  final String? material;
  final String? cNumber;
  final String? requireRemark;
  final String? colorId;
  final String? unitId;
  final int? colorLegacyId;
  final int? unitLegacyId;
  final String? colorName;
  final String? unitName;
  final String? sourceType; // 来源（自制/采购/委外）

  final String? categoryId; // 所属分类 id（货品资料页"搜货品定位分类"用）

  final bool autoCreated; // 迁移兜底占位货品标记（auto_created 列）

  final double? stockQty; // 即时库存合计（聚合 stock_balances，仅参与核算仓库；列表展示用）

  final String? stockPlace; // 库位号（goods.stock_place；选择器拣货/上架指引）

  factory GoodsListItem.fromJson(Map<String, dynamic> json) => GoodsListItem(
    id: json['id'] as String,
    code: json['code'] as String?,
    name: json['name'] as String?,
    spec: json['spec'] as String?,
    model: json['model'] as String?,
    price: (json['price'] as num?)?.toDouble(),
    discount: (json['discount'] as num?)?.toDouble(),
    status: json['status'] as String?,
    legacyId: (json['legacyId'] as num?)?.toInt(),
    series: json['series'] as String?,
    material: json['material'] as String?,
    // 后端 @JsonProperty("cNumber") 输出 cNumber；兼容小写兜底。
    cNumber: (json['cNumber'] ?? json['cnumber']) as String?,
    requireRemark: json['requireRemark'] as String?,
    colorId: json['colorId'] as String?,
    unitId: json['unitId'] as String?,
    colorLegacyId: (json['colorLegacyId'] as num?)?.toInt(),
    unitLegacyId: (json['unitLegacyId'] as num?)?.toInt(),
    colorName: json['colorName'] as String?,
    unitName: json['unitName'] as String?,
    sourceType: json['sourceType'] as String?,
    categoryId: json['categoryId'] as String?,
    autoCreated: json['autoCreated'] as bool? ?? false,
    stockQty: (json['stockQty'] as num?)?.toDouble(),
    stockPlace: json['stockPlace'] as String?,
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
    this.discount,
    this.status,
    this.legacyId,
    this.shortName,
    this.categoryId,
    this.categoryName,
    this.pack,
    this.material,
    this.thickness,
    this.thicknessUnitLegacyId,
    this.thicknessUnitId,
    this.unitId,
    this.unitLegacyId,
    this.mWeight,
    this.mWeightUnitLegacyId,
    this.mWeightUnitId,
    this.pieces,
    this.colorName,
    this.unitName,
    this.colorId,
    this.colorLegacyId,
    this.mouldId,
    this.mouldLegacyId,
    this.clientId,
    this.clientLegacyId,
    this.defaultSupplierId,
    this.vendLegacyId,
    this.secondarySupplierId,
    this.vend2LegacyId,
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
    this.costMasked = false,
    this.discountMasked = false,
    this.stockQty,
    this.stockByWarehouse = const [],
    this.series,
    this.stockPlace,
    this.version,
  });

  final String id;
  final String? code;
  final String? name;
  final String? spec;
  final String? model;
  final double? price;
  final double? discount; // 折扣倍率 1.0=原价 0.9=9折（复用老库 B_Goods.zk）
  final String? status;
  final int? legacyId;
  final String? shortName;
  final String? categoryId;
  final String? categoryName;
  final String? pack;
  final String? material;
  final double? thickness;
  final int? thicknessUnitLegacyId;
  final String? thicknessUnitId;
  final String? unitId;
  final int? unitLegacyId;
  final double? mWeight;
  final int? mWeightUnitLegacyId;
  final String? mWeightUnitId;
  final int? pieces;
  final String? colorName;
  final String? unitName;
  final String? colorId;
  final int? colorLegacyId;
  final String? mouldId;
  final int? mouldLegacyId;
  final String? clientId;
  final int? clientLegacyId;
  final String? defaultSupplierId;
  final int? vendLegacyId;
  final String? secondarySupplierId;
  final int? vend2LegacyId;

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

  final String? sourceType; // 来源（自制/采购/委外）

  // ===== 成本可见性（goods:cost:view；未授权时后端清空成本字段并置 costMasked=true） =====
  final bool costMasked;

  // ===== 折扣可见性（goods:discount:view；未授权时 discount 置 null 且 discountMasked=true） =====
  final bool discountMasked;

  // ===== 即时库存（聚合 stock_balances，仅参与核算仓库；详情展示+关联仓库） =====
  final double? stockQty; // 各参与核算仓库余量合计
  final List<GoodsStockRow> stockByWarehouse; // 按仓库（×颜色）展开

  final String? series; // 物料系列（如塑胶件/五金件）
  final String? stockPlace; // 库位号（仓库摆放位置）
  final int? version; // 乐观锁版本（编辑时原样回传）

  factory GoodsDetail.fromJson(Map<String, dynamic> json) => GoodsDetail(
    id: json['id'] as String,
    code: json['code'] as String?,
    name: json['name'] as String?,
    spec: json['spec'] as String?,
    model: json['model'] as String?,
    price: (json['price'] as num?)?.toDouble(),
    discount: (json['discount'] as num?)?.toDouble(),
    status: json['status'] as String?,
    legacyId: (json['legacyId'] as num?)?.toInt(),
    shortName: json['shortName'] as String?,
    categoryId: json['categoryId'] as String?,
    categoryName: json['categoryName'] as String?,
    pack: json['pack'] as String?,
    material: json['material'] as String?,
    thickness: (json['thickness'] as num?)?.toDouble(),
    thicknessUnitLegacyId: (json['thicknessUnitLegacyId'] as num?)?.toInt(),
    thicknessUnitId: json['thicknessUnitId'] as String?,
    unitId: json['unitId'] as String?,
    unitLegacyId: (json['unitLegacyId'] as num?)?.toInt(),
    // 后端 Jackson 对连续大写字段 mWeight（getter getMWeight）序列化为 "mweight"，
    // 与字段名不符；兼容两种写法，避免"单重"始终取不到值。
    mWeight: ((json['mWeight'] ?? json['mweight']) as num?)?.toDouble(),
    mWeightUnitLegacyId: (json['mWeightUnitLegacyId'] as num?)?.toInt(),
    mWeightUnitId: json['mWeightUnitId'] as String?,
    pieces: (json['pieces'] as num?)?.toInt(),
    colorName: json['colorName'] as String?,
    unitName: json['unitName'] as String?,
    colorId: json['colorId'] as String?,
    colorLegacyId: (json['colorLegacyId'] as num?)?.toInt(),
    mouldId: json['mouldId'] as String?,
    mouldLegacyId: (json['mouldLegacyId'] as num?)?.toInt(),
    clientId: json['clientId'] as String?,
    clientLegacyId: (json['clientLegacyId'] as num?)?.toInt(),
    defaultSupplierId: json['defaultSupplierId'] as String?,
    vendLegacyId: (json['vendLegacyId'] as num?)?.toInt(),
    secondarySupplierId: json['secondarySupplierId'] as String?,
    vend2LegacyId: (json['vend2LegacyId'] as num?)?.toInt(),
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
    costMasked: json['costMasked'] as bool? ?? false,
    discountMasked: json['discountMasked'] as bool? ?? false,
    stockQty: (json['stockQty'] as num?)?.toDouble(),
    stockByWarehouse:
        (json['stockByWarehouse'] as List?)
            ?.map((e) => GoodsStockRow.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
    series: json['series'] as String?,
    stockPlace: json['stockPlace'] as String?,
    version: (json['version'] as num?)?.toInt(),
  );
}

/// 构造货品主档关系的编辑种子字段。
///
/// UUID 是唯一可发送的实时关联键。UUID 缺失时的 legacy 字段只是客户端本地
/// 保留标记，[normalizeGoodsUuidFirstBody] 会在发送前同时移除该标记和空 UUID，
/// 从而保留历史快照而不把 legacy id 解析成新关联。
Map<String, dynamic> goodsUuidFirstReferenceBody(GoodsDetail detail) {
  final body = <String, dynamic>{};

  void put(String uuidKey, String? uuid, String legacyKey, int? legacyId) {
    final normalizedUuid = uuid?.trim();
    if (normalizedUuid != null && normalizedUuid.isNotEmpty) {
      body[uuidKey] = normalizedUuid;
    } else {
      body[legacyKey] = legacyId;
    }
  }

  put('colorId', detail.colorId, 'colorLegacyId', detail.colorLegacyId);
  put('unitId', detail.unitId, 'unitLegacyId', detail.unitLegacyId);
  put(
    'thicknessUnitId',
    detail.thicknessUnitId,
    'thicknessUnitLegacyId',
    detail.thicknessUnitLegacyId,
  );
  put(
    'mWeightUnitId',
    detail.mWeightUnitId,
    'mWeightUnitLegacyId',
    detail.mWeightUnitLegacyId,
  );
  put('mouldId', detail.mouldId, 'mouldLegacyId', detail.mouldLegacyId);
  put('clientId', detail.clientId, 'clientLegacyId', detail.clientLegacyId);
  put(
    'defaultSupplierId',
    detail.defaultSupplierId,
    'vendLegacyId',
    detail.vendLegacyId,
  );
  put(
    'secondarySupplierId',
    detail.secondarySupplierId,
    'vend2LegacyId',
    detail.vend2LegacyId,
  );
  return body;
}

/// 清理表单合并后的关系字段。
///
/// 表单的可编辑 UUID 字段会覆盖 [goodsUuidFirstReferenceBody] 带入的历史标记：
/// - 选择了 UUID：移除同关系的 legacy 字段；
/// - UUID 为空且存在 legacy 标记：两个字段都不发送，保留历史关系；
/// - UUID 为空且没有标记：保留显式 null，表示用户清空关系。
Map<String, dynamic> normalizeGoodsUuidFirstBody(Map<String, dynamic> source) {
  final body = Map<String, dynamic>.from(source);

  void normalize(String uuidKey, String legacyKey) {
    if (!body.containsKey(uuidKey)) {
      body.remove(legacyKey);
      return;
    }
    final rawUuid = body[uuidKey];
    final uuid = rawUuid is String ? rawUuid.trim() : null;
    if (uuid != null && uuid.isNotEmpty) {
      body[uuidKey] = uuid;
      body.remove(legacyKey);
      return;
    }
    if (body.containsKey(legacyKey)) {
      body.remove(uuidKey);
      body.remove(legacyKey);
    }
  }

  normalize('colorId', 'colorLegacyId');
  normalize('unitId', 'unitLegacyId');
  normalize('thicknessUnitId', 'thicknessUnitLegacyId');
  normalize('mWeightUnitId', 'mWeightUnitLegacyId');
  normalize('mouldId', 'mouldLegacyId');
  normalize('clientId', 'clientLegacyId');
  normalize('defaultSupplierId', 'vendLegacyId');
  normalize('secondarySupplierId', 'vend2LegacyId');
  return body;
}

/// Resolves the category UUID used by a goods save request.
///
/// A copied goods record is a new identity under the category currently open in
/// the UI, so its source category must never win.  This is what makes a paste
/// into a `V6` category use that category's `V6xxxxxx` allocator.  Ordinary
/// updates keep the persisted category unless the caller explicitly changes it.
String resolveGoodsSaveCategoryId({
  required String currentCategoryId,
  String? sourceCategoryId,
  String? requestedCategoryId,
  bool copyMode = false,
}) {
  if (copyMode) return requestedCategoryId ?? currentCategoryId;
  return requestedCategoryId ?? sourceCategoryId ?? currentCategoryId;
}

/// 货品在某仓库（×颜色）的即时库存行（聚合 stock_balances，仅参与核算仓库）。
class GoodsStockRow {
  const GoodsStockRow({
    this.warehouseId,
    this.warehouseCode,
    this.warehouseName,
    this.colorName,
    this.qty,
    this.weight,
  });

  final String? warehouseId;
  final String? warehouseCode;
  final String? warehouseName;
  final String? colorName; // 颜色名（无色货品为 null）
  final double? qty; // 当前余量（基本单位）
  final double? weight; // 当前库存重量

  factory GoodsStockRow.fromJson(Map<String, dynamic> json) => GoodsStockRow(
    warehouseId: json['warehouseId'] as String?,
    warehouseCode: json['warehouseCode'] as String?,
    warehouseName: json['warehouseName'] as String?,
    colorName: json['colorName'] as String?,
    qty: (json['qty'] as num?)?.toDouble(),
    weight: (json['weight'] as num?)?.toDouble(),
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
