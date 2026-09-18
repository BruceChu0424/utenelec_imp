import 'warehouse_iqc_stock_in.dart'
    show
        WarehouseInboundAllocation,
        WarehouseIqcStockInConfirmItem,
        WarehouseIqcStockInReceiptType;
import 'warehouse_pre_stocked_location.dart';

export 'warehouse_pre_stocked_location.dart';

/// 检查明细行的逐行判定（详情页表格前导图标口径）。
enum WarehouseQualityLineVerdict {
  /// 合格：已有合格结论且无不合格、无待检余量 → 绿色对勾。
  passed('合格'),

  /// 部分合格：既有合格又有不合格，或合格之外仍有待检余量 → 黄色警告。
  partial('部分合格'),

  /// 不合格：整行只有不合格结论 → 红色禁止。
  rejected('不合格'),

  /// 待检：尚无任何结论 → 蓝色沙漏。
  waiting('待检'),

  /// 已撤销：收货单红冲，冻结行的结论量已清零 → 灰色撤销。
  revoked('已撤销');

  const WarehouseQualityLineVerdict(this.label);

  final String label;
}

/// 品质部检查结果合并页的作业状态（服务端 WarehouseQualityResultService 同口径）。
enum WarehouseQualityWorkStatus {
  waitingInspection('WAITING_INSPECTION', '等待检查结果', '等待结果'),
  allPassed('ALL_PASSED', '全部合格 · 待入库', '全部合格'),
  partialPassed('PARTIAL_PASSED', '部分合格 · 部分待入库', '部分合格'),
  returnRequired('RETURN_REQUIRED', '全部不合格 · 需退回', '不合格退回'),
  completed('COMPLETED', '已完结', '已完结');

  const WarehouseQualityWorkStatus(this.apiValue, this.label, this.shortLabel);

  final String apiValue;
  final String label;

  /// 顶部状态分段用短标签（整条工具条放不下五个全称）。
  final String shortLabel;

  /// 等待检查结果由品质部推进，仓库无动作；其余未完结状态都是仓库待办。
  bool get actionable =>
      this == allPassed || this == partialPassed || this == returnRequired;

  bool get isCompleted => this == completed;

  static WarehouseQualityWorkStatus tryParse(Object? value) {
    final normalized = value?.toString().trim().toUpperCase();
    for (final status in values) {
      if (status.apiValue == normalized) return status;
    }
    return completed;
  }
}

/// 合并页任务行：按收货单聚合的品质结论 + 仓库待办量（无金额字段）。
class WarehouseQualityResultTask {
  const WarehouseQualityResultTask({
    required this.receiptType,
    required this.receiptId,
    required this.workStatus,
    required this.goodsLineCount,
    required this.passedLineCount,
    required this.failedLineCount,
    required this.openItemCount,
    required this.pendingSliceCount,
    required this.pendingReturnCount,
    this.billNo,
    this.billDate,
    this.supplierId,
    this.supplierName,
    this.warehouseId,
    this.warehouseName,
    this.lastActivityAt,
    this.preStockedLineCount = 0,
  });

  final WarehouseIqcStockInReceiptType receiptType;
  final String receiptId;
  final String? billNo;
  final String? billDate;
  final String? supplierId;
  final String? supplierName;

  /// Receipt-time warehouse reference; actual stock-in warehouses are line facts.
  final String? warehouseId;
  final String? warehouseName;
  final WarehouseQualityWorkStatus workStatus;
  final int goodsLineCount;
  final int passedLineCount;
  final int failedLineCount;
  final int openItemCount;
  final int pendingSliceCount;
  final int pendingReturnCount;
  final String? lastActivityAt;

  /// 先入库后质检(V596)：仍在等结论且已上架的明细行数(>0 = 实物已在库位、合格自动转正)。
  final int preStockedLineCount;

  String get receiptTypeValue => receiptType.apiValue;

  /// 等结论的行里还有未上架的：可以补做「先入库上架」。
  bool get hasPreStockableLines =>
      !workStatus.isCompleted && openItemCount > preStockedLineCount;

  /// 列表「作业状态」列：等待检查结果时补一句上架进度，仓库一眼看出实物在哪。
  String get workStatusLabel => preStockedLineCount > 0
      ? '${workStatus.label} · 已上架 $preStockedLineCount 行'
      : workStatus.label;

  /// 列表「品质结论」列：合格 / 不合格 / 待检 行数一眼可比。
  String get verdictLabel {
    final parts = <String>[
      '合格 $passedLineCount',
      if (failedLineCount > 0) '不合格 $failedLineCount',
      if (openItemCount > 0) '待检 $openItemCount',
    ];
    return '${parts.join(' · ')} / 共 $goodsLineCount 行';
  }

  factory WarehouseQualityResultTask.fromJson(Map<String, dynamic> json) =>
      WarehouseQualityResultTask(
        receiptType: _requiredReceiptType(json['receiptType']),
        receiptId: _requiredText(json['receiptId'], '品质检查结果任务缺少 receiptId'),
        billNo: _text(json['billNo']),
        billDate: _text(json['billDate']),
        supplierId: _text(json['supplierId']),
        supplierName: _text(json['supplierName']),
        warehouseId: _text(json['warehouseId']),
        warehouseName: _text(json['warehouseName']),
        workStatus: WarehouseQualityWorkStatus.tryParse(json['workStatus']),
        goodsLineCount: _integer(json['goodsLineCount']),
        passedLineCount: _integer(json['passedLineCount']),
        failedLineCount: _integer(json['failedLineCount']),
        openItemCount: _integer(json['openItemCount']),
        pendingSliceCount: _integer(json['pendingSliceCount']),
        pendingReturnCount: _integer(json['pendingReturnCount']),
        lastActivityAt: _text(json['lastActivityAt']),
        preStockedLineCount: _integer(json['preStockedLineCount']),
      );
}

/// 合并页详情：单据概要 + 待入库切片 + 入库历史 + 不合格退回案件。
class WarehouseQualityResultDetail {
  const WarehouseQualityResultDetail({
    required this.receiptType,
    required this.receiptId,
    required this.workStatus,
    required this.qualityStatus,
    required this.goodsLineCount,
    required this.passedLineCount,
    required this.failedLineCount,
    required this.openItemCount,
    required this.pendingSliceCount,
    required this.pendingReturnCount,
    required this.completed,
    required this.containsOwnRelease,
    required this.allowedActions,
    required this.lines,
    required this.items,
    required this.history,
    required this.rejections,
    this.billNo,
    this.billDate,
    this.supplierId,
    this.supplierName,
    this.warehouseId,
    this.warehouseName,
    this.preStockedLineCount = 0,
  });

  /// 服务端动作码：先入库上架(需 warehouse_iqc_stock_in:before_inspection)。
  static const actionPreStockIn = 'PRE_STOCK_IN';

  final WarehouseIqcStockInReceiptType receiptType;
  final String receiptId;
  final String? billNo;
  final String? billDate;
  final String? supplierId;
  final String? supplierName;
  final String? warehouseId;
  final String? warehouseName;
  final WarehouseQualityWorkStatus workStatus;
  final String qualityStatus;
  final int goodsLineCount;
  final int passedLineCount;
  final int failedLineCount;
  final int openItemCount;
  final int pendingSliceCount;
  final int pendingReturnCount;
  final bool completed;
  final bool containsOwnRelease;
  final Set<String> allowedActions;
  final List<WarehouseQualityInspectionLine> lines;
  final List<WarehouseQualityReleasedSlice> items;
  final List<WarehouseQualityStockInHistoryItem> history;
  final List<WarehouseQualityRejectionCase> rejections;

  /// 先入库后质检(V596)：仍在等结论且已上架的明细行数。
  final int preStockedLineCount;

  bool get canConfirm =>
      !completed && items.isNotEmpty && allowedActions.contains('CONFIRM');

  /// 仍有等结论且未上架的行，且服务端授予了先入库动作。
  bool get canPreStockIn =>
      !completed &&
      allowedActions.contains(actionPreStockIn) &&
      lines.any((line) => line.preStockable);

  /// 等结论且未上架、可被先入库上架的行。
  List<WarehouseQualityInspectionLine> get preStockableLines =>
      [for (final line in lines) if (line.preStockable) line];

  String get qualityStatusLabel => switch (qualityStatus.trim().toUpperCase()) {
    'IN_PROGRESS' => '品质检验进行中',
    'PENDING' => '部分待检',
    'PARTIAL' => '部分处置',
    'RESOLVED' => '品质已结案',
    'REVERSED' => '品质已撤销',
    _ => qualityStatus.trim().isEmpty ? '品质状态未知' : qualityStatus.trim(),
  };

  factory WarehouseQualityResultDetail.fromJson(Map<String, dynamic> json) {
    final lineRows = json['lines'] as List? ?? const [];
    final itemRows = json['items'] as List? ?? const [];
    final historyRows = json['history'] as List? ?? const [];
    final rejectionRows = json['rejections'] as List? ?? const [];
    return WarehouseQualityResultDetail(
      receiptType: _requiredReceiptType(json['receiptType']),
      receiptId: _requiredText(json['receiptId'], '品质检查结果详情缺少 receiptId'),
      billNo: _text(json['billNo']),
      billDate: _text(json['billDate']),
      supplierId: _text(json['supplierId']),
      supplierName: _text(json['supplierName']),
      warehouseId: _text(json['warehouseId']),
      warehouseName: _text(json['warehouseName']),
      workStatus: WarehouseQualityWorkStatus.tryParse(json['workStatus']),
      qualityStatus: _text(json['qualityStatus']) ?? '',
      goodsLineCount: _integer(json['goodsLineCount']),
      passedLineCount: _integer(json['passedLineCount']),
      failedLineCount: _integer(json['failedLineCount']),
      openItemCount: _integer(json['openItemCount']),
      pendingSliceCount: _integer(json['pendingSliceCount']),
      pendingReturnCount: _integer(json['pendingReturnCount']),
      completed: json['completed'] == true,
      containsOwnRelease: json['containsOwnRelease'] == true,
      allowedActions: _stringSet(json['allowedActions']),
      preStockedLineCount: _integer(json['preStockedLineCount']),
      lines: [
        for (final row in lineRows.whereType<Map<Object?, Object?>>())
          WarehouseQualityInspectionLine.fromJson(
            Map<String, dynamic>.from(row),
          ),
      ],
      items: [
        for (final row in itemRows.whereType<Map<Object?, Object?>>())
          WarehouseQualityReleasedSlice.fromJson(
            Map<String, dynamic>.from(row),
          ),
      ],
      history: [
        for (final row in historyRows.whereType<Map<Object?, Object?>>())
          WarehouseQualityStockInHistoryItem.fromJson(
            Map<String, dynamic>.from(row),
          ),
      ],
      rejections: [
        for (final row in rejectionRows.whereType<Map<Object?, Object?>>())
          WarehouseQualityRejectionCase.fromJson(
            Map<String, dynamic>.from(row),
          ),
      ],
    );
  }
}

/// 检查结果明细行：详情页表格逐货品行的判定数据（无金额字段）。
/// 判定（合格/部分/不合格/待检）由数量与行状态推导，服务端不下结论。
class WarehouseQualityInspectionLine {
  const WarehouseQualityInspectionLine({
    required this.inspectionItemId,
    required this.goodsId,
    required this.receivedBaseQty,
    required this.passedBaseQty,
    required this.failedBaseQty,
    required this.warehouseStockedBaseQty,
    required this.pendingStockBaseQty,
    required this.lineStatus,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitId,
    this.unitName,
    this.warehouseId,
    this.warehouseName,
    this.preStocked,
    this.placeHint,
  });

  final String inspectionItemId;
  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final String? warehouseId;
  final String? warehouseName;
  final double receivedBaseQty;
  final double passedBaseQty;
  final double failedBaseQty;
  final double warehouseStockedBaseQty;
  final double pendingStockBaseQty;
  final String lineStatus;

  /// 先入库后质检(V596)：该行实物已上架的仓/库位；null = 走原流程。
  final WarehousePreStockedLocation? preStocked;

  /// 建议库位(仓库×货品×颜色学习偏好，回落货品主档)；先入库上架页预填。
  final String? placeHint;

  /// 等结论、尚无任何结论且未上架的行可以先入库上架(服务端同口径)。
  bool get preStockable =>
      preStocked == null &&
      lineStatus.trim().toUpperCase() == 'PENDING' &&
      passedBaseQty <= 0 &&
      failedBaseQty <= 0;

  String get goodsLabel => [
    goodsCode,
    goodsName,
    if (colorName?.isNotEmpty == true) colorName,
  ].where((value) => value?.trim().isNotEmpty == true).join(' · ');

  /// PENDING/PARTIAL = 检验未出完（仍有待检余量）。
  bool get isOpen =>
      lineStatus.trim().toUpperCase() == 'PENDING' ||
      lineStatus.trim().toUpperCase() == 'PARTIAL';

  /// 逐行判定：收货红冲行（结论量已清零）直接判已撤销；其余不合格优先看
  /// 有无合格量；有合格但仍有待检/不合格 → 部分。
  WarehouseQualityLineVerdict get verdict {
    if (lineStatus.trim().toUpperCase() == 'REVERSED') {
      return WarehouseQualityLineVerdict.revoked;
    }
    if (failedBaseQty > 0 && passedBaseQty <= 0) {
      return WarehouseQualityLineVerdict.rejected;
    }
    if (passedBaseQty > 0 && (failedBaseQty > 0 || isOpen)) {
      return WarehouseQualityLineVerdict.partial;
    }
    if (passedBaseQty > 0) return WarehouseQualityLineVerdict.passed;
    return WarehouseQualityLineVerdict.waiting;
  }

  factory WarehouseQualityInspectionLine.fromJson(Map<String, dynamic> json) =>
      WarehouseQualityInspectionLine(
        inspectionItemId: _requiredText(
          json['inspectionItemId'],
          '检查明细行缺少 inspectionItemId',
        ),
        goodsId: _requiredText(json['goodsId'], '检查明细行缺少 goodsId'),
        goodsCode: _text(json['goodsCode']),
        goodsName: _text(json['goodsName']),
        colorName: _text(json['colorName']),
        unitId: _text(json['unitId']),
        unitName: _text(json['unitName']),
        warehouseId: _text(json['warehouseId']),
        warehouseName: _text(json['warehouseName']),
        receivedBaseQty: _decimal(json['receivedBaseQty']),
        passedBaseQty: _decimal(json['passedBaseQty']),
        failedBaseQty: _decimal(json['failedBaseQty']),
        warehouseStockedBaseQty: _decimal(json['warehouseStockedBaseQty']),
        pendingStockBaseQty: _decimal(json['pendingStockBaseQty']),
        lineStatus: _text(json['lineStatus']) ?? 'PENDING',
        preStocked: WarehousePreStockedLocation.tryParse(json['preStocked']),
        placeHint: _text(json['placeHint']),
      );
}

/// 品质放行待入库切片（与 IQC 待入库详情同形，仓库合并页复用）。
class WarehouseQualityReleasedSlice {
  const WarehouseQualityReleasedSlice({
    required this.passEventId,
    required this.inspectionItemId,
    required this.goodsId,
    required this.receivedBaseQty,
    required this.qualityPassedBaseQty,
    required this.warehouseStockedBaseQty,
    required this.releasedBaseQty,
    required this.stockedForReleaseBaseQty,
    required this.remainingBaseQty,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitId,
    this.unitName,
    this.sourceOrderNo,
    this.releasedWeight,
    this.weightUnitId,
    this.weightUnitName,
    this.placeHint,
    this.releaseNote,
    this.releasedBy,
    this.releasedAt,
    this.warehouseId,
    this.warehouseName,
    this.expectedAllocations = const [],
  });

  final String passEventId;
  final String inspectionItemId;
  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final String? sourceOrderNo;
  final double receivedBaseQty;
  final double qualityPassedBaseQty;
  final double warehouseStockedBaseQty;
  final double releasedBaseQty;
  final double stockedForReleaseBaseQty;
  final double remainingBaseQty;
  final double? releasedWeight;
  final String? weightUnitId;
  final String? weightUnitName;
  final String? placeHint;
  final String? releaseNote;
  final String? releasedBy;
  final String? releasedAt;
  final String? warehouseId;
  final String? warehouseName;
  final List<WarehouseInboundAllocation> expectedAllocations;

  String get goodsLabel => [
    goodsCode,
    goodsName,
    if (colorName?.isNotEmpty == true) colorName,
  ].where((value) => value?.trim().isNotEmpty == true).join(' · ');

  factory WarehouseQualityReleasedSlice.fromJson(Map<String, dynamic> json) =>
      WarehouseQualityReleasedSlice(
        passEventId: _requiredText(json['passEventId'], '待入库切片缺少 passEventId'),
        inspectionItemId: _requiredText(
          json['inspectionItemId'],
          '待入库切片缺少 inspectionItemId',
        ),
        goodsId: _requiredText(json['goodsId'], '待入库切片缺少 goodsId'),
        goodsCode: _text(json['goodsCode']),
        goodsName: _text(json['goodsName']),
        colorName: _text(json['colorName']),
        unitId: _text(json['unitId']),
        unitName: _text(json['unitName']),
        sourceOrderNo: _text(json['sourceOrderNo']),
        receivedBaseQty: _decimal(json['receivedBaseQty']),
        qualityPassedBaseQty: _decimal(json['qualityPassedBaseQty']),
        warehouseStockedBaseQty: _decimal(json['warehouseStockedBaseQty']),
        releasedBaseQty: _decimal(json['releasedBaseQty']),
        stockedForReleaseBaseQty: _decimal(json['stockedForReleaseBaseQty']),
        remainingBaseQty: _decimal(json['remainingBaseQty']),
        releasedWeight: _nullableDecimal(json['releasedWeight']),
        weightUnitId: _text(json['weightUnitId']),
        weightUnitName: _text(json['weightUnitName']),
        placeHint: _text(json['placeHint']),
        releaseNote: _text(json['releaseNote']),
        releasedBy: _text(json['releasedBy']),
        releasedAt: _text(json['releasedAt']),
        warehouseId: _text(json['warehouseId']),
        warehouseName: _text(json['warehouseName']),
        expectedAllocations: _allocationList(json['expectedAllocations']),
      );
}

/// 仓库入库历史行（只读事实）。
class WarehouseQualityStockInHistoryItem {
  const WarehouseQualityStockInHistoryItem({
    required this.stockInItemId,
    required this.batchId,
    required this.passEventId,
    required this.goodsId,
    required this.baseQty,
    required this.place,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitName,
    this.weight,
    this.weightUnitName,
    this.confirmedBy,
    this.confirmedAt,
    this.warehouseId,
    this.warehouseName,
    this.actualAllocations = const [],
    this.origin = 'WAREHOUSE_CONFIRM',
  });

  final String stockInItemId;
  final String batchId;
  final String passEventId;
  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitName;
  final double baseQty;
  final double? weight;
  final String? weightUnitName;
  final String place;
  final String? confirmedBy;
  final String? confirmedAt;
  final String? warehouseId;
  final String? warehouseName;
  final List<WarehouseInboundAllocation> actualAllocations;

  /// 入库批次来源：WAREHOUSE_CONFIRM(仓库确认) / PRE_STOCKED_AUTO(先入库后检合格自动转正)。
  final String origin;

  bool get isAutoFromPreStock => origin.trim().toUpperCase() == 'PRE_STOCKED_AUTO';

  String get originLabel => isAutoFromPreStock ? '先入库后检 · 合格自动转正' : '仓库确认入库';

  String get goodsLabel => [
    goodsCode,
    goodsName,
    if (colorName?.isNotEmpty == true) colorName,
  ].where((value) => value?.trim().isNotEmpty == true).join(' · ');

  factory WarehouseQualityStockInHistoryItem.fromJson(
    Map<String, dynamic> json,
  ) => WarehouseQualityStockInHistoryItem(
    stockInItemId: _requiredText(json['stockInItemId'], '入库历史缺少 stockInItemId'),
    batchId: _requiredText(json['batchId'], '入库历史缺少 batchId'),
    passEventId: _requiredText(json['passEventId'], '入库历史缺少 passEventId'),
    goodsId: _requiredText(json['goodsId'], '入库历史缺少 goodsId'),
    goodsCode: _text(json['goodsCode']),
    goodsName: _text(json['goodsName']),
    colorName: _text(json['colorName']),
    unitName: _text(json['unitName']),
    baseQty: _decimal(json['baseQty']),
    weight: _nullableDecimal(json['weight']),
    weightUnitName: _text(json['weightUnitName']),
    place: _text(json['place']) ?? '—',
    confirmedBy: _text(json['confirmedBy']),
    confirmedAt: _text(json['confirmedAt']),
    warehouseId: _text(json['warehouseId']),
    warehouseName: _text(json['warehouseName']),
    actualAllocations: _allocationList(json['actualAllocations']),
    origin: _text(json['origin']) ?? 'WAREHOUSE_CONFIRM',
  );
}

/// 检查不合格的实物退回案件（V440 拒收案件在仓库侧的投影）。
class WarehouseQualityRejectionCase {
  const WarehouseQualityRejectionCase({
    required this.id,
    required this.inspectionItemId,
    required this.goodsId,
    required this.failedQty,
    required this.physicalStatus,
    required this.rowVersion,
    required this.canRecordReturn,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitName,
    this.returnReference,
    this.returnDate,
    this.returnNote,
    this.returnRecordedByName,
    this.returnRecordedAt,
    this.preStocked,
  });

  final String id;
  final String inspectionItemId;
  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitName;
  final double failedQty;
  final String physicalStatus;
  final String? returnReference;
  final String? returnDate;
  final String? returnNote;
  final String? returnRecordedByName;
  final String? returnRecordedAt;
  final int rowVersion;
  final bool canRecordReturn;

  /// 先入库后质检(V596)：不合格实物当前所在的上架仓/库位，仓库据此取货退回。
  final WarehousePreStockedLocation? preStocked;

  String get goodsLabel => [
    goodsCode,
    goodsName,
    if (colorName?.isNotEmpty == true) colorName,
  ].where((value) => value?.trim().isNotEmpty == true).join(' · ');

  String get statusLabel => switch (physicalStatus.trim().toUpperCase()) {
    'PENDING_RETURN' => '待登记退回',
    'RETURN_RECORDED' => '退回已登记',
    'VOIDED' => '来源已撤销',
    _ => physicalStatus.trim().isEmpty ? '待登记退回' : physicalStatus.trim(),
  };

  factory WarehouseQualityRejectionCase.fromJson(Map<String, dynamic> json) =>
      WarehouseQualityRejectionCase(
        id: _requiredText(json['id'], '退回案件缺少 id'),
        inspectionItemId: _requiredText(
          json['inspectionItemId'],
          '退回案件缺少 inspectionItemId',
        ),
        goodsId: _requiredText(json['goodsId'], '退回案件缺少 goodsId'),
        goodsCode: _text(json['goodsCode']),
        goodsName: _text(json['goodsName']),
        colorName: _text(json['colorName']),
        unitName: _text(json['unitName']),
        failedQty: _decimal(json['failedQty']),
        physicalStatus: _text(json['physicalStatus']) ?? 'PENDING_RETURN',
        returnReference: _text(json['returnReference']),
        returnDate: _text(json['returnDate']),
        returnNote: _text(json['returnNote']),
        returnRecordedByName: _text(json['returnRecordedByName']),
        returnRecordedAt: _text(json['returnRecordedAt']),
        preStocked: WarehousePreStockedLocation.tryParse(json['preStocked']),
        rowVersion: _integer(json['rowVersion']),
        canRecordReturn: json['canRecordReturn'] == true,
      );
}

/// 批量入库命令（跨收货单，整批同事务：任一冲突整批回滚）。
class WarehouseQualityBatchConfirmCommand {
  const WarehouseQualityBatchConfirmCommand({required this.batches});

  final List<WarehouseQualityBatchConfirmEntry> batches;

  Map<String, dynamic> toJson() => {
    'batches': [for (final entry in batches) entry.toJson()],
  };
}

class WarehouseQualityBatchConfirmEntry {
  const WarehouseQualityBatchConfirmEntry({
    required this.receiptType,
    required this.receiptId,
    required this.idempotencyKey,
    required this.items,
  });

  final String receiptType;
  final String receiptId;
  final String idempotencyKey;
  final List<WarehouseIqcStockInConfirmItem> items;

  Map<String, dynamic> toJson() => {
    'receiptType': receiptType,
    'receiptId': receiptId,
    'idempotencyKey': idempotencyKey,
    'items': [for (final item in items) item.toJson()],
  };
}

class WarehouseQualityBatchConfirmResult {
  const WarehouseQualityBatchConfirmResult({
    required this.confirmedReceipts,
    required this.confirmedItemCount,
    required this.results,
  });

  final int confirmedReceipts;
  final int confirmedItemCount;
  final List<WarehouseQualityBatchConfirmEntryResult> results;

  factory WarehouseQualityBatchConfirmResult.fromJson(
    Map<String, dynamic> json,
  ) => WarehouseQualityBatchConfirmResult(
    confirmedReceipts: _integer(json['confirmedReceipts']),
    confirmedItemCount: _integer(json['confirmedItemCount']),
    results: [
      for (final row
          in (json['results'] as List? ?? const [])
              .whereType<Map<Object?, Object?>>())
        WarehouseQualityBatchConfirmEntryResult.fromJson(
          Map<String, dynamic>.from(row),
        ),
    ],
  );
}

class WarehouseQualityBatchConfirmEntryResult {
  const WarehouseQualityBatchConfirmEntryResult({
    required this.receiptType,
    required this.receiptId,
    required this.batchId,
    required this.replayed,
    required this.confirmedCount,
    this.allocations = const [],
  });

  final String receiptType;
  final String receiptId;
  final String batchId;
  final bool replayed;
  final int confirmedCount;
  final List<WarehouseInboundAllocation> allocations;

  factory WarehouseQualityBatchConfirmEntryResult.fromJson(
    Map<String, dynamic> json,
  ) => WarehouseQualityBatchConfirmEntryResult(
    receiptType: _text(json['receiptType']) ?? '',
    receiptId: _text(json['receiptId']) ?? '',
    batchId: _text(json['batchId']) ?? '',
    replayed: json['replayed'] == true,
    confirmedCount: _integer(json['confirmedCount']),
    allocations: _allocationList(json['allocations']),
  );
}

String _requiredText(Object? value, String message) {
  final result = _text(value);
  if (result == null) throw FormatException(message);
  return result;
}

WarehouseIqcStockInReceiptType _requiredReceiptType(Object? value) {
  final result = WarehouseIqcStockInReceiptType.tryParse(value);
  if (result == null) throw const FormatException('品质检查结果来源类型无效');
  return result;
}

String? _text(Object? value) {
  if (value == null) return null;
  final result = value.toString().trim();
  return result.isEmpty ? null : result;
}

int _integer(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _decimal(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

double? _nullableDecimal(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

Set<String> _stringSet(Object? value) {
  if (value is! List) return const {};
  return {for (final item in value) ?_text(item)};
}

List<WarehouseInboundAllocation> _allocationList(Object? value) => value is List
    ? [
        for (final row in value.whereType<Map<Object?, Object?>>())
          WarehouseInboundAllocation.fromJson(Map<String, dynamic>.from(row)),
      ]
    : const [];
