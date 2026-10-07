// 生产日报 model（生产管理 · 空结构保未来）。
//
// 对应后端 server/src/main/java/com/uten/imp/features/production/dailyreport/：
//   ProductionDailyReport（头）+ ProductionDailyReportItem（明细）。
// 老库 F_DateReport 从未启用（字段类型自相矛盾，见 docs/数据迁移/23 §2.2），
// 本期建空结构保未来启用零成本（贴采购/仓库先例）。UI 完整但预期 0 行。
//
// 状态机与生产计划一致（0/1/-1），复用 production_plan.dart 的状态助手。
// JSON：camelCase；boolean isClosed/isCanceled → closed/canceled。
//
// 重新导出状态助手，方便日报页面从一处 import（plan/daily 共用 0/1/-1）。
export 'production_plan.dart'
    show
        kProductionStatusDraft,
        kProductionStatusApproved,
        kProductionStatusReversed,
        productionStatusLabel,
        productionStatusColor;

int? _asInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

List<String> _stringIds(Object? value, Object? fallback) {
  final ids = <String>[];
  final seen = <String>{};
  if (value is List) {
    for (final entry in value.whereType<String>()) {
      if (entry.isNotEmpty && seen.add(entry)) ids.add(entry);
    }
  }
  if (ids.isEmpty && fallback is String && fallback.isNotEmpty) {
    ids.add(fallback);
  }
  return List.unmodifiable(ids);
}

double? _asDouble(dynamic v) {
  if (v == null) return null;
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// 「不良数」列的说明(编辑表与详情表共用)。
const productionDailyReportDefectInfo = '只记录，不影响良品数和库存；用来算实产单耗和不良率';

/// 生产日报列表行（GET /production/daily-reports → DailyReportListItem）。
class ProductionDailyReportListItem {
  const ProductionDailyReportListItem({
    required this.id,
    this.billNo,
    this.billDate,
    this.warehouseId,
    this.departmentId,
    this.workshopName,
    this.workerId,
    this.workerIds = const [],
    this.supplierId,
    this.status,
    this.closed = false,
    this.canceled = false,
    this.legacyId,
  });

  final String id;
  final String? billNo;
  final String? billDate;
  final String? warehouseId;
  final String? departmentId;
  final String? workshopName;
  final String? workerId;

  /// 整张日报的生产参与人员。首位同时作为旧 workerId 责任人兼容值。
  /// 这里只证明整单参与，不表达行级贡献、分配权重或计件工资。
  final List<String> workerIds;
  final String? supplierId;
  final int? status;
  final bool closed;
  final bool canceled;
  final int? legacyId;

  factory ProductionDailyReportListItem.fromJson(Map<String, dynamic> json) =>
      ProductionDailyReportListItem(
        id: json['id'] as String,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        warehouseId: json['warehouseId'] as String?,
        departmentId: json['departmentId'] as String?,
        workshopName: json['workshopName'] as String?,
        workerId: json['workerId'] as String?,
        workerIds: _stringIds(json['workerIds'], json['workerId']),
        supplierId: json['supplierId'] as String?,
        status: _asInt(json['status']),
        closed: (json['closed'] as bool?) ?? false,
        canceled: (json['canceled'] as bool?) ?? false,
        legacyId: _asInt(json['legacyId']),
      );
}

/// 生产日报明细行（DailyReportItemDto）。
class ProductionDailyReportItem {
  const ProductionDailyReportItem({
    required this.id,
    this.lineNo,
    this.goodsId,
    this.colorId,
    this.unitId,
    this.unitRate,
    this.qty,
    this.defectQty = 0,
    this.price,
    this.total,
    this.stotal,
    this.salesOrderItemId,
    this.salesOrderNo,
    this.planItemId,
    this.planId,
    this.remainingPlanQty,
    this.executionSegmentId,
    this.executionSegmentSalesAllocationId,
    this.fqcRecoveryAuthorizationId,
    this.planNo,
    this.outboundNo,
    this.outboundQty,
    this.orderQty,
    this.stepLegacyId,
    this.orderDate,
    this.boxes,
    this.perBoxQty,
    this.weight,
    this.clientName,
    this.sourceDocNo,
    this.remark,
    this.isFinal = false,
    this.destination,
    this.directTransferDemandId,
    this.directTransferTargetLabel,
    this.outputRouteReason,
    this.outputRouteReasonText,
    this.goodsName,
    this.goodsCode,
    this.colorName,
    this.unitName,
    this.allowActualOverproduction = false,
    this.outputBatchId,
    this.outputBatchQty,
    this.publicOutput = false,
    this.actualSurplus = false,
    this.overLimit = false,
    this.overLimitReason,
    this.dispositionId,
    this.outputKind,
    this.supplementProofId,
    this.outputSourceExecutionSegmentId,
    this.outputSourcePlanItemId,
    this.outputSourcePlanId,
    this.outputSourcePlanNo,
    this.outputSourceSalesAllocationId,
    this.outputSourceSalesOrderItemId,
  });

  final String id;
  final int? lineNo;
  final String? goodsId;
  final String? colorId;
  final String? unitId;
  final double? unitRate;
  final double? qty; // 完工量

  /// 不良数(ADR-129)：只记录，不影响良品数、库存与产量分流；用来算实产单耗和不良率。
  /// 一次报工拆成多条明细时只记在第一条上，其余为 0。
  final double defectQty;
  final double? price;
  final double? total; // 金额
  final double? stotal; // 成本金额
  final String? salesOrderItemId;
  final String? salesOrderNo;
  final String? planItemId; // → production_plan_items.id
  final String? planId;
  final double? remainingPlanQty;
  final String? executionSegmentId; // → production_execution_segments.id
  final String? executionSegmentSalesAllocationId;
  final String? fqcRecoveryAuthorizationId;
  final String? planNo;
  final String? outboundNo;
  final double? outboundQty;
  final double? orderQty;
  final int? stepLegacyId;
  final String? orderDate;
  final double? boxes;
  final double? perBoxQty;
  final double? weight;
  final String? clientName;
  final String? sourceDocNo;
  final String? remark;

  /// 本批普通完工申报终结；不代表品质合格，后续按 FQC 结果封顶、恢复或补产。
  final bool isFinal;

  /// 产出去向(V584)：'WAREHOUSE' 送入仓库 / 'WORKSHOP' 转下一道工序；老单为空按送仓库。
  final String? destination;

  /// 直送的接收需求(V585)；送仓库行为空。
  final String? directTransferDemandId;

  /// 直送接收方的可读标识(V595)：父件产品名 编号 · 工单号。
  final String? directTransferTargetLabel;

  /// 送仓明细为什么没转下一道工序(V736 原因码)；转送明细与历史明细为空。只用于判断。
  final String? outputRouteReason;

  /// 上面原因的大白话(服务端唯一文案)，详情页与审核确认直接显示。
  final String? outputRouteReasonText;

  /// 货品身份三列与单位由服务端随单解析下发，页面不再查字典缓存。
  /// 客户端字典会随连接恢复或权限快照变化整体清空，那时逐格解析会集体变「—」且不自愈。
  final String? goodsName;
  final String? goodsCode;
  final String? colorName;
  final String? unitName;
  final bool allowActualOverproduction;
  final String? outputBatchId;
  final double? outputBatchQty;
  final bool publicOutput;
  final bool actualSurplus;
  final bool overLimit;
  final String? overLimitReason;
  final String? dispositionId;
  final String? outputKind;
  final String? supplementProofId;
  final String? outputSourceExecutionSegmentId;
  final String? outputSourcePlanItemId;
  final String? outputSourcePlanId;
  final String? outputSourcePlanNo;
  final String? outputSourceSalesAllocationId;
  final String? outputSourceSalesOrderItemId;

  String get outputKindLabel => switch (outputKind) {
    'PLANNED' => '需求产出',
    'PLANNED_PUBLIC' => '计划公共备货',
    'ACTUAL_SURPLUS' => '实际超产 · 公共备货',
    'OVER_LIMIT' => '超限产出',
    _ => publicOutput ? '公共备货' : '原来源',
  };

  bool get isDirectTransfer => destination == 'WORKSHOP';

  factory ProductionDailyReportItem.fromJson(Map<String, dynamic> json) =>
      ProductionDailyReportItem(
        destination: json['destination'] as String?,
        directTransferDemandId: json['directTransferDemandId'] as String?,
        directTransferTargetLabel: json['directTransferTargetLabel'] as String?,
        outputRouteReason: json['outputRouteReason'] as String?,
        outputRouteReasonText: json['outputRouteReasonText'] as String?,
        id: json['id'] as String,
        lineNo: _asInt(json['lineNo']),
        goodsId: json['goodsId'] as String?,
        colorId: json['colorId'] as String?,
        unitId: json['unitId'] as String?,
        unitRate: _asDouble(json['unitRate']),
        qty: _asDouble(json['qty']),
        defectQty: _asDouble(json['defectQty']) ?? 0,
        price: _asDouble(json['price']),
        total: _asDouble(json['total']),
        stotal: _asDouble(json['stotal']),
        salesOrderItemId: json['salesOrderItemId'] as String?,
        salesOrderNo: json['salesOrderNo'] as String?,
        planItemId: json['planItemId'] as String?,
        planId: json['planId'] as String?,
        remainingPlanQty: _asDouble(json['remainingPlanQty']),
        executionSegmentId: json['executionSegmentId'] as String?,
        executionSegmentSalesAllocationId:
            json['executionSegmentSalesAllocationId'] as String?,
        fqcRecoveryAuthorizationId:
            json['fqcRecoveryAuthorizationId'] as String?,
        planNo: json['planNo'] as String?,
        outboundNo: json['outboundNo'] as String?,
        outboundQty: _asDouble(json['outboundQty']),
        orderQty: _asDouble(json['orderQty']),
        stepLegacyId: _asInt(json['stepLegacyId']),
        orderDate: json['orderDate'] as String?,
        boxes: _asDouble(json['boxes']),
        perBoxQty: _asDouble(json['perBoxQty']),
        weight: _asDouble(json['weight']),
        clientName: json['clientName'] as String?,
        sourceDocNo: json['sourceDocNo'] as String?,
        remark: json['remark'] as String?,
        isFinal: json['isFinal'] == true,
        goodsName: json['goodsName'] as String?,
        goodsCode: json['goodsCode'] as String?,
        colorName: json['colorName'] as String?,
        unitName: json['unitName'] as String?,
        allowActualOverproduction: json['allowActualOverproduction'] == true,
        outputBatchId: json['outputBatchId'] as String?,
        outputBatchQty: _asDouble(json['outputBatchQty']),
        publicOutput: json['publicOutput'] == true,
        actualSurplus: json['actualSurplus'] == true,
        overLimit: json['overLimit'] == true,
        overLimitReason: json['overLimitReason'] as String?,
        dispositionId: json['dispositionId'] as String?,
        outputKind: json['outputKind'] as String?,
        supplementProofId: json['supplementProofId'] as String?,
        outputSourceExecutionSegmentId:
            json['outputSourceExecutionSegmentId'] as String?,
        outputSourcePlanItemId: json['outputSourcePlanItemId'] as String?,
        outputSourcePlanId: json['outputSourcePlanId'] as String?,
        outputSourcePlanNo: json['outputSourcePlanNo'] as String?,
        outputSourceSalesAllocationId:
            json['outputSourceSalesAllocationId'] as String?,
        outputSourceSalesOrderItemId:
            json['outputSourceSalesOrderItemId'] as String?,
      );
}

/// 保存后的需求/公共切片在编辑时还原为一次实际申报，避免再报一份超产。
/// 分组只认服务端给的产出批次(ProductionDailyReportDetail.outputBatches)，页面不再自己拼组。
class ProductionDailyReportInputGroup {
  ProductionDailyReportInputGroup(List<ProductionDailyReportItem> items)
    : items = List.unmodifiable(items);

  final List<ProductionDailyReportItem> items;
  ProductionDailyReportItem get source =>
      items.firstWhere((item) => !item.publicOutput, orElse: () => items.first);
  double? get qty => source.outputBatchQty ?? source.qty;
  String? get overLimitReason => items
      .where((item) => item.overLimitReason?.trim().isNotEmpty == true)
      .map((item) => item.overLimitReason)
      .firstOrNull;

  /// 整次报工的不良数：服务端只让同一批次的第一条明细带不良数，合计即原输入。
  double get defectQty =>
      items.fold<double>(0, (sum, item) => sum + item.defectQty);
  bool get supplementBatch =>
      source.supplementProofId != null &&
      source.fqcRecoveryAuthorizationId == null;
  String? get planId =>
      supplementBatch ? source.outputSourcePlanId : source.planId;
  String? get planItemId =>
      supplementBatch ? source.outputSourcePlanItemId : source.planItemId;
  String? get executionSegmentId => supplementBatch
      ? source.outputSourceExecutionSegmentId
      : source.executionSegmentId;
  String? get allocationId => supplementBatch
      ? source.outputSourceSalesAllocationId
      : source.executionSegmentSalesAllocationId;
  String? get salesOrderItemId => supplementBatch
      ? source.outputSourceSalesOrderItemId
      : source.salesOrderItemId;
  String? get planNo => supplementBatch
      ? source.outputSourcePlanNo ??
            (source.planId == planId ? source.planNo : null)
      : source.planNo;
  double? get weight {
    final weights = items.map((item) => item.weight).whereType<double>();
    return weights.isEmpty ? null : weights.fold<double>(0, (a, b) => a + b);
  }

  /// 本批产出的去向(与提交体同形 `{directTransferDemandId, qty}`)：每个上层工单一条，
  /// 送入仓库的部分(需求份、公共备货、实际超产)合成一条(V736/ADR-127)。
  List<Map<String, dynamic>> get allocations {
    final direct = <String, double>{};
    var warehouse = 0.0;
    for (final item in items) {
      final qty = item.qty ?? 0;
      final demand = item.directTransferDemandId;
      if (item.isDirectTransfer && demand != null) {
        direct[demand] = (direct[demand] ?? 0) + qty;
      } else {
        warehouse += qty;
      }
    }
    return [
      for (final entry in direct.entries)
        {'directTransferDemandId': entry.key, 'qty': entry.value},
      if (warehouse > 0) {'directTransferDemandId': null, 'qty': warehouse},
    ];
  }
}

/// 一次录入的实际产出批次(ADR-148，服务端 DailyReportOutputBatch)：报工页一行 = 一批。
/// 服务端按库里的实物交接批分好去向组并拼好审核摘要，页面直接显示，不再自己拼。
class ProductionDailyReportOutputBatch {
  const ProductionDailyReportOutputBatch({
    required this.batchKey,
    required this.itemIds,
    required this.qty,
    required this.summary,
    this.sourceItemId,
    this.groups = const [],
  });

  /// 产出批次号(没拆分的行 = 行 id)。
  final String batchKey;

  /// 本批第一份(行号最小)的报工行。
  final String? sourceItemId;

  /// 本批全部份(按行号)：草稿恢复按它把同批各份合回一行。
  final List<String> itemIds;
  final double qty;

  /// 「货品 共 1100：送入仓库 1100(其中实际超产 100)」。
  final String summary;
  final List<ProductionDailyReportOutputGroup> groups;

  factory ProductionDailyReportOutputBatch.fromJson(
    Map<String, dynamic> json,
  ) => ProductionDailyReportOutputBatch(
    batchKey: json['batchKey'] as String? ?? '',
    sourceItemId: json['sourceItemId'] as String?,
    itemIds: [
      for (final id in json['itemIds'] as List? ?? const [])
        if (id is String) id,
    ],
    qty: _asDouble(json['qty']) ?? 0,
    summary: json['summary'] as String? ?? '',
    groups:
        (json['groups'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ProductionDailyReportOutputGroup.fromJson)
            .toList(growable: false) ??
        const [],
  );
}

/// 同一产出批次、同一去向、同一接收方的各份(一个实物交接批)。
class ProductionDailyReportOutputGroup {
  const ProductionDailyReportOutputGroup({
    required this.itemIds,
    required this.qty,
    required this.summary,
    this.lotId,
    this.destination,
    this.directTransferDemandId,
    this.receiverLabel,
    this.demandQty = 0,
    this.publicQty = 0,
    this.actualSurplusQty = 0,
    this.splitText,
    this.reasonText,
  });

  final String? lotId;
  final List<String> itemIds;

  /// WAREHOUSE 送入仓库 / WORKSHOP 转给上层工单。
  final String? destination;
  final String? directTransferDemandId;
  final String? receiverLabel;
  final double qty;
  final double demandQty;
  final double publicQty;
  final double actualSurplusQty;

  /// 「需求 1000 · 实际超产 100」；整批都是需求份时为空。
  final String? splitText;

  /// 需求份送入仓库的原因(大白话)；没有时为空。
  final String? reasonText;
  final String summary;

  factory ProductionDailyReportOutputGroup.fromJson(
    Map<String, dynamic> json,
  ) => ProductionDailyReportOutputGroup(
    lotId: json['lotId'] as String?,
    itemIds: [
      for (final id in json['itemIds'] as List? ?? const [])
        if (id is String) id,
    ],
    destination: json['destination'] as String?,
    directTransferDemandId: json['directTransferDemandId'] as String?,
    receiverLabel: json['receiverLabel'] as String?,
    qty: _asDouble(json['qty']) ?? 0,
    demandQty: _asDouble(json['demandQty']) ?? 0,
    publicQty: _asDouble(json['publicQty']) ?? 0,
    actualSurplusQty: _asDouble(json['actualSurplusQty']) ?? 0,
    splitText: json['splitText'] as String?,
    reasonText: json['reasonText'] as String?,
    summary: json['summary'] as String? ?? '',
  );
}

/// 生产日报详情（GET /production/daily-reports/{id} → DailyReportDetail）。
class ProductionDailyReportDetail {
  const ProductionDailyReportDetail({
    required this.id,
    this.legacyId,
    this.billNo,
    this.billDate,
    this.warehouseId,
    this.departmentId,
    this.workshopName,
    this.workerId,
    this.workerIds = const [],
    this.supplierId,
    this.makerId,
    this.approverId,
    this.makerName,
    this.createdAt,
    this.makerLegacyId,
    this.approverLegacyId,
    this.remark,
    this.status,
    this.closed = false,
    this.canceled = false,
    this.sourceDocNo,
    this.rowVersion = 0,
    this.rowVersionAvailable = false,
    this.approvalCommandVersion,
    this.approvalCapabilityMalformed = false,
    this.approvalReceipt,
    this.items = const [],
    this.outputBatches = const [],
    this.materialUsages = const [],
    this.surplusReturnRequested = false,
    this.departmentName,
    this.workerNames = const [],
    this.allowedActions = const {},
  });

  final String id;
  final int? legacyId;
  final String? billNo;
  final String? billDate;
  final String? warehouseId;
  final String? departmentId;
  final String? workshopName;
  final String? workerId;

  /// 当前账号对这张日报能做的动作(服务端按权限码 + 对象范围 + 状态 + 车间直送审核权
  /// 一次算好)；按钮只按它显隐，页面不再本地拼权限。目前只下发 [approveAction]。
  final Set<String> allowedActions;

  static const approveAction = 'APPROVE';

  bool get canApprove => allowedActions.contains(approveAction);

  /// 整张日报的生产参与人员；不证明行级贡献或计件工资归属。
  final List<String> workerIds;
  final String? supplierId;
  final String? makerId;
  final String? approverId;

  /// 制单员姓名（服务端解析；只读展示，不可修改）
  final String? makerName;

  /// 制单时间 ISO（审计 created_at，创建后不可变）
  final String? createdAt;
  final int? makerLegacyId;
  final int? approverLegacyId;
  final String? remark;
  final int? status;
  final bool closed;
  final bool canceled;
  final String? sourceDocNo;
  final int rowVersion;

  /// The editing fallback value must not impersonate a server-provided approval version.
  final bool rowVersionAvailable;
  final int? approvalCommandVersion;
  final bool approvalCapabilityMalformed;
  final ProductionDailyReportApprovalReceipt? approvalReceipt;

  bool get supportsReviewedApproval =>
      !approvalCapabilityMalformed && approvalCommandVersion == 2;
  bool get supportsLegacyApproval =>
      !approvalCapabilityMalformed &&
      (approvalCommandVersion == null || approvalCommandVersion == 1);
  bool get canFreezeReviewedApproval =>
      supportsReviewedApproval && rowVersionAvailable && rowVersion >= 0;
  final List<ProductionDailyReportItem> items;

  /// ADR-148：服务端按一次录入的产出批次分好的组与审核摘要(报工页一行 = 一批)。
  final List<ProductionDailyReportOutputBatch> outputBatches;

  /// 草稿恢复：每个产出批次的各份合回一行(一次实际申报)。服务端给的份缺了就拒绝恢复。
  List<ProductionDailyReportInputGroup> get inputGroups {
    final byId = {for (final item in items) item.id: item};
    return [
      for (final batch in outputBatches)
        if (batch.itemIds.isNotEmpty)
          ProductionDailyReportInputGroup([
            for (final id in batch.itemIds)
              byId[id] ?? (throw const FormatException('报工分流明细不完整，请重新读取草稿')),
          ]),
    ];
  }

  /// V583 报工同页登记的本次实际用料；历史日报为空。
  final List<ProductionDailyReportMaterialUsage> materialUsages;

  /// 收尾余料退仓意愿；审核时先结实耗再按剩余可退量开退料单。
  final bool surplusReturnRequested;

  /// 车间名(服务端按 departmentId 解析)；页面不再查部门字典。
  final String? departmentName;

  /// 生产参与人员姓名，顺序与 [workerIds] 一一对应；页面不再逐个调员工档案接口。
  final List<String> workerNames;

  factory ProductionDailyReportDetail.fromJson(
    Map<String, dynamic> json,
  ) => ProductionDailyReportDetail(
    id: json['id'] as String,
    legacyId: _asInt(json['legacyId']),
    billNo: json['billNo'] as String?,
    billDate: json['billDate'] as String?,
    warehouseId: json['warehouseId'] as String?,
    departmentId: json['departmentId'] as String?,
    workshopName: json['workshopName'] as String?,
    workerId: json['workerId'] as String?,
    workerIds: _stringIds(json['workerIds'], json['workerId']),
    supplierId: json['supplierId'] as String?,
    makerId: json['makerId'] as String?,
    makerName: json['makerName'] as String?,
    createdAt: json['createdAt'] as String?,
    approverId: json['approverId'] as String?,
    makerLegacyId: _asInt(json['makerLegacyId']),
    approverLegacyId: _asInt(json['approverLegacyId']),
    remark: json['remark'] as String?,
    status: _asInt(json['status']),
    closed: (json['closed'] as bool?) ?? false,
    canceled: (json['canceled'] as bool?) ?? false,
    sourceDocNo: json['sourceDocNo'] as String?,
    rowVersion: _asInt(json['rowVersion']) ?? 0,
    rowVersionAvailable:
        json['rowVersion'] is int && (json['rowVersion'] as int) >= 0,
    approvalCommandVersion: _asInt(json['approvalCommandVersion']),
    approvalCapabilityMalformed:
        json['approvalCommandVersion'] != null &&
        (json['approvalCommandVersion'] is! int ||
            (json['approvalCommandVersion'] as int) < 1),
    approvalReceipt: json['approvalReceipt'] is Map
        ? ProductionDailyReportApprovalReceipt.fromJson(
            Map<String, dynamic>.from(json['approvalReceipt'] as Map),
          )
        : null,
    items:
        (json['items'] as List?)
            ?.map(
              (e) =>
                  ProductionDailyReportItem.fromJson(e as Map<String, dynamic>),
            )
            .toList() ??
        const [],
    outputBatches:
        (json['outputBatches'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ProductionDailyReportOutputBatch.fromJson)
            .toList(growable: false) ??
        const [],
    materialUsages:
        (json['materialUsages'] as List?)
            ?.map(
              (e) => ProductionDailyReportMaterialUsage.fromJson(
                e as Map<String, dynamic>,
              ),
            )
            .toList() ??
        const [],
    surplusReturnRequested: json['surplusReturnRequested'] == true,
    departmentName: json['departmentName'] as String?,
    workerNames:
        (json['workerNames'] as List?)
            ?.map((e) => e?.toString() ?? '')
            .toList() ??
        const [],
    allowedActions: {
      for (final action in (json['allowedActions'] as List? ?? const []))
        if (action is String) action,
    },
  );
}

class ProductionDailyReportApprovalReceipt {
  const ProductionDailyReportApprovalReceipt({
    required this.reportId,
    required this.idempotencyKey,
    required this.commandVersion,
    required this.reviewedVersion,
    required this.replay,
    this.metadataMalformed = false,
    this.reviewProtection,
  });
  final String reportId;
  final String idempotencyKey;
  final int? commandVersion;
  final int? reviewedVersion;
  final bool replay;
  final bool metadataMalformed;
  final String? reviewProtection;

  bool get legacy => commandVersion == null || commandVersion == 1;
  bool get valid =>
      !metadataMalformed &&
      reportId.isNotEmpty &&
      idempotencyKey.isNotEmpty &&
      (legacy
          ? reviewedVersion == null &&
                (reviewProtection == null ||
                    reviewProtection == 'LEGACY_UNVERSIONED')
          : commandVersion == 2 &&
                reviewedVersion != null &&
                reviewedVersion! >= 0 &&
                (reviewProtection == null ||
                    reviewProtection == 'REVIEWED_VERSION'));

  factory ProductionDailyReportApprovalReceipt.fromJson(
    Map<String, dynamic> json,
  ) {
    bool invalidInteger(Object? value) =>
        value != null && (value is! int || value < 0);
    return ProductionDailyReportApprovalReceipt(
      reportId: json['reportId'] as String? ?? '',
      idempotencyKey: json['idempotencyKey'] as String? ?? '',
      commandVersion: _asInt(json['commandVersion']),
      reviewedVersion: _asInt(json['reviewedVersion']),
      replay: json['replay'] == true,
      reviewProtection: json['reviewProtection'] as String?,
      metadataMalformed:
          invalidInteger(json['commandVersion']) ||
          invalidInteger(json['reviewedVersion']),
    );
  }
}

class ProductionDailyReportApprovalResolution {
  const ProductionDailyReportApprovalResolution({
    required this.status,
    this.receipt,
    this.detail,
  });
  final String status;
  final ProductionDailyReportApprovalReceipt? receipt;
  final ProductionDailyReportDetail? detail;

  factory ProductionDailyReportApprovalResolution.fromJson(
    Map<String, dynamic> json,
  ) => ProductionDailyReportApprovalResolution(
    status: json['status'] as String? ?? 'UNCONFIRMED',
    receipt: json['receipt'] is Map
        ? ProductionDailyReportApprovalReceipt.fromJson(
            Map<String, dynamic>.from(json['receipt'] as Map),
          )
        : null,
    detail: json['detail'] is Map
        ? ProductionDailyReportDetail.fromJson(
            Map<String, dynamic>.from(json['detail'] as Map),
          )
        : null,
  );
}

/// 日报上已登记的一条本次实际用料(V583)。草稿阶段只是事实，审核才转成材料消耗。
class ProductionDailyReportMaterialUsage {
  const ProductionDailyReportMaterialUsage({
    required this.demandId,
    required this.qtyBase,
    this.id,
    this.lineNo,
    this.planId,
    this.materialExecutionSegmentId,
    this.materialExecutionSegmentCode,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitName,
    this.countedLeftoverQty,
  });

  final String? id;
  final int? lineNo;
  final String? planId;
  final String demandId;
  final String? materialExecutionSegmentId;
  final String? materialExecutionSegmentCode;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitName;
  final double qtyBase;

  /// 最后一次报工按实物清点的实际剩余(基本单位，ADR-129 §2.7)；没清点为 null。
  final double? countedLeftoverQty;

  factory ProductionDailyReportMaterialUsage.fromJson(
    Map<String, dynamic> json,
  ) => ProductionDailyReportMaterialUsage(
    id: json['id'] as String?,
    lineNo: _asInt(json['lineNo']),
    planId: json['planId'] as String?,
    demandId: json['demandId'] as String,
    materialExecutionSegmentId: json['materialExecutionSegmentId'] as String?,
    materialExecutionSegmentCode:
        json['materialExecutionSegmentCode'] as String?,
    goodsId: json['goodsId'] as String?,
    goodsCode: json['goodsCode'] as String?,
    goodsName: json['goodsName'] as String?,
    colorName: json['colorName'] as String?,
    unitName: json['unitName'] as String?,
    qtyBase: (json['qtyBase'] as num?)?.toDouble() ?? 0,
    countedLeftoverQty: (json['countedLeftoverQty'] as num?)?.toDouble(),
  );
}
