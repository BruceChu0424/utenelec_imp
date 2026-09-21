const Set<String> warehouseSalesOutboundForbiddenKeys = {
  'financeAudit',
  'currencyId',
  'currencyCode',
  'exchangeRate',
  'taxRate',
  'settlementMethodId',
  'price',
  'unitPrice',
  'amount',
  'amountOriginal',
  'amountLocal',
  'totalOriginal',
  'totalLocal',
  'arPosted',
};

/// V582 起仓库只有两个有效态：财务放行后的「待出库」和确认出库后的「已出库」。
/// 历史单据仍可能带着已退役的 PICKING/PICKED/EXCEPTION 字符串，label 用兜底分支
/// 原样显示，不把未知值伪装成已知状态。
abstract final class WarehouseSalesOutboundStatus {
  static const pendingPick = 'PENDING_PICK';
  static const shipped = 'SHIPPED';

  static String label(String? value) => switch (value?.trim().toUpperCase()) {
    pendingPick => '待出库',
    shipped => '已出库',
    _ => value?.trim().isNotEmpty == true ? value!.trim() : '状态未知',
  };

  static String nextStep(String? value) =>
      switch (value?.trim().toUpperCase()) {
        pendingPick => '核对货品、数量与库位后确认出库',
        shipped => '已完成出库',
        _ => '请刷新后按服务端允许动作处理',
      };
}

/// 仓库作业状态分组计数(GET /warehouse/sales-outbound/counts, 键 = warehouse_work_status,
/// 与列表同一读范围): 出库任务中心「销售出库」父分类红徽章与小类行计数的唯一来源.
class WarehouseSalesOutboundCounts {
  const WarehouseSalesOutboundCounts({
    this.pendingPick = 0,
    this.legacyPending = 0,
    this.shipped = 0,
  });

  factory WarehouseSalesOutboundCounts.fromJson(Map<String, dynamic> json) {
    return WarehouseSalesOutboundCounts(
      pendingPick: _count(json, WarehouseSalesOutboundStatus.pendingPick),
      legacyPending: _count(json, 'LEGACY_PENDING'),
      shipped: _count(json, WarehouseSalesOutboundStatus.shipped),
    );
  }

  /// 待出库(等仓库确认出库)张数 = 红徽章(hub 卡 / 父分类 / 小类同数).
  final int pendingPick;

  /// 历史迁移异常(V443 起只读, 仓库无动作)张数: 不进红徽章, 只能从表头「仓库作业」筛选进入.
  final int legacyPending;

  /// 已出库张数 = 小类行中性括号数(已完结, 供掂量, 不进任何累加).
  final int shipped;

  /// 后端固定给五个状态键; 缺键按 0(键集是服务端契约, 不在此猜), 非数字直接抛给 provider 记错.
  static int _count(Map<String, dynamic> json, String key) =>
      (json[key] as num?)?.toInt() ?? 0;
}

enum WarehouseSalesOutboundAction {
  confirmShipment(WarehouseSalesOutboundStatus.shipped, '确认出库');

  const WarehouseSalesOutboundAction(this.targetStatus, this.label);

  final String targetStatus;
  final String label;
}

class WarehouseSalesOutboundSummary {
  const WarehouseSalesOutboundSummary({
    required this.id,
    required this.allowedWarehouseTargets,
    this.billNo,
    this.billDate,
    this.clientId,
    this.clientName,
    this.warehouseId,
    this.warehouseName,
    this.warehouseWorkStatus,
  });

  final String id;
  final String? billNo;
  final String? billDate;
  final String? clientId;
  final String? clientName;
  final String? warehouseId;
  final String? warehouseName;
  final String? warehouseWorkStatus;
  final Set<String> allowedWarehouseTargets;

  String get statusLabel =>
      WarehouseSalesOutboundStatus.label(warehouseWorkStatus);

  bool allows(WarehouseSalesOutboundAction action) =>
      allowedWarehouseTargets.contains(action.targetStatus);

  factory WarehouseSalesOutboundSummary.fromJson(Map<String, dynamic> json) {
    return WarehouseSalesOutboundSummary(
      id: _requiredId(json['id']),
      billNo: _text(json['billNo']),
      billDate: _text(json['billDate']),
      clientId: _text(json['clientId']),
      clientName: _text(json['clientName']),
      warehouseId: _text(json['warehouseId']),
      warehouseName: _text(json['warehouseName']),
      warehouseWorkStatus: _text(json['warehouseWorkStatus']),
      allowedWarehouseTargets: _stringSet(json['allowedWarehouseTargets']),
    );
  }
}

class WarehouseSalesOutboundDetail {
  const WarehouseSalesOutboundDetail({
    required this.header,
    required this.lines,
    this.shipAddress,
    this.contactPhone,
    this.logisticsNo,
    this.parcelCount,
    this.warehouseWorkUpdatedAt,
    this.handedOverAt,
  });

  final WarehouseSalesOutboundSummary header;
  final String? shipAddress;
  final String? contactPhone;
  final String? logisticsNo;
  final int? parcelCount;
  final String? warehouseWorkUpdatedAt;
  final String? handedOverAt;

  /// V631 起发出仓按行落定(见 [WarehouseSalesOutboundLine.warehouseChoices])，
  /// 表头 [WarehouseSalesOutboundSummary.warehouseId] 只是默认/主发出仓。
  final List<WarehouseSalesOutboundLine> lines;

  factory WarehouseSalesOutboundDetail.fromJson(Map<String, dynamic> json) {
    return WarehouseSalesOutboundDetail(
      header: WarehouseSalesOutboundSummary.fromJson(json),
      shipAddress: _text(json['shipAddress']),
      contactPhone: _text(json['contactPhone']),
      logisticsNo: _text(json['logisticsNo']),
      parcelCount: _integer(json['parcelCount']),
      warehouseWorkUpdatedAt: _text(json['warehouseWorkUpdatedAt']),
      handedOverAt: _text(json['handedOverAt']),
      lines: _objectList(
        json['lines'],
      ).map(WarehouseSalesOutboundLine.fromJson).toList(growable: false),
    );
  }
}

class WarehouseSalesOutboundLine {
  const WarehouseSalesOutboundLine({
    required this.id,
    this.lineNumber,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.currentStockPlaceHint,
    this.actualStockPlace,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.quantity,
    this.weight,
    this.parcelQuantity,
    this.cartonCount,
    this.clientProductCode,
    this.clientModel,
    this.sourceDocumentNo,
    this.warehouseId,
    this.warehouseName,
    this.suggestedWarehouseId,
    this.warehouseChoices = const [],
  });

  final String id;
  final int? lineNumber;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? currentStockPlaceHint;
  final String? actualStockPlace;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final String? quantity;
  final String? weight;
  final String? parcelQuantity;
  final int? cartonCount;
  final String? clientProductCode;
  final String? clientModel;
  final String? sourceDocumentNo;

  /// 已落定的实际发出仓(已出库行 / 已确认的行)；待确认行为空。
  final String? warehouseId;
  final String? warehouseName;

  /// 服务端预填的建议发出仓：表头仓能发出本行就是表头仓，否则首个能发出本行的仓。
  final String? suggestedWarehouseId;

  /// 本行可选的发出仓及各自可发量(V631)；只在待确认出库时给出。
  final List<WarehouseSalesWarehouseChoice> warehouseChoices;

  WarehouseSalesWarehouseChoice? choice(String? warehouseId) {
    if (warehouseId == null) return null;
    for (final choice in warehouseChoices) {
      if (choice.warehouseId == warehouseId) return choice;
    }
    return null;
  }

  factory WarehouseSalesOutboundLine.fromJson(Map<String, dynamic> json) {
    return WarehouseSalesOutboundLine(
      id: _requiredId(json['id']),
      lineNumber: _integer(json['lineNumber']),
      goodsId: _text(json['goodsId']),
      goodsCode: _text(json['goodsCode']),
      goodsName: _text(json['goodsName']),
      currentStockPlaceHint: _text(json['currentStockPlaceHint']),
      actualStockPlace: _text(json['actualStockPlace']),
      colorId: _text(json['colorId']),
      colorName: _text(json['colorName']),
      unitId: _text(json['unitId']),
      unitName: _text(json['unitName']),
      quantity: _decimalText(json['quantity']),
      weight: _decimalText(json['weight']),
      parcelQuantity: _decimalText(json['parcelQuantity']),
      cartonCount: _integer(json['cartonCount']),
      clientProductCode: _text(json['clientProductCode']),
      clientModel: _text(json['clientModel']),
      sourceDocumentNo: _text(json['sourceDocumentNo']),
      warehouseId: _text(json['warehouseId']),
      warehouseName: _text(json['warehouseName']),
      suggestedWarehouseId: _text(json['suggestedWarehouseId']),
      warehouseChoices: _objectList(
        json['warehouseChoices'],
      ).map(WarehouseSalesWarehouseChoice.fromJson).toList(growable: false),
    );
  }
}

/// 某一出库行可选的发出仓(V631)：可发量已扣安全库存、其它硬预留与来源承诺，
/// 同仓同货多行按行序递减；不足时下拉项禁选并点明差额。
class WarehouseSalesWarehouseChoice {
  const WarehouseSalesWarehouseChoice({
    required this.warehouseId,
    required this.warehouseName,
    required this.canFulfill,
    this.availableQty,
    this.requiredQty,
  });

  final String warehouseId;
  final String warehouseName;
  final bool canFulfill;
  final String? availableQty;
  final String? requiredQty;

  /// 下拉项文案：仓名 · 可发 N；不足时补「不足(需 M)」。
  String get label =>
      '$warehouseName · 可发 ${availableQty ?? '0'}'
      '${canFulfill ? '' : ' · 不足(需 ${requiredQty ?? '0'})'}';

  factory WarehouseSalesWarehouseChoice.fromJson(Map<String, dynamic> json) =>
      WarehouseSalesWarehouseChoice(
        warehouseId: _requiredId(json['warehouseId']),
        warehouseName: _text(json['warehouseName']) ?? '—',
        canFulfill: json['canFulfill'] == true,
        availableQty: _decimalText(json['availableQty']),
        requiredQty: _decimalText(json['requiredQty']),
      );
}

String _requiredId(Object? value) {
  final id = _text(value);
  if (id == null) throw const FormatException('销售出库任务缺少 id');
  return id;
}

String? _text(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

String? _decimalText(Object? value) => _text(value);

int? _integer(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

Set<String> _stringSet(Object? value) {
  if (value is! List) return const {};
  return {for (final item in value) ?_text(item)};
}

List<Map<String, dynamic>> _objectList(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map<Object?, Object?>>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}
