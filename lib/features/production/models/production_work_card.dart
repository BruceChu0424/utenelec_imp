/// Read-only A4 work-card projection for one confirmed execution package.
///
/// Names are resolved from current master data by the server when this view is
/// requested. The package, segment, demand and quantity identities remain the
/// persisted source of truth; printing never writes business state.
class ProductionWorkCardView {
  const ProductionWorkCardView({
    required this.planId,
    required this.packageId,
    required this.packageStatus,
    required this.executionModelVersion,
    required this.packageLockVersion,
    required this.warehouseId,
    required this.generatedAt,
    required this.namePolicy,
    this.planBillNo,
    this.planBillDate,
    this.deliveryDate,
    this.confirmedAt,
    this.approverName,
    this.warehouseCode,
    this.warehouseName,
    this.cards = const [],
  });

  final String planId;
  final String? planBillNo;
  final String? planBillDate;
  final String? deliveryDate;
  final String packageId;
  final String packageStatus;
  final int executionModelVersion;
  final int packageLockVersion;
  final String? confirmedAt;
  final String? approverName;
  final String warehouseId;
  final String? warehouseCode;
  final String? warehouseName;
  final String generatedAt;
  final String namePolicy;
  final List<ProductionWorkCard> cards;

  bool get isPrintable =>
      packageStatus == 'CONFIRMED' &&
      executionModelVersion == 1 &&
      cards.isNotEmpty;

  factory ProductionWorkCardView.fromJson(Map<String, dynamic> json) {
    return ProductionWorkCardView(
      planId: json['planId'] as String,
      planBillNo: json['planBillNo'] as String?,
      planBillDate: json['planBillDate'] as String?,
      deliveryDate: json['deliveryDate'] as String?,
      packageId: json['packageId'] as String,
      packageStatus: json['packageStatus'] as String,
      executionModelVersion:
          (json['executionModelVersion'] as num?)?.toInt() ?? 0,
      packageLockVersion: (json['packageLockVersion'] as num?)?.toInt() ?? 0,
      confirmedAt: json['confirmedAt'] as String?,
      approverName: json['approverName'] as String?,
      warehouseId: json['warehouseId'] as String,
      warehouseCode: json['warehouseCode'] as String?,
      warehouseName: json['warehouseName'] as String?,
      generatedAt: json['generatedAt'] as String,
      namePolicy: json['namePolicy'] as String? ?? 'CURRENT_MASTER_DATA',
      cards: [
        for (final raw in json['cards'] as List? ?? const [])
          ProductionWorkCard.fromJson(Map<String, dynamic>.from(raw as Map)),
      ],
    );
  }
}

class ProductionWorkCard {
  const ProductionWorkCard({
    required this.segmentId,
    required this.segmentCode,
    required this.sourcePlanItemId,
    required this.productGoodsId,
    required this.plannedQty,
    required this.status,
    this.autoPromoteWhenReady = true,
    this.materialRequirementMode = 'DEMANDED',
    this.zeroMaterialReason,
    this.sourceLineNo,
    this.productNo,
    this.productCode,
    this.productName,
    this.productSpec,
    this.productModel,
    this.productColorName,
    this.productUnitName,
    this.workshopName,
    this.teamName,
    this.responsibleEmployeeName,
    this.planBeginDate,
    this.planEndDate,
    this.salesOrderNo,
    this.requestNote,
    this.remark,
    this.drawBillNos,
    this.materials = const [],
  });

  final String segmentId;
  final String segmentCode;
  final String sourcePlanItemId;
  final int? sourceLineNo;
  final String? productNo;
  final String productGoodsId;
  final String? productCode;
  final String? productName;
  final String? productSpec;
  final String? productModel;
  final String? productColorName;
  final String? productUnitName;
  final double plannedQty;
  final String status;
  final bool autoPromoteWhenReady;
  final String materialRequirementMode;
  final String? zeroMaterialReason;
  final String? workshopName;
  final String? teamName;
  final String? responsibleEmployeeName;
  final String? planBeginDate;
  final String? planEndDate;
  final String? salesOrderNo;
  final String? requestNote;
  final String? remark;
  final String? drawBillNos;
  final List<ProductionWorkCardMaterial> materials;

  factory ProductionWorkCard.fromJson(Map<String, dynamic> json) {
    return ProductionWorkCard(
      segmentId: json['segmentId'] as String,
      segmentCode: json['segmentCode'] as String,
      sourcePlanItemId: json['sourcePlanItemId'] as String,
      sourceLineNo: (json['sourceLineNo'] as num?)?.toInt(),
      productNo: json['productNo'] as String?,
      productGoodsId: json['productGoodsId'] as String,
      productCode: json['productCode'] as String?,
      productName: json['productName'] as String?,
      productSpec: json['productSpec'] as String?,
      productModel: json['productModel'] as String?,
      productColorName: json['productColorName'] as String?,
      productUnitName: json['productUnitName'] as String?,
      plannedQty: (json['plannedQty'] as num).toDouble(),
      status: json['status'] as String,
      autoPromoteWhenReady: json['autoPromoteWhenReady'] != false,
      materialRequirementMode:
          json['materialRequirementMode'] as String? ?? 'DEMANDED',
      zeroMaterialReason: json['zeroMaterialReason'] as String?,
      workshopName: json['workshopName'] as String?,
      teamName: json['teamName'] as String?,
      responsibleEmployeeName: json['responsibleEmployeeName'] as String?,
      planBeginDate: json['planBeginDate'] as String?,
      planEndDate: json['planEndDate'] as String?,
      salesOrderNo: json['salesOrderNo'] as String?,
      requestNote: json['requestNote'] as String?,
      remark: json['remark'] as String?,
      drawBillNos: json['drawBillNos'] as String?,
      materials: [
        for (final raw in json['materials'] as List? ?? const [])
          ProductionWorkCardMaterial.fromJson(
            Map<String, dynamic>.from(raw as Map),
          ),
      ],
    );
  }
}

class ProductionWorkCardMaterial {
  const ProductionWorkCardMaterial({
    required this.demandId,
    required this.goodsId,
    required this.perProductQty,
    required this.requiredQty,
    required this.stockAllocatedQty,
    required this.shortageQty,
    required this.supplyRoute,
    required this.demandStatus,
    this.requirementMode = 'LINEAR',
    this.goodsCode,
    this.goodsName,
    this.spec,
    this.colorName,
    this.unitName,
  });

  final String demandId;
  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? spec;
  final String? colorName;
  final String? unitName;
  final double perProductQty;
  final double requiredQty;
  final double stockAllocatedQty;
  final double shortageQty;
  final String supplyRoute;
  final String demandStatus;
  final String requirementMode;

  factory ProductionWorkCardMaterial.fromJson(Map<String, dynamic> json) {
    return ProductionWorkCardMaterial(
      demandId: json['demandId'] as String,
      goodsId: json['goodsId'] as String,
      goodsCode: json['goodsCode'] as String?,
      goodsName: json['goodsName'] as String?,
      spec: json['spec'] as String?,
      colorName: json['colorName'] as String?,
      unitName: json['unitName'] as String?,
      perProductQty: (json['perProductQty'] as num).toDouble(),
      requiredQty: (json['requiredQty'] as num).toDouble(),
      stockAllocatedQty: (json['stockAllocatedQty'] as num).toDouble(),
      shortageQty: (json['shortageQty'] as num).toDouble(),
      supplyRoute: json['supplyRoute'] as String,
      demandStatus: json['demandStatus'] as String,
      requirementMode: json['requirementMode'] as String? ?? 'LINEAR',
    );
  }
}
