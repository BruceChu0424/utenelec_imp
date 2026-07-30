// 委外单据模型（8 单据统一超集，对应后端 *ListItem/*Detail/*ItemDto）。
//
// 8 单据差异由 doc_type 决定可选字段是否非空（订货有 purchaser+currency；进仓有 sender+
// apPosted；退货有 lastDate+apPosted；发料/材料退/损耗有 worker+仓库必填且无单价；损耗
// 明细含 ending/standard/waste_rate/cause）。一个超集模型 ×8 配置，避免 8 套重复。
// UUID=String；金额/数量=(json as num?)；日期=ISO 字符串直存（后端 LocalDate）；status=Short→int。

/// 委外单据类型。pathSegment 对齐后端 /api/subcontract/{inquiries|applications|orders|
/// receipts|returns|material-issues|material-returns|wastes}。
enum SubcontractDocType {
  inquiry('inquiries'),
  application('applications'),
  order('orders'),
  receipt('receipts'),
  materialIssue('material-issues'),
  returnDoc('returns'),
  materialReturn('material-returns'),
  waste('wastes');

  const SubcontractDocType(this.pathSegment);
  final String pathSegment;

  static SubcontractDocType byPath(String seg) =>
      SubcontractDocType.values.firstWhere(
        (e) => e.pathSegment == seg,
        orElse: () => SubcontractDocType.receipt,
      );
}

/// 单据状态：0草稿 / 1已审 / -1红冲（后端 Short）。
const int kSubcontractStatusDraft = 0;
const int kSubcontractStatusApproved = 1;
const int kSubcontractStatusReversed = -1;

/// 报表 monthly 端点 docType 参数取值（与后端 SubcontractReportService 对齐）。
const Set<String> kSubcontractReportDocTypes = {
  'INQUIRY',
  'APPLICATION',
  'ORDER',
  'RECEIPT',
  'RETURN',
  'MATERIAL_ISSUE',
  'MATERIAL_RETURN',
  'WASTE',
};

class SubcontractDocListItem {
  const SubcontractDocListItem({
    required this.id,
    this.billNo,
    this.billDate,
    this.supplierId,
    this.warehouseId,
    this.totalLocal,
    this.totalWeight,
    this.status,
    this.closed = false,
    this.apPosted = false,
    this.fulfill = false,
    this.legacyId,
  });

  final String id;
  final String? billNo;
  final String? billDate;
  final String? supplierId;
  final String? warehouseId;
  final double? totalLocal;
  final double? totalWeight;
  final int? status;
  final bool closed;
  final bool apPosted;
  final bool fulfill;
  final int? legacyId;

  factory SubcontractDocListItem.fromJson(Map<String, dynamic> json) =>
      SubcontractDocListItem(
        id: json['id'] as String,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        supplierId: json['supplierId'] as String?,
        warehouseId: json['warehouseId'] as String?,
        totalLocal: (json['totalLocal'] as num?)?.toDouble(),
        totalWeight: (json['totalWeight'] as num?)?.toDouble(),
        status: (json['status'] as num?)?.toInt(),
        closed: (json['closed'] as bool?) ?? false,
        apPosted: (json['apPosted'] as bool?) ?? false,
        fulfill: (json['fulfill'] as bool?) ?? false,
        legacyId: (json['legacyId'] as num?)?.toInt(),
      );
}

class SubcontractDocItem {
  const SubcontractDocItem({
    required this.id,
    this.lineNo,
    this.goodsId,
    this.colorId,
    this.unitId,
    this.unitRate,
    this.qty,
    this.price,
    this.amountOriginal,
    this.amountLocal,
    this.checkQty,
    this.orderQty,
    this.receivedQty,
    this.returnedQty,
    this.wastedQty,
    this.endingQty,
    this.standardQty,
    this.wasteRate,
    this.cause,
    this.weight,
    this.girthQty,
    this.boxQty,
    this.parentGoodsId,
    this.parentColorId,
    // 链路 *ItemId
    this.applicationItemId,
    this.orderItemId,
    this.receiptItemId,
    this.materialIssueItemId,
    this.sourceDocNo,
    this.remark,
  });

  final String? id;
  final int? lineNo;
  final String? goodsId;
  final String? colorId;
  final String? unitId;
  final double? unitRate;
  final double? qty;
  final double? price;
  final double? amountOriginal;
  final double? amountLocal;
  final double? checkQty;
  final double? orderQty;
  final double? receivedQty;
  final double? returnedQty;
  final double? wastedQty;
  // 损耗特有
  final double? endingQty;
  final double? standardQty;
  final double? wasteRate;
  final String? cause;
  final double? weight;
  // 围数（进仓/退货/材料退）/ 胶箱数量（材料出）
  final double? girthQty;
  final double? boxQty;
  // BOM 父件（发料/材料退）
  final String? parentGoodsId;
  final String? parentColorId;
  // 链路
  final String? applicationItemId;
  final String? orderItemId;
  final String? receiptItemId;
  final String? materialIssueItemId;
  final String? sourceDocNo;
  final String? remark;

  factory SubcontractDocItem.fromJson(Map<String, dynamic> json) =>
      SubcontractDocItem(
        id: json['id'] as String?,
        lineNo: (json['lineNo'] as num?)?.toInt(),
        goodsId: json['goodsId'] as String?,
        colorId: json['colorId'] as String?,
        unitId: json['unitId'] as String?,
        unitRate: (json['unitRate'] as num?)?.toDouble(),
        qty: (json['qty'] as num?)?.toDouble(),
        price: (json['price'] as num?)?.toDouble(),
        amountOriginal: (json['amountOriginal'] as num?)?.toDouble(),
        amountLocal: (json['amountLocal'] as num?)?.toDouble(),
        checkQty: (json['checkQty'] as num?)?.toDouble(),
        orderQty: (json['orderQty'] as num?)?.toDouble(),
        receivedQty: (json['receivedQty'] as num?)?.toDouble(),
        returnedQty: (json['returnedQty'] as num?)?.toDouble(),
        wastedQty: (json['wastedQty'] as num?)?.toDouble(),
        endingQty: (json['endingQty'] as num?)?.toDouble(),
        standardQty: (json['standardQty'] as num?)?.toDouble(),
        wasteRate: (json['wasteRate'] as num?)?.toDouble(),
        cause: json['cause'] as String?,
        weight: (json['weight'] as num?)?.toDouble(),
        girthQty: (json['girthQty'] as num?)?.toDouble(),
        boxQty: (json['boxQty'] as num?)?.toDouble(),
        parentGoodsId: json['parentGoodsId'] as String?,
        parentColorId: json['parentColorId'] as String?,
        applicationItemId: json['applicationItemId'] as String?,
        orderItemId: json['orderItemId'] as String?,
        receiptItemId: json['receiptItemId'] as String?,
        materialIssueItemId: json['materialIssueItemId'] as String?,
        sourceDocNo: json['sourceDocNo'] as String?,
        remark: json['remark'] as String?,
      );
}

class SubcontractDocDetail {
  const SubcontractDocDetail({
    required this.id,
    this.legacyId,
    this.billNo,
    this.billDate,
    this.supplierId,
    this.warehouseId,
    this.currencyId,
    this.exchangeRate,
    this.taxRate,
    this.purchaserId,
    this.senderId,
    this.workerId,
    this.makerId,
    this.approverId,
    this.makerName,
    this.createdAt,
    this.deliverDate,
    this.lastDate,
    this.bStyle,
    this.totalWeight,
    this.settlementStyleLegacy,
    this.remark,
    this.totalOriginal,
    this.totalLocal,
    this.status,
    this.closed = false,
    this.apPosted = false,
    this.fulfill = false,
    this.sourceDocNo,
    this.items = const [],
  });

  final String id;
  final int? legacyId;
  final String? billNo;
  final String? billDate;
  final String? supplierId;
  final String? warehouseId;
  final String? currencyId;
  final double? exchangeRate;
  final double? taxRate;
  final String? purchaserId;
  final String? senderId;
  final String? workerId;
  final String? makerId;
  final String? approverId;

  /// 制单员姓名（服务端解析；只读展示，不可修改）
  final String? makerName;

  /// 制单时间 ISO（审计 created_at，创建后不可变）
  final String? createdAt;
  final String? deliverDate;
  final String? lastDate;
  final int? bStyle;
  final double? totalWeight;
  final int? settlementStyleLegacy; // 结帐方式（进仓/退货；B_PStyle 字典码）
  final String? remark;
  final double? totalOriginal;
  final double? totalLocal;
  final int? status;
  final bool closed;
  final bool apPosted;
  final bool fulfill;
  final String? sourceDocNo;
  final List<SubcontractDocItem> items;

  factory SubcontractDocDetail.fromJson(Map<String, dynamic> json) =>
      SubcontractDocDetail(
        id: json['id'] as String,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        supplierId: json['supplierId'] as String?,
        warehouseId: json['warehouseId'] as String?,
        currencyId: json['currencyId'] as String?,
        exchangeRate: (json['exchangeRate'] as num?)?.toDouble(),
        taxRate: (json['taxRate'] as num?)?.toDouble(),
        purchaserId: json['purchaserId'] as String?,
        senderId: json['senderId'] as String?,
        workerId: json['workerId'] as String?,
        makerId: json['makerId'] as String?,
        makerName: json['makerName'] as String?,
        createdAt: json['createdAt'] as String?,
        approverId: json['approverId'] as String?,
        deliverDate: json['deliverDate'] as String?,
        lastDate: json['lastDate'] as String?,
        bStyle: (json['bStyle'] as num?)?.toInt(),
        totalWeight: (json['totalWeight'] as num?)?.toDouble(),
        settlementStyleLegacy: (json['settlementStyleLegacy'] as num?)?.toInt(),
        remark: json['remark'] as String?,
        totalOriginal: (json['totalOriginal'] as num?)?.toDouble(),
        totalLocal: (json['totalLocal'] as num?)?.toDouble(),
        status: (json['status'] as num?)?.toInt(),
        closed: (json['closed'] as bool?) ?? false,
        apPosted: (json['apPosted'] as bool?) ?? false,
        fulfill: (json['fulfill'] as bool?) ?? false,
        sourceDocNo: json['sourceDocNo'] as String?,
        items:
            (json['items'] as List?)
                ?.map(
                  (e) => SubcontractDocItem.fromJson(e as Map<String, dynamic>),
                )
                .toList() ??
            const [],
      );
}
