// 货品主档模型（对应后端 GoodsListItem / GoodsDetail / GoodsFacets）。
//
// 数值字段一律走 (json['x'] as num?)?.toInt()/toDouble()，避免 int/double 被后端
// 序列化成 String（或 null）时直接 cast 崩溃——老库迁移常踩这个坑。
// price 为后端 BigDecimal / PostgreSQL NUMERIC(18,4)，前端仅为表单展示按 double 解析；
// 服务端计算和落库不经过二进制浮点，也不对金额做破坏聚合/约束的字段级随机加密。

import 'master_facet.dart';

/// Where goods.name_en came from (ADR-134): typed by a person, or learned when
/// sales saved a customer file. null = no English name yet.
abstract final class GoodsNameEnSource {
  static const manual = 'MANUAL';
  static const learned = 'LEARNED';
}

/// Longest English name the server accepts (goods.name_en varchar(255)).
const kGoodsNameEnMaxLength = 255;

/// 货品列表项（含筛选/展示所需的核心字段）。
class GoodsListItem {
  const GoodsListItem({
    required this.id,
    this.code,
    this.name,
    this.nameEn,
    this.nameEnSource,
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
    this.mouldCode,
    this.rearInsertCode,
    this.paper,
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
    this.minOrderQty,
    this.orderMultipleQty,
    this.owningWarehouseId,
    this.owningWarehouseName,
    this.owningWorkshopId,
    this.owningWorkshopName,
    this.version,
    this.issueMethod = GoodsIssueMethod.order,
    this.periodicCostBasis,
    this.bulkPackageQty,
    this.recycledMaterial = false,
  });

  /// 乐观锁版本(ADR-111)：行启停、批量启停/删除直接回传比对，不必先拉详情。
  final int? version;

  final String id;
  final String? code;
  final String? name;

  /// English name used to match customer files (goods.name_en, ADR-134);
  /// the goods picker hands it to the sales grid as the default file goods name.
  final String? nameEn;

  /// [GoodsNameEnSource] value, null when [nameEn] is blank.
  final String? nameEnSource;
  final String? spec;
  final String? model;
  final double? price;
  final double? discount; // 折扣倍率 1.0=原价 0.9=9折（复用老库 B_Goods.zk）
  final String? status;
  final int? legacyId;
  final String? series;
  final String? material;
  final String? cNumber;
  final String? requireRemark; // 老库 Require 迁移残值（真实迁移恒空；显示走 paper）
  final String? mouldCode; // 模具编号（moulds.code；UUID 关系优先，历史缺失回落 legacy 快照）
  final String? rearInsertCode; // 后模镶件编号（V457）：生产该货品需使用的后模镶件标识
  final String? paper; // 备注（老库 B_Goods.Paper；列表「备注」列数据源）
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

  // ===== 采购批量口径（V575；软约束，下达采购按此预填默认数量，可人工改） =====
  final double? minOrderQty; // 最小起订量（供应商 MOQ，基本单位）；null=未登记，0=已确认无起订量
  final double? orderMultipleQty; // 订货倍数/整包装量（基本单位，整箱 50 即 50）；null=无倍数要求

  // ===== 所属仓库 (V587；货品主档归属，不是单据落点仓，也不是分析范围仓) =====
  final String? owningWarehouseId; // 这批货平时归哪个仓管；null=未登记归属
  final String? owningWarehouseName; // 展示名；仓库已软删或未解析时为 null

  // ===== 归属生产车间 (V590；最近一次排产确认/改派自动学习回写，只读展示) =====
  final String? owningWorkshopId; // null=尚未学习
  final String? owningWorkshopName; // 展示名；部门已软删或未解析时为 null

  // ===== 车间内料仓 (ADR-131；只读，切换走「发料方式」预览确认) =====
  /// 发料方式：ORDER=按工单领料，PERIODIC=整批领到车间内料仓。
  final String issueMethod;

  /// 分摊方式 (只对整批领料)：OWN=主料 / SHARED=辅料 / EXPENSE=记车间费用。
  final String? periodicCostBasis;

  /// 每袋净重 (基本单位，公斤)；发料、盘点「袋数 × 每袋」的默认值。
  final double? bulkPackageQty;

  /// 回收料 (水口料、破碎料)：其它入库按 0 成本进仓。
  final bool recycledMaterial;

  bool get isPeriodicIssue => issueMethod == GoodsIssueMethod.periodic;

  factory GoodsListItem.fromJson(Map<String, dynamic> json) => GoodsListItem(
    id: json['id'] as String,
    code: json['code'] as String?,
    name: json['name'] as String?,
    nameEn: json['nameEn'] as String?,
    nameEnSource: json['nameEnSource'] as String?,
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
    mouldCode: json['mouldCode'] as String?,
    rearInsertCode: json['rearInsertCode'] as String?,
    paper: json['paper'] as String?,
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
    // 后端 NUMERIC(18,4)，Jackson 可能发 int 或 double；统一走 num? 再 toDouble。
    minOrderQty: (json['minOrderQty'] as num?)?.toDouble(),
    orderMultipleQty: (json['orderMultipleQty'] as num?)?.toDouble(),
    owningWarehouseId: json['owningWarehouseId'] as String?,
    owningWarehouseName: json['owningWarehouseName'] as String?,
    owningWorkshopId: json['owningWorkshopId'] as String?,
    owningWorkshopName: json['owningWorkshopName'] as String?,
    version: (json['version'] as num?)?.toInt(),
    issueMethod: goodsIssueMethodFromJson(json['issueMethod']),
    periodicCostBasis: json['periodicCostBasis'] as String?,
    bulkPackageQty: (json['bulkPackageQty'] as num?)?.toDouble(),
    recycledMaterial: goodsRecycledMaterialFromJson(json),
  );
}

/// 发料方式取值 (ADR-131，与后端 goods.issue_method 一致)。
abstract final class GoodsIssueMethod {
  /// 按工单领料 (默认)。
  static const order = 'ORDER';

  /// 整批领到车间内料仓，盘点计耗。
  static const periodic = 'PERIODIC';
}

/// 分摊方式取值 (ADR-131，与后端 goods.periodic_cost_basis 一致；只对整批领料)。
abstract final class GoodsPeriodicCostBasis {
  /// 主料：按「报工量 × BOM 单个重量」的理论比例分到各工单。
  static const own = 'OWN';

  /// 辅料 (如色母)：不写进 BOM，按当期主料用量分到各产品。
  static const shared = 'SHARED';

  /// 记车间费用：不分给产品。
  static const expense = 'EXPENSE';

  static const values = [own, shared, expense];
}

/// 旧响应没有发料方式时按「按工单领料」处理 (与数据库默认值一致)。
String goodsIssueMethodFromJson(Object? raw) => raw == GoodsIssueMethod.periodic
    ? GoodsIssueMethod.periodic
    : GoodsIssueMethod.order;

/// 回收料标记：Java 的 boolean isRecycledMaterial 经 Jackson 输出为
/// recycledMaterial，record 组件则原名输出；两种写法都认。
bool goodsRecycledMaterialFromJson(Map<String, dynamic> json) =>
    (json['recycledMaterial'] ?? json['isRecycledMaterial']) == true;

/// 产品 BOM 上一条「整批领料的料」的单个重量 (货品详情只读展示)。
class GoodsPeriodicBomWeight {
  const GoodsPeriodicBomWeight({
    required this.materialGoodsId,
    this.bomItemId,
    this.materialName,
    this.materialCode,
    this.colorName,
    this.qty,
    this.unitName,
    this.unitWeightGrams,
  });

  final String materialGoodsId;
  final String? bomItemId;
  final String? materialName;
  final String? materialCode;
  final String? colorName;

  /// 单个重量 (料的基本单位)。
  final double? qty;

  /// 料的基本单位名。
  final String? unitName;

  /// 单个重量 (克)；料的基本单位不能按克换算时为 null，按 [qty] + [unitName] 显示。
  final double? unitWeightGrams;

  factory GoodsPeriodicBomWeight.fromJson(Map<String, dynamic> json) =>
      GoodsPeriodicBomWeight(
        materialGoodsId: json['materialGoodsId'] as String? ?? '',
        bomItemId: json['bomItemId'] as String?,
        materialName: json['materialName'] as String?,
        materialCode: json['materialCode'] as String?,
        colorName: json['colorName'] as String?,
        qty: (json['qty'] as num?)?.toDouble(),
        unitName: json['unitName'] as String?,
        unitWeightGrams: (json['unitWeightGrams'] as num?)?.toDouble(),
      );
}

/// 采购批量数量（最小起订量 / 订货倍数）的展示文本。
///
/// 后端存 NUMERIC(18,4)，但起订量和整箱倍数绝大多数是整数：500 应显示「500」
/// 而不是「500.0」。非整数保留有效小数位，去掉补齐的 0。null → null（显「—」）。
String? goodsQtyText(double? v) {
  if (v == null) return null;
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '');
}

/// 货品详情（列表字段 + 关键业务字段，够看即可）。
class GoodsDetail {
  const GoodsDetail({
    required this.id,
    this.code,
    this.name,
    this.nameEn,
    this.nameEnSource,
    this.canEditNameEn = false,
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
    this.mouldCode,
    this.mouldName,
    this.rearInsertCode,
    this.paper,
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
    this.subcontractAllowedLossPct,
    this.purchaseAllowedOverReceiptPct,
    this.sourceType,
    this.costMasked = false,
    this.discountMasked = false,
    this.priceMasked = false,
    this.stockQty,
    this.stockWeightKg,
    this.stockWeightUnknown = 0,
    this.stockWeightEstimated = false,
    this.stockByWarehouse = const [],
    this.series,
    this.stockPlace,
    this.version,
    this.quantityUnitLocked = false,
    this.writable = false,
    this.minOrderQty,
    this.orderMultipleQty,
    this.owningWarehouseId,
    this.owningWarehouseName,
    this.owningWorkshopId,
    this.owningWorkshopName,
    this.defaultPurchasePrice,
    this.defaultSubcontractPrice,
    this.defaultPurchasePriceInfo,
    this.defaultSubcontractPriceInfo,
    this.issueMethod = GoodsIssueMethod.order,
    this.periodicCostBasis,
    this.bulkPackageQty,
    this.recycledMaterial = false,
    this.periodicBomWeights = const [],
  });

  final String id;

  /// Once quantity/BOM history exists, the database fixes the basic unit.
  final bool quantityUnitLocked;
  final String? code;
  final String? name;

  /// English name used to match customer files (goods.name_en, ADR-134).
  final String? nameEn;

  /// [GoodsNameEnSource] value, null when [nameEn] is blank.
  final String? nameEnSource;

  /// Server capability: the caller may change only the English name through
  /// PUT /master/goods/{id}/name-en (goods:name_en:edit or goods:edit plus
  /// object scope). Missing on older responses means read-only.
  final bool canEditNameEn;

  bool get nameEnLearned =>
      nameEnSource == GoodsNameEnSource.learned &&
      (nameEn?.trim().isNotEmpty ?? false);
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
  final String? mouldCode; // 模具编号（moulds.code；UUID 关系优先，历史缺失回落 legacy 快照）
  final String? mouldName; // 模具名称（同上回落）
  final String? rearInsertCode; // 后模镶件编号（V457）
  final String? paper; // 备注（老库 B_Goods.Paper）
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

  /// 委外允许损耗默认值(%)（ADR-098）：委外订货明细预填记忆；不是成本字段，不随成本脱敏。
  final double? subcontractAllowedLossPct;

  /// 采购允许超收默认值(%)（ADR-144）：采购订货明细预填记忆；空 = 不预填(按 0%)。
  /// 不是价格或成本字段，不随成本脱敏；只经 PUT purchase-receipt-policy 修改。
  final double? purchaseAllowedOverReceiptPct;

  final String? sourceType; // 来源（自制/采购/委外）

  // ===== 成本可见性（goods:cost:view；未授权时后端清空成本字段并置 costMasked=true） =====
  final bool costMasked;

  // ===== 折扣可见性（goods:discount:view；未授权时 discount 置 null 且 discountMasked=true） =====
  final bool discountMasked;

  // ===== 售价可见性（goods:price:view，V570；未授权时 price 置 null 且 priceMasked=true） =====
  final bool priceMasked;

  /// Server object scope; missing capability on older responses is read-only.
  final bool writable;

  // ===== 即时库存（聚合 stock_balances，仅参与核算仓库；详情展示+关联仓库） =====
  final double? stockQty; // 各参与核算仓库余量合计

  /// 已知库存重量合计 (千克, 服务端按参与核算且非线边的仓库算好; 前端不再逐行相加)。
  /// null = 有量的维度重量全都未知; 与 [stockWeightUnknown] 一起显示「≈28.9 kg (另有 2 处未称)」。
  final double? stockWeightKg;

  /// 有库存但重量未知的维度数 (仓库 x 颜色, 不含线边仓)。
  final int stockWeightUnknown;

  /// 重量合计含估算 (显示「≈」)。
  final bool stockWeightEstimated;
  final List<GoodsStockRow> stockByWarehouse; // 按仓库（×颜色）展开

  final String? series; // 物料系列（如塑胶件/五金件）
  final String? stockPlace; // 库位号（仓库摆放位置）
  final int? version; // 乐观锁版本（编辑时原样回传）

  // ===== 采购批量口径（V575；软约束，下达采购按此预填默认数量，采购员可改） =====
  final double? minOrderQty; // 最小起订量（供应商 MOQ，基本单位）；null=未登记，0=已确认无起订量
  final double? orderMultipleQty; // 订货倍数/整包装量（基本单位，整箱 50 即 50）；null=无倍数要求

  // ===== 所属仓库 (V587) =====
  // 货品平时归哪个仓管的主档归属，既不是单据落点仓，也不是物料分析的分析范围仓。
  // 保存时只有带上 owningWarehouseId 这个键才会改动；不带=后端保持原归属。
  final String? owningWarehouseId; // null=未登记归属
  final String? owningWarehouseName; // 展示名；仓库已软删或未解析时为 null

  // ===== 归属生产车间 (V590；只读展示，由排产确认/改派自动学习回写) =====
  final String? owningWorkshopId; // null=尚未学习
  final String? owningWorkshopName; // 展示名；部门已软删或未解析时为 null

  // ===== 采购/委外单价 (V593；由订单保存自动写回，只读展示) =====
  final double? defaultPurchasePrice;
  final double? defaultSubcontractPrice;
  final GoodsLearnedPriceInfo? defaultPurchasePriceInfo;
  final GoodsLearnedPriceInfo? defaultSubcontractPriceInfo;

  // ===== 车间内料仓 (ADR-131) =====
  // 发料方式与分摊方式只读：普通保存不改它们，切换一律走「发料方式」预览确认
  // (GoodsIssueMethodService，先核对没清账的工单与受影响的 BOM 再原子切换)。
  /// 发料方式：ORDER=按工单领料，PERIODIC=整批领到车间内料仓。
  final String issueMethod;

  /// 分摊方式 (只对整批领料)：OWN / SHARED / EXPENSE。
  final String? periodicCostBasis;

  /// 每袋净重 (基本单位，公斤)。
  final double? bulkPackageQty;

  /// 回收料 (水口料、破碎料)。
  final bool recycledMaterial;

  /// 本货品作为产品时，BOM 上「整批领料的料」的单个重量 (只读展示)。
  final List<GoodsPeriodicBomWeight> periodicBomWeights;

  bool get isPeriodicIssue => issueMethod == GoodsIssueMethod.periodic;

  factory GoodsDetail.fromJson(Map<String, dynamic> json) => GoodsDetail(
    id: json['id'] as String,
    code: json['code'] as String?,
    name: json['name'] as String?,
    nameEn: json['nameEn'] as String?,
    nameEnSource: json['nameEnSource'] as String?,
    canEditNameEn: json['canEditNameEn'] == true,
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
    mouldCode: json['mouldCode'] as String?,
    mouldName: json['mouldName'] as String?,
    rearInsertCode: json['rearInsertCode'] as String?,
    paper: json['paper'] as String?,
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
    subcontractAllowedLossPct: (json['subcontractAllowedLossPct'] as num?)
        ?.toDouble(),
    purchaseAllowedOverReceiptPct:
        (json['purchaseAllowedOverReceiptPct'] as num?)?.toDouble(),
    sourceType: json['sourceType'] as String?,
    costMasked: json['costMasked'] as bool? ?? false,
    discountMasked: json['discountMasked'] as bool? ?? false,
    priceMasked: json['priceMasked'] as bool? ?? false,
    writable: json['writable'] == true,
    stockQty: (json['stockQty'] as num?)?.toDouble(),
    stockWeightKg: (json['stockWeightKg'] as num?)?.toDouble(),
    stockWeightUnknown: (json['stockWeightUnknown'] as num?)?.toInt() ?? 0,
    stockWeightEstimated: json['stockWeightEstimated'] == true,
    stockByWarehouse:
        (json['stockByWarehouse'] as List?)
            ?.map((e) => GoodsStockRow.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
    series: json['series'] as String?,
    stockPlace: json['stockPlace'] as String?,
    version: (json['version'] as num?)?.toInt(),
    quantityUnitLocked: json['quantityUnitLocked'] == true,
    // 后端 NUMERIC(18,4)，Jackson 可能发 int 或 double；统一走 num? 再 toDouble。
    minOrderQty: (json['minOrderQty'] as num?)?.toDouble(),
    orderMultipleQty: (json['orderMultipleQty'] as num?)?.toDouble(),
    owningWarehouseId: json['owningWarehouseId'] as String?,
    owningWarehouseName: json['owningWarehouseName'] as String?,
    owningWorkshopId: json['owningWorkshopId'] as String?,
    owningWorkshopName: json['owningWorkshopName'] as String?,
    defaultPurchasePriceInfo:
        json['defaultPurchasePriceInfo'] is Map<String, dynamic>
        ? GoodsLearnedPriceInfo.fromJson(
            json['defaultPurchasePriceInfo'] as Map<String, dynamic>,
          )
        : null,
    defaultSubcontractPriceInfo:
        json['defaultSubcontractPriceInfo'] is Map<String, dynamic>
        ? GoodsLearnedPriceInfo.fromJson(
            json['defaultSubcontractPriceInfo'] as Map<String, dynamic>,
          )
        : null,
    defaultPurchasePrice: (json['defaultPurchasePrice'] as num?)?.toDouble(),
    defaultSubcontractPrice: (json['defaultSubcontractPrice'] as num?)
        ?.toDouble(),
    issueMethod: goodsIssueMethodFromJson(json['issueMethod']),
    periodicCostBasis: json['periodicCostBasis'] as String?,
    bulkPackageQty: (json['bulkPackageQty'] as num?)?.toDouble(),
    recycledMaterial: goodsRecycledMaterialFromJson(json),
    periodicBomWeights:
        (json['periodicBomWeights'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(GoodsPeriodicBomWeight.fromJson)
            .toList() ??
        const [],
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
/// [requestedCategoryId] (an explicitly chosen target) always wins. Paste
/// supplies the currently open category as that target, so the new record and
/// generated code belong there. Ordinary updates keep the persisted category;
/// [currentCategoryId] is their fallback for snapshots missing a category.
String resolveGoodsSaveCategoryId({
  required String currentCategoryId,
  String? sourceCategoryId,
  String? requestedCategoryId,
}) {
  return requestedCategoryId ?? sourceCategoryId ?? currentCategoryId;
}

/// 货品在某仓库（×颜色）的即时库存行（聚合 stock_balances，仅参与核算仓库）。
/// 线边仓行单独列出、不计入合计 ([lineSide])。
class GoodsStockRow {
  const GoodsStockRow({
    this.warehouseId,
    this.warehouseCode,
    this.warehouseName,
    this.colorId,
    this.colorName,
    this.qty,
    this.weight,
    this.weightEstimated = false,
    this.lineSide = false,
  });

  final String? warehouseId;
  final String? warehouseCode;
  final String? warehouseName;
  final String? colorId;
  final String? colorName; // 颜色名（无色货品为 null）
  final double? qty; // 当前余量（基本单位）

  /// 当前库存重量 (千克); null = 未知 (没称过)。
  final double? weight;

  /// 重量含估算 (显示「≈」)。
  final bool weightEstimated;

  /// 线边仓 (车间直送料架) 行: 只列出, 不计入合计。
  final bool lineSide;

  factory GoodsStockRow.fromJson(Map<String, dynamic> json) => GoodsStockRow(
    warehouseId: json['warehouseId'] as String?,
    warehouseCode: json['warehouseCode'] as String?,
    warehouseName: json['warehouseName'] as String?,
    colorId: json['colorId'] as String?,
    colorName: json['colorName'] as String?,
    qty: (json['qty'] as num?)?.toDouble(),
    weight: (json['weight'] as num?)?.toDouble(),
    weightEstimated: json['weightEstimated'] == true,
    lineSide: json['lineSide'] == true,
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
    'paper',
    'rearInsertCode',
    'colorLegacyId',
    'unitLegacyId',
    'sourceType',
    // V587/V590 归属两列：value=UUID（筛选回传），label=仓库名/车间名。
    'owningWarehouse',
    'owningWorkshop',
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

class GoodsLearnedPriceInfo {
  const GoodsLearnedPriceInfo({
    required this.price,
    this.supplierName,
    this.colorName,
    this.unitName,
    this.currencyName,
    this.taxRate,
    this.contextComplete = false,
  });
  factory GoodsLearnedPriceInfo.fromJson(Map<String, dynamic> json) =>
      GoodsLearnedPriceInfo(
        price: (json['price'] as num).toDouble(),
        supplierName: json['supplierName'] as String?,
        colorName: json['colorName'] as String?,
        unitName: json['unitName'] as String?,
        currencyName: json['currencyName'] as String?,
        taxRate: (json['taxRate'] as num?)?.toDouble(),
        contextComplete: json['contextComplete'] == true,
      );
  final double price;
  final String? supplierName, colorName, unitName, currencyName;
  final double? taxRate;
  final bool contextComplete;
}
