// 委外订货单全链路进度模型（V304）。
// 对应 GET /api/subcontract/orders/{id}/progress。

class SubcontractMaterialPlanLine {
  const SubcontractMaterialPlanLine({
    required this.planItemId,
    required this.parentGoodsCode,
    required this.parentGoodsName,
    required this.goodsCode,
    required this.goodsName,
    required this.colorName,
    required this.unitName,
    required this.bomUnitQty,
    required this.plannedQty,
    required this.issuedQty,
    required this.draftQty,
    this.flowMode = 'LEGACY_BOM_COMPONENT',
    this.preparationStatus = 'LEGACY_READY',
    this.preparedQty = 0,
    this.readyOutboundQty = 0,
    this.remainingQtySnapshot,
    this.preparationAnalysisId,
    this.preparationAnalysisItemId,
    this.blocker,
    this.allowedActions = const {},
  });

  final String planItemId;
  final String? parentGoodsCode;
  final String? parentGoodsName;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitName;
  final double bomUnitQty;
  final double plannedQty;
  final double issuedQty;
  final double draftQty;
  final String flowMode;
  final String preparationStatus;
  final double preparedQty;
  final double readyOutboundQty;
  final double? remainingQtySnapshot;
  final String? preparationAnalysisId;
  final String? preparationAnalysisItemId;
  final String? blocker;
  final Set<String> allowedActions;

  bool get isLegacyBomComponent => flowMode == 'LEGACY_BOM_COMPONENT';

  double get remainingQty {
    if (remainingQtySnapshot case final value?) return value < 0 ? 0 : value;
    final r = plannedQty - issuedQty - draftQty;
    return r < 0 ? 0 : r;
  }

  factory SubcontractMaterialPlanLine.fromJson(Map<String, dynamic> json) =>
      SubcontractMaterialPlanLine(
        planItemId: json['planItemId'] as String,
        parentGoodsCode: json['parentGoodsCode'] as String?,
        parentGoodsName: json['parentGoodsName'] as String?,
        goodsCode: json['goodsCode'] as String?,
        goodsName: json['goodsName'] as String?,
        colorName: json['colorName'] as String?,
        unitName: json['unitName'] as String?,
        bomUnitQty: (json['bomUnitQty'] as num?)?.toDouble() ?? 0,
        plannedQty: (json['plannedQty'] as num?)?.toDouble() ?? 0,
        issuedQty: (json['issuedQty'] as num?)?.toDouble() ?? 0,
        draftQty:
            (json['draftReservedQty'] as num?)?.toDouble() ??
            (json['draftQty'] as num?)?.toDouble() ??
            0,
        flowMode:
            json['flowMode']?.toString().trim().toUpperCase() ??
            'LEGACY_BOM_COMPONENT',
        preparationStatus:
            json['preparationStatus']?.toString().trim().toUpperCase() ??
            'LEGACY_READY',
        preparedQty: (json['preparedQty'] as num?)?.toDouble() ?? 0,
        readyOutboundQty:
            (json['readyOutboundQty'] as num?)?.toDouble() ??
            (json['remainingQty'] as num?)?.toDouble() ??
            0,
        remainingQtySnapshot: (json['remainingQty'] as num?)?.toDouble(),
        preparationAnalysisId: json['preparationAnalysisId'] as String?,
        preparationAnalysisItemId: json['preparationAnalysisItemId'] as String?,
        blocker: json['blocker'] as String?,
        allowedActions: {
          for (final action in (json['allowedActions'] as List? ?? const []))
            if (action != null) action.toString(),
        },
      );
}

/// 链路单据进度（出仓单/进仓单/退货单/损耗单共用）。
class SubcontractProgressDoc {
  const SubcontractProgressDoc({
    required this.id,
    required this.billNo,
    required this.status,
    required this.billDate,
    this.warehouseName,
    this.approverName,
    this.totalQty,
    this.totalLocal,
    this.iqcStatus,
    this.warehouseStockInStatus,
    this.iqcPassedBaseQty,
    this.warehouseStockedBaseQty,
    this.pendingStockInBaseQty,
    this.deductAmount,
    this.deductPosted,
  });

  final String id;
  final String? billNo;
  final int? status; // 0 草稿 / 1 已审 / -1 红冲
  final String? billDate;
  final String? warehouseName;
  final String? approverName;
  final double? totalQty;
  final double? totalLocal;

  /// IQC 聚合状态（仅进仓单）：PENDING / PARTIAL / RESOLVED。
  final String? iqcStatus;

  /// V446 仓库实际入库状态。只有服务端明确返回 STOCKED 才表示已进入库存；
  /// null/未知值必须失败关闭，不能从 IQC RESOLVED 或当前库存反推。
  final String? warehouseStockInStatus;
  final double? iqcPassedBaseQty;
  final double? warehouseStockedBaseQty;
  final double? pendingStockInBaseQty;

  bool get qualityResolved => iqcStatus?.trim().toUpperCase() == 'RESOLVED';

  /// Missing/unknown server projection is deliberately not treated as stocked.
  bool get warehouseStocked =>
      warehouseStockInStatus?.trim().toUpperCase() == 'STOCKED';

  /// 损耗建议索赔金额（仅损耗单；不自动扣款或冲应付）。
  final double? deductAmount;

  /// 历史扣款兼容标记；新流程不据此表达已冲应付。
  final bool? deductPosted;

  factory SubcontractProgressDoc.fromJson(Map<String, dynamic> json) =>
      SubcontractProgressDoc(
        id: json['id'] as String,
        billNo: json['billNo'] as String?,
        status: (json['status'] as num?)?.toInt(),
        billDate: json['billDate'] as String?,
        warehouseName: json['warehouseName'] as String?,
        approverName: json['approverName'] as String?,
        totalQty: (json['totalQty'] as num?)?.toDouble(),
        totalLocal: (json['totalLocal'] as num?)?.toDouble(),
        iqcStatus: json['iqcStatus'] as String?,
        warehouseStockInStatus: json['warehouseStockInStatus'] as String?,
        iqcPassedBaseQty: (json['iqcPassedBaseQty'] as num?)?.toDouble(),
        warehouseStockedBaseQty: (json['warehouseStockedBaseQty'] as num?)
            ?.toDouble(),
        pendingStockInBaseQty: (json['pendingStockInBaseQty'] as num?)
            ?.toDouble(),
        deductAmount: (json['deductAmount'] as num?)?.toDouble(),
        deductPosted: json['deductPosted'] as bool?,
      );
}

/// 供应商处材料台账行（V221 守恒口径）。
class SubcontractSupplierLedgerLine {
  const SubcontractSupplierLedgerLine({
    required this.goodsCode,
    required this.goodsName,
    required this.colorName,
    required this.unitName,
    required this.atSupplierQty,
    required this.consumedQty,
    required this.returnedQty,
    required this.wastedQty,
    required this.supplierEnding,
  });

  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitName;
  final double atSupplierQty;
  final double consumedQty;
  final double returnedQty;
  final double wastedQty;
  final double supplierEnding;

  factory SubcontractSupplierLedgerLine.fromJson(Map<String, dynamic> json) =>
      SubcontractSupplierLedgerLine(
        goodsCode: json['goodsCode'] as String?,
        goodsName: json['goodsName'] as String?,
        colorName: json['colorName'] as String?,
        unitName: json['unitName'] as String?,
        atSupplierQty: (json['atSupplierQty'] as num?)?.toDouble() ?? 0,
        consumedQty: (json['consumedQty'] as num?)?.toDouble() ?? 0,
        returnedQty: (json['returnedQty'] as num?)?.toDouble() ?? 0,
        wastedQty: (json['wastedQty'] as num?)?.toDouble() ?? 0,
        supplierEnding: (json['supplierEnding'] as num?)?.toDouble() ?? 0,
      );
}

class SubcontractOrderProgress {
  const SubcontractOrderProgress({
    required this.orderId,
    required this.billNo,
    required this.status,
    required this.financeCaseStatus,
    required this.financeDecidedAt,
    required this.materialRequired,
    required this.planStatus,
    required this.planCloseReason,
    required this.materialLines,
    required this.issues,
    required this.receipts,
    required this.returns,
    required this.wastes,
    required this.supplierLedger,
    required this.apPostedTotal,
    required this.wasteDeductTotal,
    this.priceMasked = false,
  });

  final String orderId;
  final String? billNo;
  final int? status;
  final String? financeCaseStatus; // PENDING / APPROVED / REJECTED
  final String? financeDecidedAt;
  final bool materialRequired;
  final String? planStatus; // OPEN / CLOSED / CANCELED
  final String? planCloseReason;
  final List<SubcontractMaterialPlanLine> materialLines;
  final List<SubcontractProgressDoc> issues;
  final List<SubcontractProgressDoc> receipts;
  final List<SubcontractProgressDoc> returns;
  final List<SubcontractProgressDoc> wastes;
  final List<SubcontractSupplierLedgerLine> supplierLedger;
  final double apPostedTotal;

  /// 后端历史字段名；前端按“建议索赔合计（不计入应付）”展示。
  final double wasteDeductTotal;
  final bool priceMasked;

  factory SubcontractOrderProgress.fromJson(Map<String, dynamic> json) =>
      SubcontractOrderProgress(
        orderId: json['orderId'] as String,
        billNo: json['billNo'] as String?,
        status: (json['status'] as num?)?.toInt(),
        financeCaseStatus: json['financeCaseStatus'] as String?,
        financeDecidedAt: json['financeDecidedAt'] as String?,
        materialRequired: json['materialRequired'] as bool? ?? false,
        planStatus: json['planStatus'] as String?,
        planCloseReason: json['planCloseReason'] as String?,
        materialLines: [
          for (final e in (json['materialLines'] as List? ?? const []))
            SubcontractMaterialPlanLine.fromJson(
              (e as Map).cast<String, dynamic>(),
            ),
        ],
        issues: [
          for (final e in (json['issues'] as List? ?? const []))
            SubcontractProgressDoc.fromJson((e as Map).cast<String, dynamic>()),
        ],
        receipts: [
          for (final e in (json['receipts'] as List? ?? const []))
            SubcontractProgressDoc.fromJson((e as Map).cast<String, dynamic>()),
        ],
        returns: [
          for (final e in (json['returns'] as List? ?? const []))
            SubcontractProgressDoc.fromJson((e as Map).cast<String, dynamic>()),
        ],
        wastes: [
          for (final e in (json['wastes'] as List? ?? const []))
            SubcontractProgressDoc.fromJson((e as Map).cast<String, dynamic>()),
        ],
        supplierLedger: [
          for (final e in (json['supplierLedger'] as List? ?? const []))
            SubcontractSupplierLedgerLine.fromJson(
              (e as Map).cast<String, dynamic>(),
            ),
        ],
        apPostedTotal: (json['apPostedTotal'] as num?)?.toDouble() ?? 0,
        wasteDeductTotal: (json['wasteDeductTotal'] as num?)?.toDouble() ?? 0,
        priceMasked: json['priceMasked'] == true,
      );
}
