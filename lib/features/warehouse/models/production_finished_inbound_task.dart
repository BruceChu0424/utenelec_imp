enum ProductionFinishedInboundTaskStage {
  arrivalRegistration('ARRIVAL_REGISTRATION'),
  finalCount('FINAL_COUNT');

  const ProductionFinishedInboundTaskStage(this.code);

  final String code;

  static ProductionFinishedInboundTaskStage fromCode(String? code) =>
      values.firstWhere(
        (stage) => stage.code == code,
        orElse: () => ProductionFinishedInboundTaskStage.finalCount,
      );
}

enum ProductionFinishedPlaceSuggestionSource {
  warehousePreference('WAREHOUSE_PREFERENCE'),
  registrationHistory('REGISTRATION_HISTORY'),
  goodsMaster('GOODS_MASTER'),
  none('NONE');

  const ProductionFinishedPlaceSuggestionSource(this.code);

  final String code;

  static ProductionFinishedPlaceSuggestionSource fromCode(String? code) =>
      values.firstWhere(
        (source) => source.code == code,
        orElse: () => ProductionFinishedPlaceSuggestionSource.none,
      );
}

class ProductionFinishedPlaceSuggestion {
  const ProductionFinishedPlaceSuggestion({
    required this.reportItemId,
    required this.source,
    this.place,
  });

  final String reportItemId;
  final String? place;
  final ProductionFinishedPlaceSuggestionSource source;

  factory ProductionFinishedPlaceSuggestion.fromJson(
    Map<String, dynamic> json,
  ) => ProductionFinishedPlaceSuggestion(
    reportItemId: json['reportItemId'] as String? ?? '',
    place: json['place'] as String?,
    source: ProductionFinishedPlaceSuggestionSource.fromCode(
      json['source'] as String?,
    ),
  );
}

class ProductionFinishedRememberPlacesResult {
  const ProductionFinishedRememberPlacesResult({
    required this.remembered,
    required this.unchanged,
    required this.ambiguous,
    required this.warnings,
  });

  final int remembered;
  final int unchanged;
  final int ambiguous;
  final List<String> warnings;

  factory ProductionFinishedRememberPlacesResult.fromJson(
    Map<String, dynamic> json,
  ) => ProductionFinishedRememberPlacesResult(
    remembered: (json['remembered'] as num?)?.toInt() ?? 0,
    unchanged: (json['unchanged'] as num?)?.toInt() ?? 0,
    ambiguous: (json['ambiguous'] as num?)?.toInt() ?? 0,
    warnings:
        (json['warnings'] as List?)
            ?.map((warning) => warning?.toString().trim() ?? '')
            .where((warning) => warning.isNotEmpty)
            .toList(growable: false) ??
        const [],
  );
}

/// 多报工单汇总登记结果：一次提交逐单登记所选明细并逐行送检；
/// V547 起同仓合并成一张品质检查单（sheets 每仓一张）。
class ProductionFinishedBatchRegistrationResult {
  const ProductionFinishedBatchRegistrationResult({
    required this.registeredCount,
    required this.reports,
    this.sheets = const [],
  });

  final int registeredCount;
  final List<ProductionFinishedRegisteredReport> reports;
  final List<ProductionFinishedInspectionSheetSummary> sheets;

  factory ProductionFinishedBatchRegistrationResult.fromJson(
    Map<String, dynamic> json,
  ) => ProductionFinishedBatchRegistrationResult(
    registeredCount: (json['registeredCount'] as num?)?.toInt() ?? 0,
    reports:
        (json['reports'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ProductionFinishedRegisteredReport.fromJson)
            .toList(growable: false) ??
        const [],
    sheets:
        (json['sheets'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ProductionFinishedInspectionSheetSummary.fromJson)
            .toList(growable: false) ??
        const [],
  );
}

/// 本次登记命令生成的品质检查单（每个成品仓一张）。
class ProductionFinishedInspectionSheetSummary {
  const ProductionFinishedInspectionSheetSummary({
    required this.sheetId,
    required this.sheetNo,
    this.warehouseId,
    this.warehouseName,
    required this.itemCount,
  });

  final String sheetId;
  final String sheetNo;
  final String? warehouseId;
  final String? warehouseName;
  final int itemCount;

  factory ProductionFinishedInspectionSheetSummary.fromJson(
    Map<String, dynamic> json,
  ) => ProductionFinishedInspectionSheetSummary(
    sheetId: json['sheetId'] as String? ?? '',
    sheetNo: json['sheetNo'] as String? ?? '',
    warehouseId: json['warehouseId'] as String?,
    warehouseName: json['warehouseName'] as String?,
    itemCount: (json['itemCount'] as num?)?.toInt() ?? 0,
  );
}

class ProductionFinishedRegisteredReport {
  const ProductionFinishedRegisteredReport({
    this.registrationId,
    required this.reportId,
    this.reportNo,
    this.warehouseId,
    this.warehouseName,
    this.sheetId,
    this.sheetNo,
  });

  final String? registrationId;
  final String reportId;
  final String? reportNo;
  final String? warehouseId;
  final String? warehouseName;
  final String? sheetId;
  final String? sheetNo;

  factory ProductionFinishedRegisteredReport.fromJson(
    Map<String, dynamic> json,
  ) => ProductionFinishedRegisteredReport(
    registrationId: json['registrationId'] as String?,
    reportId: json['reportId'] as String? ?? '',
    reportNo: json['reportNo'] as String?,
    warehouseId: json['warehouseId'] as String?,
    warehouseName: json['warehouseName'] as String?,
    sheetId: json['sheetId'] as String?,
    sheetNo: json['sheetNo'] as String?,
  );
}

/// 同一报工的一个登记批次（V469 分批 + V547 检查单 + V548 撤回态）。
class ProductionFinishedRegistrationBatch {
  const ProductionFinishedRegistrationBatch({
    required this.registrationId,
    this.warehouseId,
    this.warehouseName,
    this.receiverName,
    this.remark,
    this.registeredAt,
    required this.itemCount,
    this.sheetId,
    this.sheetNo,
    this.reversedAt,
    this.reversalReason,
    this.reversible = false,
  });

  final String registrationId;
  final String? warehouseId;
  final String? warehouseName;
  final String? receiverName;
  final String? remark;
  final DateTime? registeredAt;
  final int itemCount;
  final String? sheetId;
  final String? sheetNo;
  final DateTime? reversedAt;
  final String? reversalReason;

  /// 服务端判定：未撤回且本批每条 FQC 仍待检、无决定/放行/恢复授权。
  final bool reversible;

  bool get reversed => reversedAt != null;

  factory ProductionFinishedRegistrationBatch.fromJson(
    Map<String, dynamic> json,
  ) => ProductionFinishedRegistrationBatch(
    registrationId: json['registrationId'] as String? ?? '',
    warehouseId: json['warehouseId'] as String?,
    warehouseName: json['warehouseName'] as String?,
    receiverName: json['receiverName'] as String?,
    remark: json['remark'] as String?,
    registeredAt: DateTime.tryParse(json['registeredAt']?.toString() ?? ''),
    itemCount: (json['itemCount'] as num?)?.toInt() ?? 0,
    sheetId: json['sheetId'] as String?,
    sheetNo: json['sheetNo'] as String?,
    reversedAt: DateTime.tryParse(json['reversedAt']?.toString() ?? ''),
    reversalReason: json['reversalReason'] as String?,
    reversible: json['reversible'] as bool? ?? false,
  );
}

/// 当前用户最近一次成品送检登记所用成品仓（下次进入自动预选）。
class ProductionFinishedLastWarehouse {
  const ProductionFinishedLastWarehouse({
    required this.warehouseId,
    this.warehouseCode,
    this.warehouseName,
  });

  final String warehouseId;
  final String? warehouseCode;
  final String? warehouseName;

  factory ProductionFinishedLastWarehouse.fromJson(Map<String, dynamic> json) =>
      ProductionFinishedLastWarehouse(
        warehouseId: json['warehouseId'] as String? ?? '',
        warehouseCode: json['warehouseCode'] as String?,
        warehouseName: json['warehouseName'] as String?,
      );
}

class ProductionFinishedInboundTask {
  const ProductionFinishedInboundTask({
    required this.taskStage,
    required this.taskId,
    this.documentNo,
    required this.documentDate,
    required this.lineCount,
    required this.pendingQty,
    required this.createdAt,
    required this.residualTask,
    this.reportId,
    this.documentId,
    this.warehouseId,
    this.warehouseName,
    this.planId,
    this.planNo,
    this.reportNos,
    this.goodsSummary,
  });

  final ProductionFinishedInboundTaskStage taskStage;
  final String taskId;
  final String? reportId;
  final String? documentId;
  final String? documentNo;
  final DateTime documentDate;
  final String? warehouseId;
  final String? warehouseName;
  final String? planId;
  final String? planNo;
  final String? reportNos;
  final String? goodsSummary;
  final int lineCount;
  final double pendingQty;
  final DateTime createdAt;
  final bool residualTask;

  bool get isArrivalRegistration =>
      taskStage == ProductionFinishedInboundTaskStage.arrivalRegistration;

  factory ProductionFinishedInboundTask.fromJson(Map<String, dynamic> json) {
    DateTime parseDate(String key) =>
        DateTime.tryParse(json[key]?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);

    return ProductionFinishedInboundTask(
      taskStage: ProductionFinishedInboundTaskStage.fromCode(
        json['taskStage'] as String?,
      ),
      taskId:
          json['taskId'] as String? ??
          json['documentId'] as String? ??
          json['reportId'] as String? ??
          '',
      reportId: json['reportId'] as String?,
      documentId: json['documentId'] as String?,
      documentNo: json['documentNo'] as String?,
      documentDate: parseDate('documentDate'),
      warehouseId: json['warehouseId'] as String?,
      warehouseName: json['warehouseName'] as String?,
      planId: json['planId'] as String?,
      planNo: json['planNo'] as String?,
      reportNos: json['reportNos'] as String?,
      goodsSummary: json['goodsSummary'] as String?,
      lineCount: (json['lineCount'] as num?)?.toInt() ?? 0,
      pendingQty: (json['pendingQty'] as num?)?.toDouble() ?? 0,
      createdAt: parseDate('createdAt'),
      residualTask: json['residualTask'] as bool? ?? false,
    );
  }
}

class ProductionFinishedArrivalRegistration {
  const ProductionFinishedArrivalRegistration({
    this.registrationId,
    required this.registered,
    required this.reportId,
    required this.reportNo,
    required this.reportDate,
    required this.items,
    this.departmentId,
    this.workshopName,
    this.warehouseId,
    this.warehouseCode,
    this.warehouseName,
    this.receiverEmployeeId,
    this.receiverName,
    this.remark,
    this.registeredAt,
    this.sheetId,
    this.sheetNo,
    this.reversedAt,
    this.reversalReason,
    this.reversible = false,
    this.batches = const [],
  });

  final String? registrationId;
  final bool registered;
  final String reportId;
  final String reportNo;
  final DateTime reportDate;
  final String? departmentId;
  final String? workshopName;
  final String? warehouseId;
  final String? warehouseCode;
  final String? warehouseName;
  final String? receiverEmployeeId;
  final String? receiverName;

  /// 登记备注（V542：随登记批次留痕，登记详情回显）。
  final String? remark;
  final DateTime? registeredAt;

  /// V547 本登记批次所属品质检查单；V548 撤回态与可撤回判定（服务端权威）。
  final String? sheetId;
  final String? sheetNo;
  final DateTime? reversedAt;
  final String? reversalReason;
  final bool reversible;

  /// 同一报工的全部登记批次（含已撤回）；待登记视图也带回，便于回看历史批次。
  final List<ProductionFinishedRegistrationBatch> batches;
  final List<ProductionFinishedArrivalRegistrationItem> items;

  List<String> get planNos => items
      .map((item) => item.planNo?.trim() ?? '')
      .where((planNo) => planNo.isNotEmpty)
      .toSet()
      .toList(growable: false);

  factory ProductionFinishedArrivalRegistration.fromJson(
    Map<String, dynamic> json,
  ) => ProductionFinishedArrivalRegistration(
    registrationId: json['registrationId'] as String?,
    registered: json['registered'] as bool? ?? false,
    reportId: json['reportId'] as String? ?? '',
    reportNo: json['reportNo'] as String? ?? '',
    reportDate:
        DateTime.tryParse(json['reportDate']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    departmentId: json['departmentId'] as String?,
    workshopName: json['workshopName'] as String?,
    warehouseId: json['warehouseId'] as String?,
    warehouseCode: json['warehouseCode'] as String?,
    warehouseName: json['warehouseName'] as String?,
    receiverEmployeeId: json['receiverEmployeeId'] as String?,
    receiverName: json['receiverName'] as String?,
    remark: json['remark'] as String?,
    registeredAt: DateTime.tryParse(json['registeredAt']?.toString() ?? ''),
    sheetId: json['sheetId'] as String?,
    sheetNo: json['sheetNo'] as String?,
    reversedAt: DateTime.tryParse(json['reversedAt']?.toString() ?? ''),
    reversalReason: json['reversalReason'] as String?,
    reversible: json['reversible'] as bool? ?? false,
    batches:
        (json['batches'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ProductionFinishedRegistrationBatch.fromJson)
            .toList(growable: false) ??
        const [],
    items:
        (json['items'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(
              (item) =>
                  ProductionFinishedArrivalRegistrationItem.fromJson(item),
            )
            .toList(growable: false) ??
        const [],
  );
}

class ProductionFinishedArrivalRegistrationItem {
  const ProductionFinishedArrivalRegistrationItem({
    required this.reportItemId,
    required this.lineNo,
    required this.goodsId,
    required this.goodsCode,
    required this.goodsName,
    required this.reportedQty,
    this.planItemId,
    this.executionSegmentId,
    this.planId,
    this.planNo,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.place,
    this.placeHint,
    this.lastWarehouseId,
    this.lastWarehouseName,
  });

  final String reportItemId;
  final int lineNo;
  final String goodsId;
  final String goodsCode;
  final String goodsName;
  final String? planItemId;
  final String? executionSegmentId;
  final String? planId;
  final String? planNo;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final double reportedQty;
  final String? place;
  final String? placeHint;

  /// 同货品同颜色最近一次有效登记的成品仓（只读建议，页面预填并黄框提示核对）。
  final String? lastWarehouseId;
  final String? lastWarehouseName;

  factory ProductionFinishedArrivalRegistrationItem.fromJson(
    Map<String, dynamic> json,
  ) => ProductionFinishedArrivalRegistrationItem(
    reportItemId: json['reportItemId'] as String? ?? '',
    lineNo: (json['lineNo'] as num?)?.toInt() ?? 0,
    goodsId: json['goodsId'] as String? ?? '',
    goodsCode: json['goodsCode'] as String? ?? '',
    goodsName: json['goodsName'] as String? ?? '',
    planItemId: json['planItemId'] as String?,
    executionSegmentId: json['executionSegmentId'] as String?,
    planId: json['planId'] as String?,
    planNo: json['planNo'] as String?,
    colorId: json['colorId'] as String?,
    colorName: json['colorName'] as String?,
    unitId: json['unitId'] as String?,
    unitName: json['unitName'] as String?,
    reportedQty:
        (json['reportedQty'] as num?)?.toDouble() ??
        (json['qty'] as num?)?.toDouble() ??
        0,
    place: json['place'] as String?,
    placeHint: json['placeHint'] as String?,
    lastWarehouseId: json['lastWarehouseId'] as String?,
    lastWarehouseName: json['lastWarehouseName'] as String?,
  );
}
