import 'production_material_analysis.dart';

class MaterialFutureTransferSource
    implements MaterialReallocationEndpointCandidate {
  const MaterialFutureTransferSource({
    required this.sourceAllocationId,
    required this.sourceAnalysisId,
    required this.sourceMaterialId,
    required this.sourceLabel,
    required this.availableQty,
    required this.receivedQty,
    required this.sourceVersion,
    required this.sourceFingerprint,
    required this.targetVersion,
    required this.targetFingerprint,
    required this.targetUncoveredQty,
    this.expectedDate,
    this.targetNeedDate,
    this.lateOrUnknown = false,
    this.stage,
    this.route,
    this.warehouseId,
    this.warehouseName,
    this.goodsCode,
    this.goodsName,
    this.documentNo,
    this.documentId,
    this.documentRoute,
  });
  final String sourceAllocationId;
  final String sourceAnalysisId;
  final String sourceMaterialId;
  final String sourceLabel;
  final double availableQty;
  final double receivedQty;
  final int sourceVersion;
  final String sourceFingerprint;
  final int targetVersion;
  final String targetFingerprint;
  final double targetUncoveredQty;
  final String? expectedDate;
  final String? targetNeedDate;
  final bool lateOrUnknown;
  final String? stage;
  final MaterialSupplyRoute? route;
  final String? warehouseId;
  @override
  final String? warehouseName;
  final String? goodsCode;
  final String? goodsName;

  /// 来源外部单据（采购单/委外单）的单号与 ID，用于展示与跳转；可能为空。
  final String? documentNo;
  final String? documentId;
  final String? documentRoute;
  @override
  String get analysisId => sourceAnalysisId;
  @override
  String get materialLineId => sourceMaterialId;
  @override
  int get version => sourceVersion;
  @override
  String get fingerprint => sourceFingerprint;
  @override
  String get displayAnalysisLabel => sourceLabel;
  @override
  String? get productLabel => goodsName;
  @override
  String? get pathLabel => null;
  @override
  String? get deliveryDate => expectedDate;
  @override
  double get shortageQty => targetUncoveredQty;
  @override
  double get sourceLendableQty => availableQty;
  String get stageLabel => stage == 'PARTIAL_STOCK_IN'
      ? '部分已入库；当前可调的是尚未实收部分'
      : '已下单，尚未合格入库；到货与检验进度以原单为准';
  factory MaterialFutureTransferSource.fromJson(Map<String, dynamic> json) =>
      MaterialFutureTransferSource(
        sourceAllocationId: json['sourceAllocationId'] as String,
        sourceAnalysisId: json['sourceAnalysisId'] as String,
        sourceMaterialId: json['sourceMaterialId'] as String,
        sourceLabel: json['sourceLabel'] as String? ?? '供料计划',
        availableQty: (json['availableQty'] as num?)?.toDouble() ?? 0,
        receivedQty: (json['receivedQty'] as num?)?.toDouble() ?? 0,
        sourceVersion: (json['sourceVersion'] as num).toInt(),
        sourceFingerprint: json['sourceFingerprint'] as String,
        targetVersion: (json['targetVersion'] as num).toInt(),
        targetFingerprint: json['targetFingerprint'] as String,
        targetUncoveredQty:
            (json['targetUncoveredQty'] as num?)?.toDouble() ?? 0,
        expectedDate: json['expectedDate'] as String?,
        targetNeedDate: json['targetNeedDate'] as String?,
        lateOrUnknown: json['lateOrUnknown'] == true,
        stage: json['stage'] as String?,
        route: MaterialSupplyRoute.fromWire(json['route']),
        warehouseId: json['warehouseId'] as String?,
        warehouseName: json['warehouseName'] as String?,
        goodsCode: json['goodsCode'] as String?,
        goodsName: json['goodsName'] as String?,
        documentNo: json['documentNo'] as String?,
        documentId: json['documentId'] as String?,
        documentRoute: json['documentRoute'] as String?,
      );
}

class MaterialFutureTransferRecord {
  const MaterialFutureTransferRecord({
    required this.id,
    required this.sourceAllocationId,
    required this.sourceAnalysisId,
    required this.sourceMaterialId,
    required this.targetAnalysisId,
    required this.targetMaterialId,
    required this.qty,
    required this.cancelledQty,
    required this.receivedQty,
    required this.remainingQty,
    required this.status,
    required this.sourceVersion,
    required this.sourceFingerprint,
    required this.targetVersion,
    required this.targetFingerprint,
    required this.direction,
    this.sourceLabel,
    this.targetLabel,
    this.expectedDate,
    this.route,
    this.canCancel = false,
    this.cancelableQty,
    this.cancelRestoreToSourceQty,
    this.cancelPublicReleaseQty = 0,
    this.sourceSupplyShortfallQty = 0,
    this.supplyWarning,
    this.blockedReason,
    this.reason,
    this.createdByName,
    this.createdAt,
  });
  final String id;
  final String sourceAllocationId;
  final String sourceAnalysisId;
  final String sourceMaterialId;
  final String targetAnalysisId;
  final String targetMaterialId;
  final String? sourceLabel;
  final String? targetLabel;
  final String? expectedDate;
  final String? route;
  final String direction;
  final double qty;
  final double cancelledQty;
  final double receivedQty;
  final double remainingQty;
  final String status;
  final int sourceVersion;
  final String sourceFingerprint;
  final int targetVersion;
  final String targetFingerprint;
  final bool canCancel;
  final double? cancelableQty;
  double get maxCancelableQty => cancelableQty ?? remainingQty;
  final double? cancelRestoreToSourceQty;
  final double cancelPublicReleaseQty;
  final double sourceSupplyShortfallQty;
  final String? supplyWarning;
  double get maxRestoreToSourceQty =>
      cancelRestoreToSourceQty ??
      (remainingQty - cancelPublicReleaseQty).clamp(0, remainingQty);
  final String? blockedReason;
  final String? reason;

  /// 经办人与办理时间；用于记录展示，不影响业务判断。
  final String? createdByName;
  final String? createdAt;
  bool get outbound => direction == 'OUT';
  String get statusLabel => switch (status) {
    'WAITING_RECEIPT' => '尚未实收',
    'PARTIAL' => '部分已实收',
    'RECEIVED' => '已全部实收',
    'CANCELLED' => '未实收份额已撤销',
    _ => '进度待核对',
  };
  factory MaterialFutureTransferRecord.fromJson(Map<String, dynamic> json) =>
      MaterialFutureTransferRecord(
        id: json['id'] as String,
        sourceAllocationId: json['sourceAllocationId'] as String,
        sourceAnalysisId: json['sourceAnalysisId'] as String,
        sourceMaterialId: json['sourceMaterialId'] as String,
        targetAnalysisId: json['targetAnalysisId'] as String,
        targetMaterialId: json['targetMaterialId'] as String,
        sourceLabel: json['sourceLabel'] as String?,
        targetLabel: json['targetLabel'] as String?,
        qty: (json['qty'] as num).toDouble(),
        cancelledQty: (json['cancelledQty'] as num?)?.toDouble() ?? 0,
        receivedQty: (json['receivedQty'] as num?)?.toDouble() ?? 0,
        remainingQty: (json['remainingQty'] as num?)?.toDouble() ?? 0,
        status: json['status'] as String,
        sourceVersion: (json['sourceVersion'] as num).toInt(),
        sourceFingerprint: json['sourceFingerprint'] as String,
        targetVersion: (json['targetVersion'] as num).toInt(),
        targetFingerprint: json['targetFingerprint'] as String,
        direction: json['direction'] as String? ?? 'IN',
        expectedDate: json['expectedDate'] as String?,
        route: json['route'] as String?,
        canCancel: json['canCancel'] == true,
        cancelableQty: (json['cancelableQty'] as num?)?.toDouble(),
        cancelRestoreToSourceQty: (json['cancelRestoreToSourceQty'] as num?)
            ?.toDouble(),
        cancelPublicReleaseQty:
            (json['cancelPublicReleaseQty'] as num?)?.toDouble() ?? 0,
        sourceSupplyShortfallQty:
            (json['sourceSupplyShortfallQty'] as num?)?.toDouble() ?? 0,
        supplyWarning: json['supplyWarning'] as String?,
        blockedReason: json['blockedReason'] as String?,
        reason: json['reason'] as String?,
        createdByName: json['createdByName'] as String?,
        createdAt: json['createdAt'] as String?,
      );
}
