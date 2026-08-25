// 委外单据模型（8 单据统一超集，对应后端 *ListItem/*Detail/*ItemDto）。
//
// 8 单据差异由 doc_type 决定可选字段是否非空（订货有 purchaser+currency；进仓有 sender+
// apPosted；退货有 lastDate+apPosted；发料/材料退/损耗有 worker+仓库必填且无单价；损耗
// 明细含 ending/standard/waste_rate/cause）。一个超集模型 ×8 配置，避免 8 套重复。
// UUID=String；金额/数量=(json as num?)；日期=ISO 字符串直存（后端 LocalDate）；status=Short→int。

import '../../../shared/models/procurement_finance_approval.dart';

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

  static SubcontractDocType? tryByPath(String seg) {
    for (final type in SubcontractDocType.values) {
      if (type.pathSegment == seg) return type;
    }
    return null;
  }

  static SubcontractDocType byPath(String seg) =>
      tryByPath(seg) ?? (throw ArgumentError.value(seg, 'seg', '未知委外单据路由段'));
}

/// 单据状态：0草稿 / 1已审 / -1红冲（后端 Short）。
const int kSubcontractStatusDraft = 0;
const int kSubcontractStatusApproved = 1;
const int kSubcontractStatusReversed = -1;

class SubcontractDocListItem {
  const SubcontractDocListItem({
    required this.id,
    this.billNo,
    this.billDate,
    this.supplierId,
    this.warehouseId,
    this.settlementMethodId,
    this.totalLocal,
    this.priceMasked = false,
    this.totalWeight,
    this.status,
    this.closed = false,
    this.apPosted = false,
    this.fulfill = false,
    this.legacyId,
    this.financeApproval,
  });

  final String id;
  final String? billNo;
  final String? billDate;
  final String? supplierId;
  final String? warehouseId;
  final String? settlementMethodId;
  final double? totalLocal;

  /// 价格已对当前用户脱敏（金额族为 null；渲染 ***，V302 收货单价格脱敏）。
  final bool priceMasked;
  final double? totalWeight;
  final int? status;
  final bool closed;
  final bool apPosted;
  final bool fulfill;
  final int? legacyId;
  final ProcurementFinanceApproval? financeApproval;

  factory SubcontractDocListItem.fromJson(Map<String, dynamic> json) =>
      SubcontractDocListItem(
        id: json['id'] as String,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        supplierId: json['supplierId'] as String?,
        warehouseId: json['warehouseId'] as String?,
        settlementMethodId: json['settlementMethodId'] as String?,
        totalLocal: (json['totalLocal'] as num?)?.toDouble(),
        priceMasked: (json['priceMasked'] as bool?) ?? false,
        totalWeight: (json['totalWeight'] as num?)?.toDouble(),
        status: (json['status'] as num?)?.toInt(),
        closed: (json['closed'] as bool?) ?? false,
        apPosted: (json['apPosted'] as bool?) ?? false,
        fulfill: (json['fulfill'] as bool?) ?? false,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        financeApproval: json['financeApproval'] is Map
            ? ProcurementFinanceApproval.fromJson(
                (json['financeApproval'] as Map).cast<String, dynamic>(),
              )
            : null,
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
    this.legacyIssuedQty,
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
    this.orderId,
    this.orderBillNo,
    this.receiptItemId,
    this.materialIssueItemId,
    this.planItemId,
    this.sourceDocNo,
    this.atSupplierQty,
    this.consumedQty,
    this.frozenUnitQty,
    this.supplierEnding,
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

  /// 历史订货明细累计发料量。
  ///
  /// 仅兼容旧接口字段 `issuedQty` 的只读展示，不能作为当前“剩余可发量”、
  /// 新发料审核或库存扣减的权威依据；新业务不再回写该累计字段。
  final double? legacyIssuedQty;
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

  /// 来源订货单 id（进仓明细级，点击跳订货详情用）；无订货关联为 null。
  final String? orderId;

  /// 来源订货单编号（进仓明细级展示：编号而非 id）；无订货关联为 null。
  final String? orderBillNo;
  final String? receiptItemId;
  final String? materialIssueItemId;

  /// 来源发料计划行（V304；仓库拣货保存时随草稿行回传）。
  final String? planItemId;
  final String? sourceDocNo;

  /// 供应商处子账（发料明细）：已发至供应商 / 回厂已消费 / 冻结 BOM 单耗 / 期末结存
  final double? atSupplierQty;
  final double? consumedQty;
  final double? frozenUnitQty;
  final double? supplierEnding;
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
        legacyIssuedQty: (json['issuedQty'] as num?)?.toDouble(),
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
        orderId: json['orderId'] as String?,
        orderBillNo: json['orderBillNo'] as String?,
        receiptItemId: json['receiptItemId'] as String?,
        materialIssueItemId: json['materialIssueItemId'] as String?,
        planItemId: json['planItemId'] as String?,
        sourceDocNo: json['sourceDocNo'] as String?,
        atSupplierQty: (json['atSupplierQty'] as num?)?.toDouble(),
        consumedQty: (json['consumedQty'] as num?)?.toDouble(),
        frozenUnitQty: (json['frozenUnitQty'] as num?)?.toDouble(),
        supplierEnding: (json['supplierEnding'] as num?)?.toDouble(),
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
    this.settlementMethodId,
    this.remark,
    this.totalOriginal,
    this.totalLocal,
    this.priceMasked = false,
    this.status,
    this.closed = false,
    this.apPosted = false,
    this.fulfill = false,
    this.sourceDocNo,
    this.items = const [],
    this.productionLinked = false,
    this.canEdit = false,
    this.canDelete = false,
    this.canReverse = false,
    this.restrictionReason,
    this.financeApproval,
    this.sourceApplicationId,
    this.sourceApplicationNo,
    this.sourceOrderId,
    this.sourceOrderNo,
    this.deductAmount,
    this.deductPosted,
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
  final String? settlementMethodId;
  final String? remark;
  final double? totalOriginal;
  final double? totalLocal;

  /// 价格已对当前用户脱敏（金额族/明细价格族为 null；渲染 ***，V302 收货单价格脱敏）。
  final bool priceMasked;
  final int? status;
  final bool closed;
  final bool apPosted;
  final bool fulfill;
  final String? sourceDocNo;
  final List<SubcontractDocItem> items;
  final bool productionLinked;
  final bool canEdit;
  final bool canDelete;
  final bool canReverse;
  final String? restrictionReason;
  final ProcurementFinanceApproval? financeApproval;

  /// 来源委外申请（订货单全部明细同源时给出，供跳转；跨申请为 null）
  final String? sourceApplicationId;
  final String? sourceApplicationNo;

  /// 来源委外订货单（进仓单全部明细同源时给出，供跳转；跨订单为 null）
  final String? sourceOrderId;
  final String? sourceOrderNo;

  /// 损耗建议索赔金额（本币，仅建议，不自动冲应付）/ 历史扣款标记。
  final double? deductAmount;
  final bool? deductPosted;

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
        settlementMethodId: json['settlementMethodId'] as String?,
        remark: json['remark'] as String?,
        totalOriginal: (json['totalOriginal'] as num?)?.toDouble(),
        totalLocal: (json['totalLocal'] as num?)?.toDouble(),
        priceMasked: (json['priceMasked'] as bool?) ?? false,
        status: (json['status'] as num?)?.toInt(),
        closed: (json['closed'] as bool?) ?? false,
        apPosted: (json['apPosted'] as bool?) ?? false,
        fulfill: (json['fulfill'] as bool?) ?? false,
        sourceDocNo: json['sourceDocNo'] as String?,
        productionLinked: (json['productionLinked'] as bool?) ?? false,
        canEdit: (json['canEdit'] as bool?) ?? false,
        canDelete: (json['canDelete'] as bool?) ?? false,
        canReverse: (json['canReverse'] as bool?) ?? false,
        restrictionReason: json['restrictionReason'] as String?,
        sourceApplicationId: json['sourceApplicationId'] as String?,
        sourceApplicationNo: json['sourceApplicationNo'] as String?,
        sourceOrderId: json['sourceOrderId'] as String?,
        sourceOrderNo: json['sourceOrderNo'] as String?,
        deductAmount: (json['deductAmount'] as num?)?.toDouble(),
        deductPosted: json['deductPosted'] as bool?,
        financeApproval: json['financeApproval'] is Map
            ? ProcurementFinanceApproval.fromJson(
                (json['financeApproval'] as Map).cast<String, dynamic>(),
              )
            : null,
        items:
            (json['items'] as List?)
                ?.map(
                  (e) => SubcontractDocItem.fromJson(e as Map<String, dynamic>),
                )
                .toList() ??
            const [],
      );
}

/// 计划下达申请在委外任务中心的权威可拆分行。
class SubcontractDecompositionLine {
  const SubcontractDecompositionLine({
    required this.sourceDocumentId,
    required this.sourceDocumentNo,
    required this.sourceItemId,
    required this.goodsId,
    required this.requestedQty,
    required this.orderedQty,
    required this.pendingQty,
    required this.remainingQty,
    this.colorId,
    this.unitId,
    this.unitRate,
    this.needDate,
    this.warehouseId,
    this.sourcePlanNo,
  });

  final String sourceDocumentId;
  final String sourceDocumentNo;
  final String sourceItemId;
  final String goodsId;
  final String? colorId;
  final String? unitId;
  final double? unitRate;
  final double requestedQty;
  final double orderedQty;
  final double pendingQty;
  final double remainingQty;
  final String? needDate;
  final String? warehouseId;
  final String? sourcePlanNo;

  factory SubcontractDecompositionLine.fromJson(Map<String, dynamic> json) {
    double number(String key) {
      final value = json[key];
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    return SubcontractDecompositionLine(
      sourceDocumentId: json['sourceDocumentId'] as String,
      sourceDocumentNo: json['sourceDocumentNo'] as String? ?? '',
      sourceItemId: json['sourceItemId'] as String,
      goodsId: json['goodsId'] as String,
      colorId: json['colorId'] as String?,
      unitId: json['unitId'] as String?,
      unitRate: json['unitRate'] == null ? null : number('unitRate'),
      requestedQty: number('requestedQty'),
      orderedQty: number('orderedQty'),
      pendingQty: number('pendingQty'),
      remainingQty: number('remainingQty'),
      needDate: json['needDate'] as String?,
      warehouseId: json['warehouseId'] as String?,
      sourcePlanNo: json['sourcePlanNo'] as String?,
    );
  }
}
