// ADR-156 委外申请明细的物料齐套情况(GET /subcontract/applications/items/{id}/kit)。
//
// 委外价格每天不同，直属物料够做至少一套才解锁生成委外订货单；这里给任务中心
// 「齐套情况」弹窗用：剩余未下单、够做的套数、这次可下单与逐种直属物料的库存事实。
// 所有数量都由服务端在一处算好(fn_subcontract_application_kit_qty)，客户端只显示。

/// 一种直属物料的齐套事实(数量单位 = 该物料自己的单位)。
class SubcontractKitMaterial {
  const SubcontractKitMaterial({
    required this.goodsId,
    required this.goodsCode,
    required this.goodsName,
    required this.colorName,
    required this.unitName,
    required this.bomUnitQty,
    required this.neededQty,
    required this.exactQty,
    required this.exactClaimedQty,
    required this.exactFreeQty,
    required this.publicQty,
    required this.publicClaimedQty,
    required this.publicFreeQty,
    required this.freeQty,
    required this.shortQty,
    required this.kitQty,
    this.colorId,
  });

  final String goodsId;
  final String goodsCode;
  final String goodsName;
  final String? colorId;
  final String colorName;
  final String unitName;

  /// 每套用量。
  final double bomUnitQty;

  /// 剩余未下单数量需要的物料。
  final double neededQty;

  /// 本申请专属库存(物料分析分给它的)。
  final double exactQty;

  /// 专属库存里已被本申请已有委外单占用的。
  final double exactClaimedQty;
  final double exactFreeQty;

  /// 公共可用库存。
  final double publicQty;

  /// 公共库存里已被别的委外单占用的。
  final double publicClaimedQty;
  final double publicFreeQty;

  /// 现在能用 = 专属未占用 + 公共未占用。
  final double freeQty;

  /// 还缺 = 需要 - 现在能用(不小于 0)。
  final double shortQty;

  /// 这种物料够做几套。
  final double kitQty;

  /// 已被占用(专属 + 公共)，弹窗合成一列显示。
  double get claimedQty => exactClaimedQty + publicClaimedQty;

  factory SubcontractKitMaterial.fromJson(Map<String, dynamic> json) =>
      SubcontractKitMaterial(
        goodsId: _string(json, 'goodsId') ?? '',
        goodsCode: _string(json, 'goodsCode') ?? '',
        goodsName: _string(json, 'goodsName') ?? '',
        colorId: _string(json, 'colorId'),
        colorName: _string(json, 'colorName') ?? '',
        unitName: _string(json, 'unitName') ?? '',
        bomUnitQty: _double(json, 'bomUnitQty'),
        neededQty: _double(json, 'neededQty'),
        exactQty: _double(json, 'exactQty'),
        exactClaimedQty: _double(json, 'exactClaimedQty'),
        exactFreeQty: _double(json, 'exactFreeQty'),
        publicQty: _double(json, 'publicQty'),
        publicClaimedQty: _double(json, 'publicClaimedQty'),
        publicFreeQty: _double(json, 'publicFreeQty'),
        freeQty: _double(json, 'freeQty'),
        shortQty: _double(json, 'shortQty'),
        kitQty: _double(json, 'kitQty'),
      );
}

/// 一条委外申请明细的齐套情况(数量单位 = 委外件的申请单位)。
class SubcontractApplicationKit {
  const SubcontractApplicationKit({
    required this.applicationItemId,
    required this.applicationId,
    required this.applicationNo,
    required this.goodsId,
    required this.goodsCode,
    required this.goodsName,
    required this.colorName,
    required this.unitName,
    required this.openQty,
    required this.kitQty,
    required this.orderableQty,
    required this.bomMissing,
    required this.materials,
  });

  final String applicationItemId;
  final String applicationId;
  final String applicationNo;
  final String goodsId;
  final String goodsCode;
  final String goodsName;
  final String colorName;
  final String unitName;

  /// 剩余未下单。
  final double openQty;

  /// 现有物料够做的套数。
  final double kitQty;

  /// 这次可下单 = MIN(剩余未下单, 够做的套数)；0 = 等物料齐套。
  final double orderableQty;

  /// 委外件缺 BOM(没有物料行，另由「通知研发完善」处理)。
  final bool bomMissing;
  final List<SubcontractKitMaterial> materials;

  factory SubcontractApplicationKit.fromJson(Map<String, dynamic> json) =>
      SubcontractApplicationKit(
        applicationItemId: _string(json, 'applicationItemId') ?? '',
        applicationId: _string(json, 'applicationId') ?? '',
        applicationNo: _string(json, 'applicationNo') ?? '',
        goodsId: _string(json, 'goodsId') ?? '',
        goodsCode: _string(json, 'goodsCode') ?? '',
        goodsName: _string(json, 'goodsName') ?? '',
        colorName: _string(json, 'colorName') ?? '',
        unitName: _string(json, 'unitName') ?? '',
        openQty: _double(json, 'openQty'),
        kitQty: _double(json, 'kitQty'),
        orderableQty: _double(json, 'orderableQty'),
        bomMissing: json['bomMissing'] == true,
        materials: [
          for (final row in (json['materials'] as List? ?? const []))
            SubcontractKitMaterial.fromJson(
              (row as Map).cast<String, dynamic>(),
            ),
        ],
      );
}

String? _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

double _double(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim()) ?? 0;
  return 0;
}
