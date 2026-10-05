import '../../warehouse/models/warehouse_pre_stocked_location.dart';

class ProductionFqcInspection {
  const ProductionFqcInspection({
    required this.id,
    required this.sourceReportId,
    required this.sourceReportItemId,
    required this.reportedQty,
    required this.passedQty,
    required this.failedQty,
    required this.remainingQty,
    required this.authorizedInboundQty,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.reportNo,
    this.sourcePlanItemId,
    this.planId,
    this.planNo,
    this.executionSegmentId,
    this.executionSegmentSalesAllocationId,
    this.warehouseId,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.unitRate = 1,
    this.reportMakerId,
    this.sheetId,
    this.sheetNo,
    this.warehouseName,
    this.place,
    this.registrationRemark,
    this.receiverName,
    this.preStocked,
    this.lotId,
    this.sliceRank = 0,
    this.sliceKind,
    this.lotSliceCount = 1,
    this.lot,
  });

  final String id;
  final String sourceReportId;
  final String sourceReportItemId;
  final String? reportNo;
  final String? sourcePlanItemId;
  final String? planId;
  final String? planNo;
  final String? executionSegmentId;
  final String? executionSegmentSalesAllocationId;
  final String? warehouseId;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final double unitRate;
  final double reportedQty;
  final double passedQty;
  final double failedQty;
  final double remainingQty;
  final double authorizedInboundQty;
  final String status;
  final String? reportMakerId;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// V547 所属品质检查单（历史任务可能为空 = 「无检查单」）。
  final String? sheetId;
  final String? sheetNo;

  /// 来自仓库送检登记的只读事实：成品仓、库位快照、登记备注、收货人。
  final String? warehouseName;
  final String? place;
  final String? registrationRemark;
  final String? receiverName;

  /// 先入库后检(V597)：仓库登记时已把实物上架到成品仓库位，品质部到储放区域检验；
  /// 合格由系统按此位置自动点收入库。null = 原流程(合格后仓库再点收)。
  final WarehousePreStockedLocation? preStocked;

  /// ADR-148 实物交接批：同一报工、同一产出批次、同一去向的各份共用一个批号。
  final String? lotId;

  /// 本份在批内的归属(0 需求 / 1 计划公共 / 2 实际超产)与归属码。
  final int sliceRank;
  final String? sliceKind;

  /// 本批还在(未取消)的份数；大于 1 时只能在检查单里按整批判定。
  final int lotSliceCount;

  /// 检查单办理页的一行 = 一批实物(批内各份合计)；单份任务为空。
  final ProductionFqcInspectionLot? lot;

  bool get active => status == 'PENDING' || status == 'PARTIAL';

  /// 本份属于多份实物批：单份办理页只读，判定在检查单里按整批做。
  bool get wholeLotOnly => lot == null && lotSliceCount > 1;

  /// 检查单办理页的一行实物批(合计数量；判定走整批接口)。
  factory ProductionFqcInspection.fromLot(
    ProductionFqcInspectionLot lot, {
    String? sheetId,
    String? sheetNo,
  }) => ProductionFqcInspection(
    id: lot.lotId,
    sourceReportId: lot.sourceReportId,
    sourceReportItemId: lot.members.isEmpty
        ? ''
        : lot.members.first.sourceReportItemId,
    reportNo: lot.reportNo,
    planId: lot.planId,
    planNo: lot.planNo,
    warehouseId: lot.warehouseId,
    goodsId: lot.goodsId,
    goodsCode: lot.goodsCode,
    goodsName: lot.goodsName,
    colorId: lot.colorId,
    colorName: lot.colorName,
    unitId: lot.unitId,
    unitName: lot.unitName,
    reportedQty: lot.reportedQty,
    passedQty: lot.passedQty,
    failedQty: lot.failedQty,
    remainingQty: lot.remainingQty,
    authorizedInboundQty: 0,
    status: lot.status,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    sheetId: sheetId,
    sheetNo: sheetNo,
    warehouseName: lot.warehouseName,
    place: lot.place,
    preStocked: lot.preStocked,
    lotId: lot.lotId,
    lotSliceCount: lot.members.length,
    lot: lot,
  );

  factory ProductionFqcInspection.fromJson(Map<String, dynamic> json) {
    double number(String key) => (json[key] as num?)?.toDouble() ?? 0;
    DateTime instant(String key) =>
        DateTime.tryParse(json[key]?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return ProductionFqcInspection(
      id: json['id'] as String? ?? '',
      sourceReportId: json['sourceReportId'] as String? ?? '',
      sourceReportItemId: json['sourceReportItemId'] as String? ?? '',
      reportNo: json['reportNo'] as String?,
      sourcePlanItemId: json['sourcePlanItemId'] as String?,
      planId: json['planId'] as String?,
      planNo: json['planNo'] as String?,
      executionSegmentId: json['executionSegmentId'] as String?,
      executionSegmentSalesAllocationId:
          json['executionSegmentSalesAllocationId'] as String?,
      warehouseId: json['warehouseId'] as String?,
      goodsId: json['goodsId'] as String?,
      goodsCode: json['goodsCode'] as String?,
      goodsName: json['goodsName'] as String?,
      colorId: json['colorId'] as String?,
      colorName: json['colorName'] as String?,
      unitId: json['unitId'] as String?,
      unitName: json['unitName'] as String?,
      unitRate: number('unitRate'),
      reportedQty: number('reportedQty'),
      passedQty: number('passedQty'),
      failedQty: number('failedQty'),
      remainingQty: number('remainingQty'),
      authorizedInboundQty: number('authorizedInboundQty'),
      status: json['status'] as String? ?? 'PENDING',
      reportMakerId: json['reportMakerId'] as String?,
      createdAt: instant('createdAt'),
      updatedAt: instant('updatedAt'),
      sheetId: json['sheetId'] as String?,
      sheetNo: json['sheetNo'] as String?,
      warehouseName: json['warehouseName'] as String?,
      place: json['place'] as String?,
      registrationRemark: json['registrationRemark'] as String?,
      receiverName: json['receiverName'] as String?,
      preStocked: WarehousePreStockedLocation.tryParse(json['preStocked']),
      lotId: json['lotId'] as String?,
      sliceRank: (json['sliceRank'] as num?)?.toInt() ?? 0,
      sliceKind: json['sliceKind'] as String?,
      lotSliceCount: (json['lotSliceCount'] as num?)?.toInt() ?? 1,
    );
  }
}

/// 一批实物的品质视图(ADR-148)：批内各份合计、按归属拆分(服务端算一次)与各份当前判定。
/// [status]：PENDING 未判 / PARTIAL 部分已判 / RESOLVED 全部判完 / CANCELLED 已取消。
class ProductionFqcInspectionLot {
  const ProductionFqcInspectionLot({
    required this.lotId,
    required this.sourceReportId,
    required this.reportedQty,
    required this.passedQty,
    required this.failedQty,
    required this.remainingQty,
    required this.demandQty,
    required this.publicQty,
    required this.actualSurplusQty,
    required this.status,
    required this.members,
    this.reportNo,
    this.planId,
    this.planNo,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.splitText,
    this.warehouseId,
    this.warehouseName,
    this.place,
    this.preStocked,
  });

  final String lotId;
  final String sourceReportId;
  final String? reportNo;
  final String? planId;
  final String? planNo;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final double reportedQty;
  final double passedQty;
  final double failedQty;
  final double remainingQty;
  final double demandQty;
  final double publicQty;
  final double actualSurplusQty;

  /// 「需求 1000 · 实际超产 100」；整批都是需求份时为空。
  final String? splitText;
  final String status;
  final String? warehouseId;
  final String? warehouseName;
  final String? place;
  final WarehousePreStockedLocation? preStocked;
  final List<ProductionFqcInspectionLotMember> members;

  bool get active => status == 'PENDING' || status == 'PARTIAL';

  factory ProductionFqcInspectionLot.fromJson(Map<String, dynamic> json) {
    double number(String key) => (json[key] as num?)?.toDouble() ?? 0;
    return ProductionFqcInspectionLot(
      lotId: json['lotId'] as String? ?? '',
      sourceReportId: json['sourceReportId'] as String? ?? '',
      reportNo: json['reportNo'] as String?,
      planId: json['planId'] as String?,
      planNo: json['planNo'] as String?,
      goodsId: json['goodsId'] as String?,
      goodsCode: json['goodsCode'] as String?,
      goodsName: json['goodsName'] as String?,
      colorId: json['colorId'] as String?,
      colorName: json['colorName'] as String?,
      unitId: json['unitId'] as String?,
      unitName: json['unitName'] as String?,
      reportedQty: number('reportedQty'),
      passedQty: number('passedQty'),
      failedQty: number('failedQty'),
      remainingQty: number('remainingQty'),
      demandQty: number('demandQty'),
      publicQty: number('publicQty'),
      actualSurplusQty: number('actualSurplusQty'),
      splitText: json['splitText'] as String?,
      status: json['status'] as String? ?? 'PENDING',
      warehouseId: json['warehouseId'] as String?,
      warehouseName: json['warehouseName'] as String?,
      place: json['place'] as String?,
      preStocked: WarehousePreStockedLocation.tryParse(json['preStocked']),
      members:
          (json['members'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(ProductionFqcInspectionLotMember.fromJson)
              .toList(growable: false) ??
          const [],
    );
  }
}

/// 批内一份的当前判定。
class ProductionFqcInspectionLotMember {
  const ProductionFqcInspectionLotMember({
    required this.inspectionId,
    required this.sourceReportItemId,
    required this.sliceRank,
    required this.kind,
    required this.reportedQty,
    required this.passedQty,
    required this.failedQty,
    required this.remainingQty,
    required this.status,
  });

  final String inspectionId;
  final String sourceReportItemId;
  final int sliceRank;
  final String kind;
  final double reportedQty;
  final double passedQty;
  final double failedQty;
  final double remainingQty;
  final String status;

  factory ProductionFqcInspectionLotMember.fromJson(Map<String, dynamic> json) {
    double number(String key) => (json[key] as num?)?.toDouble() ?? 0;
    return ProductionFqcInspectionLotMember(
      inspectionId: json['inspectionId'] as String? ?? '',
      sourceReportItemId: json['sourceReportItemId'] as String? ?? '',
      sliceRank: (json['sliceRank'] as num?)?.toInt() ?? 0,
      kind: json['kind'] as String? ?? '',
      reportedQty: number('reportedQty'),
      passedQty: number('passedQty'),
      failedQty: number('failedQty'),
      remainingQty: number('remainingQty'),
      status: json['status'] as String? ?? 'PENDING',
    );
  }
}

/// V547 品质检查单头：待检处置队列一行一张；数量守恒仍在逐条 inspection。
class ProductionFqcInspectionSheet {
  const ProductionFqcInspectionSheet({
    required this.id,
    required this.sheetNo,
    this.warehouseId,
    this.warehouseName,
    this.receiverEmployeeId,
    this.receiverName,
    this.remark,
    this.sourceKind,
    required this.itemCount,
    required this.activeCount,
    this.pendingQtyText,
    this.reportNos,
    this.goodsSummary,
    required this.status,
    required this.createdAt,
    this.preStockedItemCount = 0,
    this.placeSummary,
  });

  final String id;
  final String sheetNo;
  final String? warehouseId;
  final String? warehouseName;
  final String? receiverEmployeeId;
  final String? receiverName;
  final String? remark;
  final String? sourceKind;
  final int itemCount;
  final int activeCount;

  /// 按单位分组的待检数量文本（服务端拼好，不跨单位相加），如 `20 只 · 3 箱`。
  final String? pendingQtyText;
  final String? reportNos;
  final String? goodsSummary;
  final String status;
  final DateTime createdAt;

  /// 先入库后检(V597)：仍在等结论且已上架到库位的行数(0 = 原流程)。
  final int preStockedItemCount;

  /// 登记库位去重清单（2026-09-17）：待检队列「库位号」列，品质部按此到储放区域检验。
  final String? placeSummary;

  bool get hasPreStockedItems => preStockedItemCount > 0;

  bool get active => status == 'ACTIVE';

  factory ProductionFqcInspectionSheet.fromJson(Map<String, dynamic> json) =>
      ProductionFqcInspectionSheet(
        id: json['id'] as String? ?? '',
        sheetNo: json['sheetNo'] as String? ?? '',
        warehouseId: json['warehouseId'] as String?,
        warehouseName: json['warehouseName'] as String?,
        receiverEmployeeId: json['receiverEmployeeId'] as String?,
        receiverName: json['receiverName'] as String?,
        remark: json['remark'] as String?,
        sourceKind: json['sourceKind'] as String?,
        itemCount: (json['itemCount'] as num?)?.toInt() ?? 0,
        activeCount: (json['activeCount'] as num?)?.toInt() ?? 0,
        pendingQtyText: json['pendingQtyText'] as String?,
        reportNos: json['reportNos'] as String?,
        goodsSummary: json['goodsSummary'] as String?,
        status: json['status'] as String? ?? 'ACTIVE',
        createdAt:
            DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        preStockedItemCount:
            (json['preStockedItemCount'] as num?)?.toInt() ?? 0,
        placeSummary: json['placeSummary'] as String?,
      );
}

/// 检查单办理视图：头 + 逐份 inspection + 按实物交接批分组的 lots(ADR-148)。
/// 办理页一批一行，一次判定合格/不良数量；服务端按瀑布分给批内各份。
class ProductionFqcInspectionSheetDetail {
  const ProductionFqcInspectionSheetDetail({
    required this.sheet,
    required this.inspections,
    this.lots = const [],
  });

  final ProductionFqcInspectionSheet sheet;
  final List<ProductionFqcInspection> inspections;
  final List<ProductionFqcInspectionLot> lots;

  List<ProductionFqcInspection> get activeInspections =>
      inspections.where((item) => item.active).toList(growable: false);

  /// 办理页的行：一批实物一行(批内各份合计)。
  List<ProductionFqcInspection> get lotInspections => [
    for (final lot in lots)
      ProductionFqcInspection.fromLot(
        lot,
        sheetId: sheet.id,
        sheetNo: sheet.sheetNo,
      ),
  ];

  List<ProductionFqcInspection> get activeLotInspections =>
      lotInspections.where((item) => item.active).toList(growable: false);

  factory ProductionFqcInspectionSheetDetail.fromJson(
    Map<String, dynamic> json,
  ) => ProductionFqcInspectionSheetDetail(
    sheet: ProductionFqcInspectionSheet.fromJson(
      json['sheet'] as Map<String, dynamic>? ?? const {},
    ),
    inspections:
        (json['inspections'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ProductionFqcInspection.fromJson)
            .toList(growable: false) ??
        const [],
    lots:
        (json['lots'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ProductionFqcInspectionLot.fromJson)
            .toList(growable: false) ??
        const [],
  );
}

class ProductionFqcDecisionResult {
  const ProductionFqcDecisionResult({
    required this.decisionEventId,
    required this.inspection,
    required this.replay,
  });

  final String decisionEventId;
  final ProductionFqcInspection inspection;
  final bool replay;

  factory ProductionFqcDecisionResult.fromJson(Map<String, dynamic> json) =>
      ProductionFqcDecisionResult(
        decisionEventId: json['decisionEventId'] as String? ?? '',
        inspection: ProductionFqcInspection.fromJson(
          json['inspection'] as Map<String, dynamic>? ?? const {},
        ),
        replay: json['replay'] as bool? ?? false,
      );
}
