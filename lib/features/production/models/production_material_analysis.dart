// Pre-plan material analysis contracts.
//
// The server is authoritative for BOM expansion, stock allocation and ready
// quantities. These models intentionally parse returned facts only; the
// Flutter client never derives availability from inventory fields.

import '../../../shared/models/progress_ratio.dart';

enum MaterialSupplyRoute {
  make('MAKE', '自制'),
  buy('BUY', '采购'),
  subcontract('SUBCONTRACT', '委外');

  const MaterialSupplyRoute(this.wireName, this.label);

  final String wireName;
  final String label;

  static MaterialSupplyRoute? fromWire(Object? value) {
    final text = value?.toString().trim().toUpperCase();
    for (final route in values) {
      if (route.wireName == text) return route;
    }
    return null;
  }
}

/// 货品一个颜色+单位维度的最近确认路线（/last-routes 学习预填用）。
class MaterialRouteMemory {
  const MaterialRouteMemory({
    required this.route,
    this.colorId,
    this.unitId,
    this.reason,
  });

  final MaterialSupplyRoute route;
  final String? colorId;
  final String? unitId;
  final String? reason;

  static MaterialRouteMemory fromJson(Map<String, dynamic> json) {
    return MaterialRouteMemory(
      route: MaterialSupplyRoute.fromWire(json['route'])!,
      colorId: json['colorId'] as String?,
      unitId: json['unitId'] as String?,
      reason: json['reason'] as String?,
    );
  }
}

/// 服务端权威的逐 BOM 路径需求激活状态。
///
/// `requiredQty == 0` 不能再被客户端统一解释成“无需补货”：它可能是上级
/// 路线截断、参考节点、已经转入正式计划，或已由 MAKE_COMPONENT child
/// 接管。客户端只解析并展示该投影，不根据树形或路线自行猜测所有权。
enum MaterialRequirementState {
  active('ACTIVE'),
  delegatedToMakeChild('DELEGATED_TO_MAKE_CHILD'),
  delegatedToSubcontractPreparation('DELEGATED_TO_SUBCONTRACT_PREPARATION'),
  inactiveParentCovered('INACTIVE_PARENT_COVERED'),
  inactiveParentRoute('INACTIVE_PARENT_ROUTE'),
  inactiveReference('INACTIVE_REFERENCE'),
  transferredToPlan('TRANSFERRED_TO_PLAN'),
  inactive('INACTIVE');

  const MaterialRequirementState(this.wireName);

  final String wireName;

  static MaterialRequirementState? fromWire(Object? value) {
    final text = value?.toString().trim().toUpperCase();
    for (final state in values) {
      if (state.wireName == text) return state;
    }
    return null;
  }
}

class MaterialAnalysisSourceInput {
  const MaterialAnalysisSourceInput({
    this.salesOrderItemId,
    this.sourceType,
    this.sourceRef,
    this.goodsId,
    this.colorId,
    this.unitId,
    required this.requestedQty,
    this.sourceReason,
    this.deliveryDate,
    this.initialProductNo,
  });

  final String? salesOrderItemId;
  final String? sourceType;
  final String? sourceRef;
  final String? goodsId;
  final String? colorId;
  final String? unitId;
  final double requestedQty;
  final String? sourceReason;
  final String? deliveryDate;

  /// Route-local seed for the subsequent production-plan wizard. It is not a
  /// material-analysis source field and therefore is intentionally omitted
  /// from [toJson].
  final String? initialProductNo;

  bool get isSalesSource => salesOrderItemId?.isNotEmpty == true;
  String get canonicalKey =>
      salesOrderItemId ??
      '${sourceType ?? 'MANUAL'}|${sourceRef ?? ''}|${goodsId ?? ''}|${colorId ?? ''}|${unitId ?? ''}';

  Map<String, dynamic> toJson() => {
    if (salesOrderItemId != null) 'salesOrderItemId': salesOrderItemId,
    if (sourceType != null) 'sourceType': sourceType,
    if (sourceRef != null) 'sourceRef': sourceRef,
    if (goodsId != null) 'goodsId': goodsId,
    if (colorId != null) 'colorId': colorId,
    if (unitId != null) 'unitId': unitId,
    'requestedQty': requestedQty,
    if (sourceReason != null) 'sourceReason': sourceReason,
    if (deliveryDate != null) 'deliveryDate': deliveryDate,
  };
}

/// Route state passed from the scheduling board to the independent analysis
/// page. [analysisId]/[analysisVersion] are optional so an existing analysis
/// can be refreshed using the same preview endpoint.
class ProductionMaterialAnalysisSeed {
  const ProductionMaterialAnalysisSeed({
    this.analysisId,
    this.analysisVersion,
    this.warehouseId,
    this.warehouseIds = const [],
    this.billDate,
    this.deliveryDate,
    this.departmentId,
    this.workshopName,
    this.workerId,
    this.sources = const [],
  });

  final String? analysisId;
  final int? analysisVersion;
  final String? warehouseId;
  final List<String> warehouseIds;
  final String? billDate;
  final String? deliveryDate;
  final String? departmentId;
  final String? workshopName;
  final String? workerId;
  final List<MaterialAnalysisSourceInput> sources;

  /// Resolves the route-local product number seed back to the analysis product
  /// created from the same source. Sales lines use their immutable item UUID;
  /// manual demand uses the same composite source identity as the backend.
  String? initialProductNoFor(ProductionMaterialAnalysisProduct product) {
    for (final source in sources) {
      final productNo = _trimmedOrNull(source.initialProductNo);
      if (productNo == null) continue;

      final productSalesItemId = _trimmedOrNull(product.salesOrderItemId);
      final sourceSalesItemId = _trimmedOrNull(source.salesOrderItemId);
      if (productSalesItemId != null) {
        if (_sameSourcePart(
          sourceSalesItemId,
          productSalesItemId,
          foldCase: true,
        )) {
          return productNo;
        }
        continue;
      }
      if (sourceSalesItemId != null) continue;

      if (_sameSourcePart(
            source.sourceType,
            product.sourceType,
            foldCase: true,
          ) &&
          _sameSourcePart(
            source.sourceRef,
            product.sourceRef,
            foldCase: true,
          ) &&
          _sameSourcePart(source.goodsId, product.goodsId, foldCase: true) &&
          _sameSourcePart(source.colorId, product.colorId, foldCase: true) &&
          _sameSourcePart(source.unitId, product.unitId, foldCase: true)) {
        return productNo;
      }
    }
    return null;
  }
}

class MaterialAnalysisSalesCandidatePage {
  const MaterialAnalysisSalesCandidatePage({
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
  });

  final List<MaterialAnalysisSalesCandidate> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;

  List<MaterialAnalysisSalesCandidateLine> get lines => [
    for (final order in items)
      for (final line in order.lines) line.withOrder(order),
  ];

  factory MaterialAnalysisSalesCandidatePage.fromJson(
    Map<String, dynamic> json,
  ) => MaterialAnalysisSalesCandidatePage(
    items: _mapList(json['items'], MaterialAnalysisSalesCandidate.fromJson),
    page: _int(json['page']) ?? 1,
    size: _int(json['size']) ?? 20,
    total: _int(json['totalElements'] ?? json['total']) ?? 0,
    totalPages: _int(json['totalPages']) ?? 0,
  );
}

/// Object-scoped material-analysis task/history row.
///
/// Quantities are persisted server projections. The client only formats them
/// and never recomputes readiness from warehouse data.
class MaterialAnalysisListItem {
  const MaterialAnalysisListItem({
    required this.analysisId,
    required this.status,
    required this.version,
    this.fingerprint,
    this.warehouseId,
    this.warehouseCode,
    this.warehouseName,
    this.analyzedAt,
    this.updatedAt,
    this.makerId,
    this.makerName,
    this.sourceCount = 0,
    this.sourceTypes = const [],
    this.sourceRefs = const [],
    this.productLabels = const [],
    this.requestedQty = 0,
    this.submittedQty = 0,
    this.approvedQty = 0,
    this.remainingQty = 0,
    this.readyNowQty = 0,
    this.readyByDateQty = 0,
  });

  final String analysisId;
  final String status;
  final int version;
  final String? fingerprint;
  final String? warehouseId;
  final String? warehouseCode;
  final String? warehouseName;
  final String? analyzedAt;
  final String? updatedAt;
  final String? makerId;
  final String? makerName;
  final int sourceCount;
  final List<String> sourceTypes;
  final List<String> sourceRefs;
  final List<String> productLabels;
  final double requestedQty;
  final double submittedQty;
  final double approvedQty;
  final double remainingQty;
  final double readyNowQty;
  final double readyByDateQty;

  factory MaterialAnalysisListItem.fromJson(Map<String, dynamic> json) =>
      MaterialAnalysisListItem(
        analysisId: _string(json['analysisId'] ?? json['id']) ?? '',
        status: _string(json['status']) ?? 'UNKNOWN',
        version: _int(json['version']) ?? 0,
        fingerprint: _string(json['fingerprint']),
        warehouseId: _string(json['warehouseId']),
        warehouseCode: _string(json['warehouseCode']),
        warehouseName: _string(json['warehouseName']),
        analyzedAt: _string(json['analyzedAt']),
        updatedAt: _string(json['updatedAt'] ?? json['analyzedAt']),
        makerId: _string(json['makerId']),
        makerName: _string(json['makerName']),
        sourceCount: _int(json['sourceCount']) ?? 0,
        sourceTypes: _stringList(json['sourceTypes']),
        sourceRefs: _stringList(json['sourceRefs']),
        productLabels: _stringList(json['productLabels']),
        requestedQty: _double(json['requestedQty']) ?? 0,
        submittedQty: _double(json['submittedQty']) ?? 0,
        approvedQty: _double(json['approvedQty']) ?? 0,
        remainingQty: _double(json['remainingQty']) ?? 0,
        readyNowQty: _double(json['readyNowQty']) ?? 0,
        readyByDateQty: _double(json['readyByDateQty']) ?? 0,
      );
}

/// One production-owned task that prepares a subcontract target item before
/// warehouse outbound.
///
/// The server owns the state, blocker, allowed actions, target warehouse and
/// all quantities. Flutter must not inspect the BOM or infer readiness locally.
class SubcontractMakeTask {
  const SubcontractMakeTask({
    required this.taskId,
    required this.analysisId,
    required this.status,
    this.preparationItemId,
    this.analysisStatus,
    this.itemSourceRef,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitName,
    this.warehouseName,
    this.requiredQty = 0,
    this.producedQty = 0,
    this.notifiedQty = 0,
    this.availableQty = 0,
    this.plannedQty = 0,
    this.needDate,
    this.allowedActions = const {},
    this.updatedAt,
  });

  final String taskId;
  final String analysisId;
  final String status;

  /// 对应 SUBCONTRACT_MAKE 分析行 id（preparation_item_id）——物料分析页
  /// 用它把任务精确挂回自己的产品卡，不按货号猜。
  final String? preparationItemId;
  final String? analysisStatus;
  final String? itemSourceRef;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitName;
  final String? warehouseName;

  /// 需求量 / 已产未通知口径（服务端账本权威）。
  final double requiredQty;
  final double producedQty;
  final double notifiedQty;
  final double availableQty;
  final double plannedQty;
  final String? needDate;
  final Set<String> allowedActions;
  final String? updatedAt;

  bool allows(String action) => allowedActions.contains(action);

  String get goodsLabel {
    final code = goodsCode ?? '';
    final name = goodsName ?? '';
    return '$code $name'.trim();
  }

  factory SubcontractMakeTask.fromJson(Map<String, dynamic> json) =>
      SubcontractMakeTask(
        taskId: _string(json['taskId']) ?? '',
        analysisId: _string(json['analysisId']) ?? '',
        preparationItemId: _string(json['preparationItemId']),
        analysisStatus: _string(json['analysisStatus']),
        itemSourceRef: _string(json['itemSourceRef']),
        goodsId: _string(json['goodsId']),
        goodsCode: _string(json['goodsCode']),
        goodsName: _string(json['goodsName']),
        colorName: _string(json['colorName']),
        unitName: _string(json['unitName']),
        warehouseName: _string(json['warehouseName']),
        requiredQty: _double(json['requiredQty']) ?? 0,
        producedQty: _double(json['producedQty']) ?? 0,
        notifiedQty: _double(json['notifiedQty']) ?? 0,
        availableQty: _double(json['availableQty']) ?? 0,
        plannedQty: _double(json['plannedQty']) ?? 0,
        needDate: _string(json['needDate']),
        status: (_string(json['status']) ?? 'UNKNOWN').toUpperCase(),
        allowedActions: _stringList(json['allowedActions']).toSet(),
        updatedAt: _string(json['updatedAt']),
      );
}

class SubcontractMakeNotifyResult {
  const SubcontractMakeNotifyResult({
    required this.taskId,
    required this.applicationId,
    required this.applicationBillNo,
    required this.notifiedQty,
    required this.availableQty,
  });

  final String taskId;
  final String applicationId;
  final String applicationBillNo;
  final double notifiedQty;
  final double availableQty;

  factory SubcontractMakeNotifyResult.fromJson(Map<String, dynamic> json) =>
      SubcontractMakeNotifyResult(
        taskId: _string(json['taskId']) ?? '',
        applicationId: _string(json['applicationId']) ?? '',
        applicationBillNo: _string(json['applicationBillNo']) ?? '',
        notifiedQty: _double(json['notifiedQty']) ?? 0,
        availableQty: _double(json['availableQty']) ?? 0,
      );
}

class SubcontractPreparationTask {
  const SubcontractPreparationTask({
    required this.planItemId,
    required this.orderId,
    required this.orderItemId,
    required this.status,
    required this.version,
    this.orderBillNo,
    this.targetGoodsId,
    this.targetGoodsCode,
    this.targetGoodsName,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.requiredQty = 0,
    this.preparedQty = 0,
    this.issuedQty = 0,
    this.needDate,
    this.blocker,
    this.sourceAnalysisId,
    this.sourceMaterialLineId,
    this.handoffStatus,
    this.takeoverQty = 0,
    this.handedOffEntitlementQty = 0,
    this.handoffBlocker,
    this.analysisId,
    this.analysisItemId,
    this.preparationWarehouseId,
    this.preparationWarehouseName,
    this.warehouseSelectionRequired = false,
    this.allowedActions = const {},
    this.updatedAt,
  });

  final String planItemId;
  final String orderId;
  final String orderItemId;
  final String status;
  final int version;
  final String? orderBillNo;
  final String? targetGoodsId;
  final String? targetGoodsCode;
  final String? targetGoodsName;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final double requiredQty;
  final double preparedQty;
  final double issuedQty;
  final String? needDate;
  final String? blocker;

  /// 原生产分析中被本前置自制任务接管的精确来源节点。
  /// 直接委外新建的任务没有这两个字段，也不应伪造跨分析交接。
  final String? sourceAnalysisId;
  final String? sourceMaterialLineId;

  /// V447 服务端权威的跨分析权益交接状态与数量。
  final String? handoffStatus;
  final double takeoverQty;
  final double handedOffEntitlementQty;
  final String? handoffBlocker;
  final String? analysisId;
  final String? analysisItemId;
  final String? preparationWarehouseId;
  final String? preparationWarehouseName;
  final bool warehouseSelectionRequired;
  final Set<String> allowedActions;
  final String? updatedAt;

  bool allows(String action) => allowedActions.contains(action);

  factory SubcontractPreparationTask.fromJson(Map<String, dynamic> json) =>
      SubcontractPreparationTask(
        planItemId: _string(json['planItemId']) ?? '',
        orderId: _string(json['orderId']) ?? '',
        orderItemId: _string(json['orderItemId']) ?? '',
        orderBillNo: _string(json['orderBillNo']),
        targetGoodsId: _string(json['targetGoodsId']),
        targetGoodsCode: _string(json['targetGoodsCode']),
        targetGoodsName: _string(json['targetGoodsName']),
        colorId: _string(json['colorId']),
        colorName: _string(json['colorName']),
        unitId: _string(json['unitId']),
        unitName: _string(json['unitName']),
        requiredQty: _double(json['requiredQty']) ?? 0,
        preparedQty: _double(json['preparedQty']) ?? 0,
        issuedQty: _double(json['issuedQty']) ?? 0,
        needDate: _string(json['needDate']),
        status: (_string(json['status']) ?? 'UNKNOWN').toUpperCase(),
        blocker: _string(json['blocker']),
        sourceAnalysisId: _string(json['sourceAnalysisId']),
        sourceMaterialLineId: _string(json['sourceMaterialLineId']),
        handoffStatus: _string(json['handoffStatus'])?.toUpperCase(),
        takeoverQty: _double(json['takeoverQty']) ?? 0,
        handedOffEntitlementQty: _double(json['handedOffEntitlementQty']) ?? 0,
        handoffBlocker: _string(json['handoffBlocker']),
        analysisId: _string(json['analysisId']),
        analysisItemId: _string(json['analysisItemId']),
        preparationWarehouseId: _string(json['preparationWarehouseId']),
        preparationWarehouseName: _string(json['preparationWarehouseName']),
        warehouseSelectionRequired: json['warehouseSelectionRequired'] == true,
        allowedActions: _stringList(json['allowedActions']).toSet(),
        version: _int(json['version']) ?? 0,
        updatedAt: _string(json['updatedAt']),
      );
}

class SubcontractPreparationStartResult {
  const SubcontractPreparationStartResult({
    required this.planItemId,
    required this.status,
    required this.version,
    this.analysisId,
    this.analysisItemId,
    this.sourceAnalysisId,
    this.sourceMaterialLineId,
    this.handoffId,
    this.handoffStatus,
    this.takeoverQty = 0,
    this.handedOffEntitlementQty = 0,
  });

  final String planItemId;
  final String status;
  final int version;
  final String? analysisId;
  final String? analysisItemId;
  final String? sourceAnalysisId;
  final String? sourceMaterialLineId;
  final String? handoffId;
  final String? handoffStatus;
  final double takeoverQty;
  final double handedOffEntitlementQty;

  factory SubcontractPreparationStartResult.fromJson(
    Map<String, dynamic> json,
  ) => SubcontractPreparationStartResult(
    planItemId: _string(json['planItemId']) ?? '',
    status: (_string(json['status']) ?? 'UNKNOWN').toUpperCase(),
    version: _int(json['version']) ?? 0,
    analysisId: _string(json['analysisId']),
    analysisItemId: _string(json['analysisItemId']),
    sourceAnalysisId: _string(json['sourceAnalysisId']),
    sourceMaterialLineId: _string(json['sourceMaterialLineId']),
    handoffId: _string(json['handoffId']),
    handoffStatus: _string(json['handoffStatus'])?.toUpperCase(),
    takeoverQty: _double(json['takeoverQty']) ?? 0,
    handedOffEntitlementQty: _double(json['handedOffEntitlementQty']) ?? 0,
  );
}

class MaterialAnalysisSalesCandidate {
  const MaterialAnalysisSalesCandidate({
    required this.orderId,
    this.orderNo,
    this.orderDate,
    this.deliveryDate,
    this.clientName,
    this.lines = const [],
  });

  final String orderId;
  final String? orderNo;
  final String? orderDate;
  final String? deliveryDate;
  final String? clientName;
  final List<MaterialAnalysisSalesCandidateLine> lines;

  factory MaterialAnalysisSalesCandidate.fromJson(Map<String, dynamic> json) =>
      MaterialAnalysisSalesCandidate(
        orderId: _string(json['orderId'] ?? json['id']) ?? '',
        orderNo: _string(json['orderNo'] ?? json['billNo']),
        orderDate: _string(json['orderDate'] ?? json['billDate']),
        deliveryDate: _string(json['deliveryDate'] ?? json['deliverDate']),
        clientName: _string(json['clientName']),
        lines: _mapList(
          json['lines'],
          MaterialAnalysisSalesCandidateLine.fromJson,
        ),
      );
}

class MaterialAnalysisSalesCandidateLine {
  const MaterialAnalysisSalesCandidateLine({
    required this.salesOrderItemId,
    this.lineNo,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.spec,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.unitRate,
    this.orderedQty,
    this.alreadyPlannedQty,
    this.remainingQty,
    this.deliveryDate,
    this.analysisId,
    this.analysisStatus,
    this.analysisVersion,
    this.orderId,
    this.orderNo,
    this.orderDate,
    this.clientName,
  });

  final String salesOrderItemId;
  final int? lineNo;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? spec;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final double? unitRate;
  final double? orderedQty;
  final double? alreadyPlannedQty;
  final double? remainingQty;
  final String? deliveryDate;
  final String? analysisId;
  final String? analysisStatus;
  final int? analysisVersion;
  final String? orderId;
  final String? orderNo;
  final String? orderDate;
  final String? clientName;

  factory MaterialAnalysisSalesCandidateLine.fromJson(
    Map<String, dynamic> json,
  ) => MaterialAnalysisSalesCandidateLine(
    salesOrderItemId:
        _string(json['salesOrderItemId'] ?? json['orderItemId']) ?? '',
    lineNo: _int(json['lineNo']),
    goodsId: _string(json['goodsId']),
    goodsCode: _string(json['goodsCode']),
    goodsName: _string(json['goodsName']),
    spec: _string(json['spec']),
    colorId: _string(json['colorId']),
    colorName: _string(json['colorName']),
    unitId: _string(json['unitId']),
    unitName: _string(json['unitName']),
    unitRate: _double(json['unitRate']),
    orderedQty: _double(json['orderedQty'] ?? json['qty']),
    alreadyPlannedQty: _double(json['alreadyPlannedQty'] ?? json['plannedQty']),
    remainingQty: _double(json['remainingQty'] ?? json['needQty']),
    deliveryDate: _string(json['deliveryDate'] ?? json['deliverDate']),
    analysisId: _string(json['analysisId']),
    analysisStatus: _string(json['analysisStatus']),
    analysisVersion: _int(json['analysisVersion']),
  );

  MaterialAnalysisSalesCandidateLine withOrder(
    MaterialAnalysisSalesCandidate order,
  ) => MaterialAnalysisSalesCandidateLine(
    salesOrderItemId: salesOrderItemId,
    lineNo: lineNo,
    goodsId: goodsId,
    goodsCode: goodsCode,
    goodsName: goodsName,
    spec: spec,
    colorId: colorId,
    colorName: colorName,
    unitId: unitId,
    unitName: unitName,
    orderedQty: orderedQty,
    alreadyPlannedQty: alreadyPlannedQty,
    remainingQty: remainingQty,
    deliveryDate: deliveryDate ?? order.deliveryDate,
    analysisId: analysisId,
    analysisStatus: analysisStatus,
    analysisVersion: analysisVersion,
    orderId: order.orderId,
    orderNo: order.orderNo,
    orderDate: order.orderDate,
    clientName: order.clientName,
  );
}

class ProductionMaterialAnalysisView {
  const ProductionMaterialAnalysisView({
    required this.analysisId,
    required this.version,
    required this.fingerprint,
    this.status,
    this.warehouseId,
    this.warehouseIds = const [],
    this.analyzedAt,
    this.products = const [],
    this.materials = const [],
    this.warehouses = const [],
    this.supplyActions = const [],
    this.allowedActions = const {},
    this.fqcReplenishmentOnly = false,
    this.fqcRecoveryAuthorizationId,
  });

  final String analysisId;
  final String? status;
  final int version;
  final String fingerprint;
  final String? warehouseId;
  final List<String> warehouseIds;
  final String? analyzedAt;
  final List<ProductionMaterialAnalysisProduct> products;
  final List<ProductionMaterialAnalysisMaterial> materials;
  final List<ProductionMaterialAnalysisWarehouse> warehouses;
  final List<MaterialAnalysisSupplyAction> supplyActions;
  final Set<String> allowedActions;
  final bool fqcReplenishmentOnly;
  final String? fqcRecoveryAuthorizationId;

  bool get routesConfirmed => materials
      .where((item) => item.shortageQty > 0)
      .every((item) => item.routeConfirmed && item.confirmedRoute != null);

  factory ProductionMaterialAnalysisView.fromJson(Map<String, dynamic> json) =>
      ProductionMaterialAnalysisView(
        analysisId: _string(json['analysisId'] ?? json['id']) ?? '',
        status: _string(json['status']),
        version: _int(json['version']) ?? 0,
        fingerprint: _string(json['fingerprint']) ?? '',
        warehouseId: _string(json['warehouseId']),
        warehouseIds: _stringList(json['warehouseIds']),
        analyzedAt: _string(
          json['analyzedAt'] ?? json['calculatedAt'] ?? json['updatedAt'],
        ),
        products: _mapList(
          json['products'],
          ProductionMaterialAnalysisProduct.fromJson,
        ),
        materials: _mapList(
          json['flatMaterials'] ?? json['materials'],
          ProductionMaterialAnalysisMaterial.fromJson,
        ),
        warehouses: _mapList(
          json['warehouses'],
          ProductionMaterialAnalysisWarehouse.fromJson,
        ),
        supplyActions: _mapList(
          json['supplyActions'],
          MaterialAnalysisSupplyAction.fromJson,
        ),
        allowedActions: _stringList(json['allowedActions']).toSet(),
        fqcReplenishmentOnly: json['fqcReplenishmentOnly'] == true,
        fqcRecoveryAuthorizationId: _string(json['fqcRecoveryAuthorizationId']),
      );
}

class ProductionMaterialAnalysisProduct {
  const ProductionMaterialAnalysisProduct({
    required this.analysisLineId,
    this.sourceType,
    this.sourceRef,
    this.sourceReason,
    this.salesOrderItemId,
    this.orderId,
    this.orderNo,
    this.orderDate,
    this.deliveryDate,
    this.clientName,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.spec,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.unitRate,
    this.requestedQty = 0,
    this.generatedQty = 0,
    this.submittedQty = 0,
    this.approvedQty = 0,
    this.remainingQty = 0,
    this.serverCanSchedule,
    this.serverMaxSchedulableQty,
    this.scheduleBlockedReason,
    this.readyNowQty = 0,
    this.readyStartQty,
    this.readyFinishQty,
    this.readyShipQty,
    this.readyByDateQty,
    this.readinessRatio = 0,
    this.hasProductionMaterialChildren,
    this.status,
    this.allocationPriority,
    this.parentAnalysisLineId,
    this.parentGoodsName,
    this.planExecutionStatus,
    this.latestPlanId,
    this.latestPlanNo,
    this.planExecutionPlannedQty,
    this.planExecutionInboundQty,
    this.planExecutionProgressRatio,
  });

  final String analysisLineId;
  final String? sourceType;
  final String? sourceRef;
  final String? sourceReason;
  final String? salesOrderItemId;
  final String? orderId;
  final String? orderNo;
  final String? orderDate;
  final String? deliveryDate;
  final String? clientName;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? spec;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final double? unitRate;
  final double requestedQty;
  final double generatedQty;
  final double submittedQty;
  final double approvedQty;
  final double remainingQty;
  final bool? serverCanSchedule;
  final double? serverMaxSchedulableQty;
  final String? scheduleBlockedReason;
  final double readyNowQty;
  final double? readyStartQty;
  final double? readyFinishQty;
  final double? readyShipQty;
  final double? readyByDateQty;
  final double readinessRatio;

  /// 服务端物料分析快照中的结构事实：当前产品是否存在生产子层级。
  ///
  /// `null` 仅用于兼容尚未返回该字段的旧服务端；页面会退回同一响应中的
  /// `flatMaterials` 判断，绝不按货品来源或主档策略猜测。
  final bool? hasProductionMaterialChildren;
  final String? status;
  final int? allocationPriority;

  /// For MAKE_COMPONENT self-make items: the parent assembly product this
  /// sub-component feeds into. Null for top-level sales/manual sources.
  final String? parentAnalysisLineId;
  final String? parentGoodsName;
  final String? planExecutionStatus;
  final String? latestPlanId;
  final String? latestPlanNo;

  /// Effective approved production-plan totals for this analysis product.
  /// The ratio is nullable so an older server or a plan without an executable
  /// denominator never masquerades as genuine 0% progress.
  final double? planExecutionPlannedQty;
  final double? planExecutionInboundQty;
  final double? planExecutionProgressRatio;

  /// 服务端明确区分“可以先排给车间”和“当前物料已经齐套”。旧服务端没有
  /// 新字段时保守回退原 ready-now 门禁，避免客户端越权放开待料排产。
  bool get canSchedule => serverCanSchedule ?? readyNowQty > 0;
  double get maxSchedulableQty => serverMaxSchedulableQty ?? readyNowQty;

  factory ProductionMaterialAnalysisProduct.fromJson(
    Map<String, dynamic> json,
  ) => ProductionMaterialAnalysisProduct(
    analysisLineId: _string(json['analysisLineId'] ?? json['id']) ?? '',
    sourceType: _string(json['sourceType']),
    sourceRef: _string(json['sourceRef']),
    sourceReason: _string(json['sourceReason']),
    salesOrderItemId: _string(json['salesOrderItemId']),
    orderId: _string(json['salesOrderId'] ?? json['orderId']),
    orderNo: _string(
      json['salesOrderNo'] ?? json['orderNo'] ?? json['orderBillNo'],
    ),
    orderDate: _string(json['orderDate']),
    deliveryDate: _string(json['deliveryDate']),
    clientName: _string(json['clientName']),
    goodsId: _string(json['goodsId']),
    goodsCode: _string(json['goodsCode']),
    goodsName: _string(json['goodsName']),
    spec: _string(json['spec']),
    colorId: _string(json['colorId']),
    colorName: _string(json['colorName']),
    unitId: _string(json['unitId']),
    unitName: _string(json['unitName']),
    unitRate: _double(json['unitRate']),
    requestedQty: _double(json['requestedQty']) ?? 0,
    generatedQty: _double(json['generatedQty'] ?? json['approvedQty']) ?? 0,
    submittedQty: _double(json['submittedQty']) ?? 0,
    approvedQty: _double(json['approvedQty']) ?? 0,
    remainingQty: _double(json['remainingQty']) ?? 0,
    serverCanSchedule: json.containsKey('canSchedule')
        ? json['canSchedule'] == true
        : null,
    serverMaxSchedulableQty: _double(json['maxSchedulableQty']),
    scheduleBlockedReason: _string(json['scheduleBlockedReason']),
    readyNowQty: _double(json['readyNowQty']) ?? 0,
    readyStartQty: _double(json['readyStartQty']),
    readyFinishQty: _double(json['readyFinishQty']),
    readyShipQty: _double(json['readyShipQty']),
    readyByDateQty: _double(json['readyByDateQty']),
    readinessRatio: _normaliseRatio(json['readinessRatio']),
    hasProductionMaterialChildren:
        json.containsKey('hasProductionMaterialChildren')
        ? json['hasProductionMaterialChildren'] == true
        : null,
    status: _string(json['status']),
    allocationPriority: _int(json['allocationPriority']),
    parentAnalysisLineId: _string(json['parentAnalysisLineId']),
    parentGoodsName: _string(json['parentGoodsName']),
    planExecutionStatus: _string(json['planExecutionStatus']),
    latestPlanId: _string(json['latestPlanId']),
    latestPlanNo: _string(json['latestPlanNo']),
    planExecutionPlannedQty: _double(json['planExecutionPlannedQty']),
    planExecutionInboundQty: _double(json['planExecutionInboundQty']),
    planExecutionProgressRatio: _normaliseNullableRatio(
      json['planExecutionProgressRatio'],
    ),
  );
}

class MaterialAllocationPriorityInput {
  const MaterialAllocationPriorityInput({
    required this.analysisLineId,
    required this.priority,
  });

  final String analysisLineId;
  final int priority;

  Map<String, dynamic> toJson() => {
    'analysisLineId': analysisLineId,
    'priority': priority,
  };
}

/// One authoritative public-surplus future-supply source visible to the
/// current user. Document identifiers may be redacted by object permissions;
/// null identifiers therefore mean "source protected", not missing data.
class SharedFutureSupplyRef {
  const SharedFutureSupplyRef({
    this.route,
    this.approvedInboundQty = 0,
    this.availableToClaimQty = 0,
    this.expectedDate,
    this.sourceActionId,
    this.documentType,
    this.documentId,
    this.documentNo,
    this.sourceIsCurrentAnalysis = false,
  });

  final MaterialSupplyRoute? route;
  final double approvedInboundQty;
  final double availableToClaimQty;
  final String? expectedDate;
  final String? sourceActionId;
  final String? documentType;
  final String? documentId;
  final String? documentNo;
  final bool sourceIsCurrentAnalysis;

  factory SharedFutureSupplyRef.fromJson(Map<String, dynamic> json) =>
      SharedFutureSupplyRef(
        route: MaterialSupplyRoute.fromWire(json['route']),
        approvedInboundQty: _double(json['approvedInboundQty']) ?? 0,
        availableToClaimQty: _double(json['availableToClaimQty']) ?? 0,
        expectedDate: _string(json['expectedDate']),
        sourceActionId: _string(json['sourceActionId']),
        documentType: _string(json['documentType']),
        documentId: _string(json['documentId']),
        documentNo: _string(json['documentNo']),
        sourceIsCurrentAnalysis: json['sourceIsCurrentAnalysis'] == true,
      );
}

/// Material-analysis planning defaults shared by every product/child entry.
///
/// A positive complete-kit quantity is the safest useful first batch: it can
/// become the immediately executable segment while the remainder stays
/// traceable as waiting material. When nothing is ready yet, the full server
/// scheduling cap remains the default so staff can still assign the waiting
/// work to a workshop in advance.
extension ProductionMaterialAnalysisBatchSuggestion
    on ProductionMaterialAnalysisProduct {
  bool get hasPartialReadyBatch {
    final cap = maxSchedulableQty;
    return cap.isFinite &&
        cap > 0 &&
        readyNowQty.isFinite &&
        readyNowQty > 0 &&
        readyNowQty < cap;
  }

  double get suggestedFirstBatchQty {
    final cap = maxSchedulableQty;
    if (!cap.isFinite || cap <= 0) return 0;
    if (hasPartialReadyBatch) return readyNowQty < cap ? readyNowQty : cap;
    return cap;
  }

  double get waitingQtyAfterSuggestedFirstBatch {
    final remaining = maxSchedulableQty - suggestedFirstBatchQty;
    return remaining > 0 && remaining.isFinite ? remaining : 0;
  }
}

class ProductionMaterialAnalysisMaterial {
  const ProductionMaterialAnalysisMaterial({
    required this.materialLineId,
    this.analysisLineId,
    this.nodeKey,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.spec,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.level = 0,
    this.path = const [],
    this.parentGoodsId,
    this.parentNodeKey,
    this.parentLabel,
    this.actionGroupKey,
    this.materialKey,
    this.requiredQty = 0,
    this.perProductQty = 0,
    this.availableQty = 0,
    this.allocatedAvailableQty = 0,
    this.exactPeggedQty = 0,
    this.reservedQty = 0,
    this.safetyStockQty = 0,
    this.inboundQty = 0,
    this.publicSurplusApprovedInboundQty = 0,
    this.publicSurplusRemainingQty = 0,
    this.sharedFutureClaimedQty = 0,
    this.additionalSupplyRecommendedQty = 0,
    this.selectedWarehousesAvailableQty = 0,
    this.selectedOtherWarehouseTransferableQty = 0,
    this.publicSurplusExpectedDate,
    this.sharedFutureSupplyRefs = const [],
    this.shortageQty = 0,
    this.demandSupplyGapQty = 0,
    this.subcontractHandoffFutureQty = 0,
    this.requirementState,
    this.delegatedToAnalysisLineId,
    this.delegatedToSourceRef,
    this.delegatedToRequestedQty,
    this.sourceSuggestion,
    this.sourceConfirmed,
    this.routeConfirmed = false,
    this.routeReason,
    this.lowerLevelPending = false,
    this.expectedReadyDate,
    this.status,
    this.controlStage,
    this.consumptionBasis,
    this.basisOutputQty,
    this.allowPartialPackage,
    this.hardGate,
    this.notifiedTargets = const [],
    this.borrowedInQty = 0,
    this.borrowedOutQty = 0,
    this.borrowRefs = const [],
    this.crossReallocatedInQty = 0,
    this.crossReallocatedOutQty = 0,
    this.priorityPendingQty = 0,
    this.priorityFulfilledQty = 0,
    this.crossReallocationRefs = const [],
    this.warehouseStocks = const [],
    required this.actionable,
  });

  final String materialLineId;
  final String? analysisLineId;
  final String? nodeKey;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? spec;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final int level;
  final List<String> path;
  final String? parentGoodsId;
  final String? parentNodeKey;
  final String? parentLabel;

  /// Stable server-side identity of this BOM node's business action.
  final String? actionGroupKey;
  final String? materialKey;
  final double requiredQty;
  final double perProductQty;

  /// Qualified stock in the selected warehouse before this analysis allocates
  /// the shared pool to individual demand nodes.
  final double availableQty;

  /// The part of [availableQty] actually assigned to this demand node.
  final double allocatedAvailableQty;

  /// 已通过质检并精确绑定给当前 BOM 需求节点的有效库存量。
  ///
  /// 与 [MaterialWarehouseStock.ownPeggedQty] 的同物料分析级汇总不同，本字段
  /// 可以安全地展示在逐路径节点卡上，兄弟节点不会重复认领同一笔到货。
  final double exactPeggedQty;
  final double reservedQty;
  final double safetyStockQty;
  final double inboundQty;
  final double publicSurplusApprovedInboundQty;
  final double publicSurplusRemainingQty;
  final double sharedFutureClaimedQty;
  final double additionalSupplyRecommendedQty;

  /// Availability across the explicitly checked warehouses. Reference only:
  /// it never raises readyNow or creates an entitlement outside the primary.
  final double selectedWarehousesAvailableQty;
  final double selectedOtherWarehouseTransferableQty;
  final String? publicSurplusExpectedDate;
  final List<SharedFutureSupplyRef> sharedFutureSupplyRefs;
  final double shortageQty;

  /// 尚未被本批已分配现货或节点精确到货权益覆盖的生产需求。
  ///
  /// 这与 [shortageQty] 不同：后者仍包含安全库存硬保护造成的阻断；提交
  /// 采购/委外/自制的“本批生产需求”只能使用本字段，避免合格到货后重复下达。
  final double demandSupplyGapQty;

  /// 已由 V447 从原分析供给分摊接管、但尚未形成当前节点合格库存的数量。
  /// 它阻止重复下达；只有真实批准订单/计划才会另计入 [inboundQty]。
  final double subcontractHandoffFutureQty;

  /// 当前路径为什么有/没有本批需求。服务端按需求、父路线与 MAKE child
  /// ownership 计算；旧响应可为空，界面只做保守兼容展示。
  final MaterialRequirementState? requirementState;

  /// `DELEGATED_TO_MAKE_CHILD` 对应的系统自制 child analysis item。
  final String? delegatedToAnalysisLineId;

  /// child 的可读业务来源引用，不是正式生产计划单号。
  final String? delegatedToSourceRef;

  /// 关联 child 当前总 requested_qty。它不是旧后代单行委派量，也不是本次
  /// 正式计划量；当前无 delegated_qty 时，服务端强制按全部实时余量创建。
  final double? delegatedToRequestedQty;
  final MaterialSupplyRoute? sourceSuggestion;
  final MaterialSupplyRoute? sourceConfirmed;
  final bool routeConfirmed;
  final String? routeReason;
  final bool lowerLevelPending;
  final String? expectedReadyDate;
  final String? status;
  final String? controlStage;
  final String? consumptionBasis;
  final double? basisOutputQty;
  final bool? allowPartialPackage;
  final bool? hardGate;
  final List<MaterialAnalysisNotificationTarget> notifiedTargets;

  /// 现货层借用（调货）投影：本节点被其它产品借入/借出的生效数量，
  /// 以及逐笔明细（对方产品、申请量、原因）。服务端权威，客户端只展示。
  final double borrowedInQty;
  final double borrowedOutQty;
  final List<MaterialBorrowRef> borrowRefs;

  /// 跨物料分析让料投影。接受计划无需返还；让出计划保留原始需求，后续
  /// 来源供应按服务端权威顺序优先补齐。客户端只展示，不参与数量计算。
  final double crossReallocatedInQty;
  final double crossReallocatedOutQty;
  final double priorityPendingQty;
  final double priorityFulfilledQty;
  final List<MaterialCrossReallocationRef> crossReallocationRefs;

  /// 分仓现货明细（服务端 v_stock_available 投影）：现货列需要解释
  /// 「在库有量但被安全库存/预留抵扣」时取这里的原始在库量。
  final List<MaterialWarehouseStock> warehouseStocks;
  final bool actionable;

  MaterialSupplyRoute? get confirmedRoute =>
      routeConfirmed ? sourceConfirmed : null;

  /// Positive server demand always wins. Older responses without the new state
  /// remain readable, but a zero quantity is conservatively treated as generic
  /// inactive rather than being relabelled as covered or delegated.
  MaterialRequirementState get effectiveRequirementState => requiredQty > 0
      ? MaterialRequirementState.active
      : requirementState ?? MaterialRequirementState.inactive;

  factory ProductionMaterialAnalysisMaterial.fromJson(
    Map<String, dynamic> json,
  ) => ProductionMaterialAnalysisMaterial(
    materialLineId: _string(json['materialLineId'] ?? json['id']) ?? '',
    analysisLineId: _string(json['analysisLineId']),
    nodeKey: _string(json['nodeKey']),
    goodsId: _string(json['goodsId']),
    goodsCode: _string(json['goodsCode']),
    goodsName: _string(json['goodsName']),
    spec: _string(json['spec']),
    colorId: _string(json['colorId']),
    colorName: _string(json['colorName']),
    unitId: _string(json['unitId']),
    unitName: _string(json['unitName']),
    level: _int(json['level']) ?? 0,
    path: _path(json['path']),
    parentGoodsId: _string(json['parentGoodsId']),
    parentNodeKey: _string(json['parentNodeKey']),
    parentLabel: _string(json['parentLabel']),
    actionGroupKey: _string(json['actionGroupKey']),
    materialKey: _string(json['materialKey']),
    perProductQty: _double(json['perProductQty']) ?? 0,
    requiredQty: _double(json['requiredQty']) ?? 0,
    availableQty: _double(json['availableQty']) ?? 0,
    allocatedAvailableQty: _double(json['allocatedAvailableQty']) ?? 0,
    exactPeggedQty: _double(json['exactPeggedQty']) ?? 0,
    reservedQty: _double(json['reservedQty']) ?? 0,
    safetyStockQty: _double(json['safetyStockQty']) ?? 0,
    inboundQty: _double(json['inboundQty']) ?? 0,
    publicSurplusApprovedInboundQty:
        _double(json['publicSurplusApprovedInboundQty']) ?? 0,
    publicSurplusRemainingQty: _double(json['publicSurplusRemainingQty']) ?? 0,
    sharedFutureClaimedQty: _double(json['sharedFutureClaimedQty']) ?? 0,
    additionalSupplyRecommendedQty:
        _double(json['additionalSupplyRecommendedQty']) ?? 0,
    selectedWarehousesAvailableQty:
        _double(json['selectedWarehousesAvailableQty']) ?? 0,
    selectedOtherWarehouseTransferableQty:
        _double(json['selectedOtherWarehouseTransferableQty']) ?? 0,
    publicSurplusExpectedDate: _string(json['publicSurplusExpectedDate']),
    sharedFutureSupplyRefs: _mapList(
      json['sharedFutureSupplyRefs'],
      SharedFutureSupplyRef.fromJson,
    ),
    shortageQty: _double(json['shortageQty']) ?? 0,
    demandSupplyGapQty: _demandSupplyGap(json),
    subcontractHandoffFutureQty:
        _double(json['subcontractHandoffFutureQty']) ?? 0,
    requirementState: MaterialRequirementState.fromWire(
      json['requirementState'],
    ),
    delegatedToAnalysisLineId: _string(json['delegatedToAnalysisLineId']),
    delegatedToSourceRef: _string(json['delegatedToSourceRef']),
    delegatedToRequestedQty: _double(json['delegatedToRequestedQty']),
    sourceSuggestion: MaterialSupplyRoute.fromWire(
      json['sourceSuggestion'] ?? json['suggestedRoute'],
    ),
    sourceConfirmed: MaterialSupplyRoute.fromWire(
      json['sourceConfirmed'] ?? json['selectedRoute'],
    ),
    routeConfirmed: json['routeConfirmed'] == true,
    routeReason: _string(json['routeReason']),
    lowerLevelPending: json['lowerLevelPending'] == true,
    expectedReadyDate: _string(json['expectedReadyDate']),
    status: _string(json['status'] ?? json['materialStatus']),
    controlStage: _string(json['controlStage']),
    consumptionBasis: _string(json['consumptionBasis']),
    basisOutputQty: _double(json['basisOutputQty']),
    allowPartialPackage: _boolOrNull(json['allowPartialPackage']),
    hardGate: _boolOrNull(json['hardGate']),
    // 优先取下游引用（含单据号/状态/分摊量），它是「已下达多少、进行到哪步」
    // 的权威投影；旧版 notifiedTargets 只有路线名，仅作回退。
    notifiedTargets: _notificationTargets(
      json['downstreamReferences'] ?? json['notifiedTargets'],
    ),
    borrowedInQty: _double(json['borrowedInQty']) ?? 0,
    borrowedOutQty: _double(json['borrowedOutQty']) ?? 0,
    borrowRefs: _mapList(json['borrowRefs'], MaterialBorrowRef.fromJson),
    crossReallocatedInQty: _double(json['crossReallocatedInQty']) ?? 0,
    crossReallocatedOutQty: _double(json['crossReallocatedOutQty']) ?? 0,
    priorityPendingQty: _double(json['priorityPendingQty']) ?? 0,
    priorityFulfilledQty: _double(json['priorityFulfilledQty']) ?? 0,
    crossReallocationRefs: _mapList(
      json['crossReallocationRefs'],
      MaterialCrossReallocationRef.fromJson,
    ),
    warehouseStocks: _mapList(
      json['warehouseBreakdown'],
      MaterialWarehouseStock.fromJson,
    ),
    actionable:
        _boolOrNull(json['actionable']) ?? ((_int(json['level']) ?? 0) == 1),
  );
}

/// 物料在某仓的现货投影：在库量 / 预留量 / 扣安全库存后可用量。
class MaterialWarehouseStock {
  const MaterialWarehouseStock({
    required this.warehouseId,
    this.warehouseCode,
    this.warehouseName,
    this.onHandQty = 0,
    this.reservedQty = 0,
    this.availableQty = 0,
    this.ownPeggedQty = 0,
    this.publicAvailableQty = 0,
    this.openSafetySupplyQty = 0,
    this.safetyReplenishmentGapQty = 0,
    this.publicSurplusApprovedInboundQty = 0,
    this.publicSurplusRemainingQty = 0,
    this.publicSurplusExpectedDate,
  });

  final String warehouseId;
  final String? warehouseCode;
  final String? warehouseName;
  final double onHandQty;
  final double reservedQty;
  final double availableQty;

  /// 当前物料维度在本分析、当前仓下的合格入库绑定合计。
  ///
  /// 这是 analysis + goods/color + warehouse 聚合，不是某个 BOM 节点的
  /// 独占量。同 SKU 兄弟节点会拿到相同合计，逐节点展示必须使用
  /// [ProductionMaterialAnalysisMaterial.exactPeggedQty]。前端不能自行用本值
  /// 参与可用量运算。
  final double ownPeggedQty;

  /// 不含本分析 exact peg 的公共可用库存。
  final double publicAvailableQty;

  /// 其它有效 BUY 行动中仍会到货的公共安全库存补库切片。
  final double openSafetySupplyQty;

  /// max(安全库存 - 公共可用 - 公共补库在途, 0)。同 SKU 路径会重复，
  /// 客户端提交前必须按 goods/color/unit 去重且显式回传。
  final double safetyReplenishmentGapQty;
  final double publicSurplusApprovedInboundQty;
  final double publicSurplusRemainingQty;
  final String? publicSurplusExpectedDate;

  /// 安全库存抵扣前的现货量（在库 - 预留），用于解释「有在库但现货为 0」。
  double get preSafetyQty =>
      (onHandQty - reservedQty).clamp(0.0, double.infinity);

  factory MaterialWarehouseStock.fromJson(
    Map<String, dynamic> json,
  ) => MaterialWarehouseStock(
    warehouseId: _string(json['warehouseId'] ?? json['id']) ?? '',
    warehouseCode: _string(json['warehouseCode'] ?? json['code']),
    warehouseName: _string(json['warehouseName'] ?? json['name']),
    onHandQty: _double(json['onHandQty']) ?? 0,
    reservedQty: _double(json['reservedQty']) ?? 0,
    availableQty: _double(json['availableQty']) ?? 0,
    ownPeggedQty: _double(json['ownPeggedQty']) ?? 0,
    publicAvailableQty: _double(json['publicAvailableQty']) ?? 0,
    openSafetySupplyQty: _double(json['openSafetySupplyQty']) ?? 0,
    safetyReplenishmentGapQty: _double(json['safetyReplenishmentGapQty']) ?? 0,
    publicSurplusApprovedInboundQty:
        _double(json['publicSurplusApprovedInboundQty']) ?? 0,
    publicSurplusRemainingQty: _double(json['publicSurplusRemainingQty']) ?? 0,
    publicSurplusExpectedDate: _string(json['publicSurplusExpectedDate']),
  );
}

/// 一笔有效借用的双向投影：本节点是借出方（OUT）还是借入方（IN）、
/// 生效数量、申请数量、对方产品标签与操作原因。
class MaterialBorrowRef {
  const MaterialBorrowRef({
    required this.borrowId,
    required this.direction,
    required this.qty,
    required this.requestedQty,
    this.counterpartProduct,
    this.reason,
  });

  final String borrowId;

  /// 'IN' = 本节点借入；'OUT' = 本节点被借出。
  final String direction;
  final double qty;
  final double requestedQty;
  final String? counterpartProduct;
  final String? reason;

  bool get isInbound => direction == 'IN';

  factory MaterialBorrowRef.fromJson(Map<String, dynamic> json) =>
      MaterialBorrowRef(
        borrowId: _string(json['borrowId']) ?? '',
        direction: _string(json['direction']) ?? '',
        qty: _double(json['qty']) ?? 0,
        requestedQty: _double(json['requestedQty']) ?? 0,
        counterpartProduct: _string(json['counterpartProduct']),
        reason: _string(json['reason']),
      );
}

/// 跨物料分析让料候选。版本与指纹属于接受计划的 CAS 快照；提交时必须
/// 原样回传，不能用列表展示值在客户端重算合法数量。
class MaterialCrossReallocationCandidate {
  const MaterialCrossReallocationCandidate({
    required this.targetAnalysisId,
    required this.targetVersion,
    required this.targetFingerprint,
    required this.targetMaterialLineId,
    this.targetAnalysisLineId,
    this.analysisLabel,
    this.productLabel,
    this.pathLabel,
    this.sourceRefs = const [],
    this.warehouseId,
    this.warehouseName,
    this.deliveryDate,
    this.shortageQty = 0,
    this.sourceLendableQty = 0,
  });

  final String targetAnalysisId;
  final int targetVersion;
  final String targetFingerprint;
  final String targetMaterialLineId;
  final String? targetAnalysisLineId;
  final String? analysisLabel;
  final String? productLabel;
  final String? pathLabel;
  final List<String> sourceRefs;
  final String? warehouseId;
  final String? warehouseName;
  final String? deliveryDate;
  final double shortageQty;
  final double sourceLendableQty;

  String get displayAnalysisLabel {
    final explicit = analysisLabel?.trim();
    if (explicit?.isNotEmpty == true) return explicit!;
    if (sourceRefs.isNotEmpty) return sourceRefs.join(' / ');
    return '物料分析 ${_shortIdentity(targetAnalysisId)}';
  }

  factory MaterialCrossReallocationCandidate.fromJson(
    Map<String, dynamic> json,
  ) => MaterialCrossReallocationCandidate(
    targetAnalysisId:
        _string(json['targetAnalysisId'] ?? json['analysisId']) ?? '',
    targetVersion: _int(json['targetVersion'] ?? json['version']) ?? 0,
    targetFingerprint:
        _string(json['targetFingerprint'] ?? json['fingerprint']) ?? '',
    targetMaterialLineId:
        _string(json['targetMaterialLineId'] ?? json['materialLineId']) ?? '',
    targetAnalysisLineId: _string(
      json['targetAnalysisLineId'] ?? json['analysisLineId'],
    ),
    analysisLabel: _string(
      json['analysisLabel'] ?? json['targetAnalysisLabel'],
    ),
    productLabel: _string(json['productLabel'] ?? json['targetProductLabel']),
    pathLabel: _string(json['pathLabel'] ?? json['materialPathLabel']),
    sourceRefs: _stringList(json['sourceRefs']),
    warehouseId: _string(json['warehouseId']),
    warehouseName: _string(json['warehouseName']),
    deliveryDate: _string(json['deliveryDate']),
    shortageQty: _double(json['shortageQty']) ?? 0,
    sourceLendableQty: _double(json['sourceLendableQty']) ?? 0,
  );
}

/// 一笔让料后，原计划获得的优先补齐来源。可来自采购、委外或自制入库；
/// 这里只展示服务端已建立的来源谱系，不代表接受计划返料。
class MaterialPriorityReplenishmentRef {
  const MaterialPriorityReplenishmentRef({
    this.route,
    this.documentType,
    this.documentId,
    this.documentNo,
    this.receiptNo,
    this.inspectionNo,
    this.qty = 0,
    this.completedAt,
  });

  final String? route;
  final String? documentType;
  final String? documentId;
  final String? documentNo;
  final String? receiptNo;
  final String? inspectionNo;
  final double qty;
  final String? completedAt;

  String get displayLabel {
    final type = switch (route?.trim().toUpperCase()) {
      'BUY' => '采购入库',
      'SUBCONTRACT' => '委外回厂',
      'MAKE' => '自制入库',
      _ => '合格入库',
    };
    final reference = [documentNo, receiptNo, inspectionNo]
        .whereType<String>()
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty);
    final suffix = reference.isEmpty ? '' : ' · ${reference.join(' / ')}';
    return '$type ${_formatModelQty(qty)}$suffix';
  }

  factory MaterialPriorityReplenishmentRef.fromJson(
    Map<String, dynamic> json,
  ) => MaterialPriorityReplenishmentRef(
    route: _string(json['route'] ?? json['sourceType']),
    documentType: _string(json['documentType']),
    documentId: _string(json['sourceDocumentId'] ?? json['documentId']),
    documentNo: _string(
      json['sourceDocumentNo'] ?? json['documentNo'] ?? json['billNo'],
    ),
    receiptNo: _string(json['receiptNo']),
    inspectionNo: _string(json['inspectionNo']),
    qty: _double(json['qty'] ?? json['fulfilledQty']) ?? 0,
    completedAt: _string(json['completedAt'] ?? json['occurredAt']),
  );
}

/// 跨计划让料的双端投影。OUT 是当前计划让出，IN 是当前计划接受。
/// `canRevoke` 与阻断原因由服务端权威给出；客户端不得按状态自行推断。
class MaterialCrossReallocationRef {
  const MaterialCrossReallocationRef({
    required this.id,
    required this.direction,
    required this.status,
    required this.counterpartAnalysisId,
    required this.qty,
    this.counterpartMaterialLineId,
    this.counterpartVersion,
    this.counterpartFingerprint,
    this.counterpartLabel,
    this.counterpartProduct,
    this.currentEffectiveQty = 0,
    this.priorityFulfilledQty = 0,
    this.priorityOpenQty = 0,
    this.reason,
    this.canRevoke = false,
    this.revokeBlockedReason,
    this.replenishmentRefs = const [],
  });

  final String id;
  final String direction;
  final String status;
  final String counterpartAnalysisId;
  final String? counterpartMaterialLineId;
  final int? counterpartVersion;
  final String? counterpartFingerprint;
  final String? counterpartLabel;
  final String? counterpartProduct;
  final double qty;
  final double currentEffectiveQty;
  final double priorityFulfilledQty;
  final double priorityOpenQty;
  final String? reason;
  final bool canRevoke;
  final String? revokeBlockedReason;
  final List<MaterialPriorityReplenishmentRef> replenishmentRefs;

  bool get isInbound => direction.trim().toUpperCase() == 'IN';
  bool get isOutbound => !isInbound;
  bool get isReversed =>
      const {'REVERSED', 'REVOKED'}.contains(status.trim().toUpperCase());
  bool get isCancelled => status.trim().toUpperCase() == 'CANCELLED';
  bool get isPriorityFulfilled =>
      priorityOpenQty <= 0 && priorityFulfilledQty > 0;

  factory MaterialCrossReallocationRef.fromJson(
    Map<String, dynamic> json,
  ) => MaterialCrossReallocationRef(
    id:
        _string(
          json['reallocationId'] ?? json['id'] ?? json['crossReallocationId'],
        ) ??
        '',
    direction: _string(json['direction']) ?? '',
    status: _string(json['status']) ?? 'UNKNOWN',
    counterpartAnalysisId: _string(json['counterpartAnalysisId']) ?? '',
    counterpartMaterialLineId: _string(json['counterpartMaterialLineId']),
    counterpartVersion: _int(json['counterpartVersion']),
    counterpartFingerprint: _string(json['counterpartFingerprint']),
    counterpartLabel: _string(
      json['counterpartAnalysisLabel'] ?? json['counterpartLabel'],
    ),
    counterpartProduct: _string(json['counterpartProduct']),
    qty: _double(json['qty']) ?? 0,
    currentEffectiveQty: _double(json['currentEffectiveQty']) ?? 0,
    priorityFulfilledQty:
        _double(json['priorityFulfilledQty'] ?? json['priorityFulfilled']) ?? 0,
    priorityOpenQty:
        _double(json['priorityOpenQty'] ?? json['priorityPendingQty']) ?? 0,
    reason: _string(json['reason']),
    canRevoke: json['canRevoke'] == true,
    revokeBlockedReason: _string(json['revokeBlockedReason']),
    replenishmentRefs: _mapList(
      json['replenishmentRefs'],
      MaterialPriorityReplenishmentRef.fromJson,
    ),
  );
}

String _shortIdentity(String value) {
  final normalized = value.trim();
  if (normalized.length <= 8) return normalized;
  return normalized.substring(0, 8);
}

String _formatModelQty(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

class MaterialAnalysisNotificationTarget {
  const MaterialAnalysisNotificationTarget({
    required this.target,
    this.actionId,
    this.documentType,
    this.documentId,
    this.documentNo,
    this.status,
    this.allocatedQty,
  });

  final MaterialSupplyRoute? target;
  final String? actionId;
  final String? documentType;
  final String? documentId;
  final String? documentNo;
  final String? status;

  /// 该下游任务分摊到本物料行的数量（downstreamReferences 投影携带）。
  /// 用于估算「已提交在途量」，服务端仍以实时缺口−在途复核为准。
  final double? allocatedQty;

  factory MaterialAnalysisNotificationTarget.fromJson(
    Map<String, dynamic> json,
  ) => MaterialAnalysisNotificationTarget(
    target: MaterialSupplyRoute.fromWire(json['target'] ?? json['route']),
    actionId: _string(json['actionId']),
    documentType: _string(json['documentType']),
    documentId: _string(json['documentId']),
    documentNo: _string(json['documentNo']),
    status: _string(json['status']),
    allocatedQty: _double(json['allocatedQty']),
  );
}

/// 一条服务端物料供给行动的权威数量快照。
///
/// [requestedQty] 只表示本批生产需求；[safetyReplenishmentQty] 是独立、
/// 显式确认的公共安全库存补库，二者不得在客户端合并后丢失来源语义。
class MaterialAnalysisSupplyAction {
  const MaterialAnalysisSupplyAction({
    required this.actionId,
    this.actionGroupKey,
    this.generation = 0,
    this.predecessorActionId,
    this.route,
    this.status,
    this.goodsId,
    this.colorId,
    this.unitId,
    this.requestedQty = 0,
    this.safetyReplenishmentQty = 0,
    this.totalRequestedQty = 0,
    this.safetyStockSnapshotQty = 0,
    this.publicAvailableSnapshotQty = 0,
    this.openSafetySupplySnapshotQty = 0,
    this.publicSurplusQty = 0,
    this.publicSurplusExternalItemId,
    this.operationType,
    this.claimSourceActionId,
    this.needDate,
    this.documentType,
    this.documentId,
    this.documentNo,
  });

  final String actionId;
  final String? actionGroupKey;
  final int generation;
  final String? predecessorActionId;
  final MaterialSupplyRoute? route;
  final String? status;
  final String? goodsId;
  final String? colorId;
  final String? unitId;
  final double requestedQty;
  final double safetyReplenishmentQty;
  final double totalRequestedQty;
  final double safetyStockSnapshotQty;
  final double publicAvailableSnapshotQty;
  final double openSafetySupplySnapshotQty;
  final double publicSurplusQty;
  final String? publicSurplusExternalItemId;
  final String? operationType;
  final String? claimSourceActionId;
  final String? needDate;
  final String? documentType;
  final String? documentId;
  final String? documentNo;

  factory MaterialAnalysisSupplyAction.fromJson(Map<String, dynamic> json) =>
      MaterialAnalysisSupplyAction(
        actionId: _string(json['actionId'] ?? json['id']) ?? '',
        actionGroupKey: _string(json['actionGroupKey']),
        generation: _int(json['generation']) ?? 0,
        predecessorActionId: _string(json['predecessorActionId']),
        route: MaterialSupplyRoute.fromWire(json['route']),
        status: _string(json['status']),
        goodsId: _string(json['goodsId']),
        colorId: _string(json['colorId']),
        unitId: _string(json['unitId']),
        requestedQty: _double(json['requestedQty']) ?? 0,
        safetyReplenishmentQty: _double(json['safetyReplenishmentQty']) ?? 0,
        totalRequestedQty: _double(json['totalRequestedQty']) ?? 0,
        safetyStockSnapshotQty: _double(json['safetyStockSnapshotQty']) ?? 0,
        publicAvailableSnapshotQty:
            _double(json['publicAvailableSnapshotQty']) ?? 0,
        openSafetySupplySnapshotQty:
            _double(json['openSafetySupplySnapshotQty']) ?? 0,
        publicSurplusQty: _double(json['publicSurplusQty']) ?? 0,
        publicSurplusExternalItemId: _string(
          json['publicSurplusExternalItemId'],
        ),
        operationType: _string(json['operationType']),
        claimSourceActionId: _string(json['claimSourceActionId']),
        needDate: _string(json['needDate']),
        documentType: _string(json['documentType']),
        documentId: _string(json['documentId']),
        documentNo: _string(json['documentNo']),
      );
}

class ProductionMaterialAnalysisWarehouse {
  const ProductionMaterialAnalysisWarehouse({
    required this.warehouseId,
    this.warehouseName,
    this.selected = false,
    this.primary = false,
  });

  final String warehouseId;
  final String? warehouseName;
  final bool selected;
  final bool primary;

  factory ProductionMaterialAnalysisWarehouse.fromJson(
    Map<String, dynamic> json,
  ) => ProductionMaterialAnalysisWarehouse(
    warehouseId: _string(json['warehouseId'] ?? json['id']) ?? '',
    warehouseName: _string(json['warehouseName'] ?? json['name']),
    selected: json['selected'] == true,
    primary: json['primary'] == true,
  );
}

/// 物料供给全链路进度（只读投影）：从「提交需求」到「入库齐套」的逐步状态。
/// 服务端沿 行动→申请→订货→审批→预计到货→收货→质检→库存 链回溯；
/// 前端只展示，不在本地推算任何一步。
class MaterialSupplyProgress {
  const MaterialSupplyProgress({
    required this.materialLineId,
    required this.route,
    required this.steps,
    this.goodsCode,
    this.goodsName,
  });

  final String materialLineId;
  final String? goodsCode;
  final String? goodsName;

  /// BUY / SUBCONTRACT / MAKE；无下游任务时为 null（步骤全为待开始）。
  final String? route;
  final List<MaterialSupplyProgressStep> steps;

  factory MaterialSupplyProgress.fromJson(Map<String, dynamic> json) =>
      MaterialSupplyProgress(
        materialLineId: _string(json['materialLineId']) ?? '',
        goodsCode: _string(json['goodsCode']),
        goodsName: _string(json['goodsName']),
        route: _string(json['route']),
        steps: _mapList(json['steps'], MaterialSupplyProgressStep.fromJson),
      );
}

class MaterialSupplyProgressStep {
  const MaterialSupplyProgressStep({
    required this.key,
    required this.label,
    required this.state,
    this.detail,
    this.docNo,
    this.at,
    this.operatorName,
    this.documentType,
    this.documentId,
    this.receiptType,
  });

  final String key;
  final String label;

  /// DONE（已完成）/ CURRENT（进行中）/ WAITING（未开始）/ REJECTED（被驳回）。
  final String state;

  /// 该步骤的补充说明（数量、待办人等），无则为 null。
  final String? detail;
  final String? docNo;
  final String? at;

  /// 该步骤责任人姓名（提交人/采购人/审批人/收货人/下达人），无则 null。
  final String? operatorName;

  /// 可跳转单据的稳定类型与 UUID；docNo 只负责展示，不能反查关联。
  final String? documentType;
  final String? documentId;
  final String? receiptType;

  bool get isDone => state == 'DONE';
  bool get isCurrent => state == 'CURRENT';
  bool get isRejected => state == 'REJECTED';

  factory MaterialSupplyProgressStep.fromJson(Map<String, dynamic> json) =>
      MaterialSupplyProgressStep(
        key: _string(json['key']) ?? '',
        label: _string(json['label']) ?? '',
        state: (_string(json['state']) ?? 'WAITING').toUpperCase(),
        detail: _string(json['detail']),
        docNo: _string(json['docNo']),
        at: _string(json['at']),
        operatorName: _string(json['operatorName']),
        documentType: _string(json['documentType']),
        documentId: _string(json['documentId']),
        receiptType: _string(json['receiptType']),
      );
}

class MaterialRouteDecision {
  const MaterialRouteDecision({
    this.actionGroupKey,
    this.materialLineId,
    required this.route,
    this.reason,
  }) : assert(actionGroupKey != null || materialLineId != null);

  final String? actionGroupKey;
  final String? materialLineId;
  final MaterialSupplyRoute route;
  final String? reason;

  Map<String, dynamic> toJson() => {
    if (actionGroupKey != null) 'actionGroupKey': actionGroupKey,
    if (materialLineId != null) 'materialLineId': materialLineId,
    'route': route.wireName,
    if (reason != null && reason!.trim().isNotEmpty) 'reason': reason!.trim(),
  };
}

/// 提交采购/委外/自制时的指定数量：二选一标识操作组，
/// 服务端按「缺口 − 在途任务」实时余量复核，超出会被拒。
class MaterialSupplyQuantityInput {
  const MaterialSupplyQuantityInput({
    this.actionGroupKey,
    this.materialLineId,
    required this.qty,
    required this.safetyReplenishmentQty,
    this.publicExtraQty = 0,
  }) : assert(actionGroupKey != null || materialLineId != null);

  final String? actionGroupKey;
  final String? materialLineId;
  final double qty;
  final double safetyReplenishmentQty;
  final double publicExtraQty;

  Map<String, dynamic> toJson() => {
    if (actionGroupKey != null) 'actionGroupKey': actionGroupKey,
    if (materialLineId != null) 'materialLineId': materialLineId,
    'qty': qty,
    'safetyReplenishmentQty': safetyReplenishmentQty,
    'publicExtraQty': publicExtraQty,
  };
}

class MaterialAnalysisPlanItemInput {
  const MaterialAnalysisPlanItemInput({
    required this.analysisLineId,
    required this.qty,
    this.billDate,
    this.deliveryDate,
    this.departmentId,
    this.workshopName,
    this.workerId,
    this.teamDepartmentId,
    this.productNo,
  });

  final String analysisLineId;
  final double qty;
  final String? billDate;
  final String? deliveryDate;
  final String? departmentId;
  final String? workshopName;
  final String? workerId;
  final String? teamDepartmentId;
  final String? productNo;

  Map<String, dynamic> toJson() => {
    'analysisLineId': analysisLineId,
    'qty': qty,
    if (billDate != null) 'billDate': billDate,
    if (deliveryDate != null) 'deliveryDate': deliveryDate,
    if (departmentId != null) 'departmentId': departmentId,
    if (workshopName?.trim().isNotEmpty == true)
      'workshopName': workshopName!.trim(),
    if (workerId != null) 'workerId': workerId,
    if (teamDepartmentId != null) 'teamDepartmentId': teamDepartmentId,
    if (productNo?.trim().isNotEmpty == true) 'productNo': productNo!.trim(),
  };

  /// The preview endpoint validates quantities and binds an optional explicit
  /// product number into its fingerprint. Per-plan scheduling fields remain a
  /// final-generate concern.
  Map<String, dynamic> toQuantityJson() => {
    'analysisLineId': analysisLineId,
    'qty': qty,
    if (productNo?.trim().isNotEmpty == true) 'productNo': productNo!.trim(),
  };
}

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

bool _sameSourcePart(String? left, String? right, {bool foldCase = false}) {
  final normalizedLeft = _trimmedOrNull(left);
  final normalizedRight = _trimmedOrNull(right);
  if (normalizedLeft == null || normalizedRight == null) {
    return normalizedLeft == normalizedRight;
  }
  return foldCase
      ? normalizedLeft.toLowerCase() == normalizedRight.toLowerCase()
      : normalizedLeft == normalizedRight;
}

class ProductionMaterialPlanPreview {
  const ProductionMaterialPlanPreview({
    required this.analysisId,
    required this.version,
    required this.previewFingerprint,
    required this.analysisFingerprint,
    this.warehouseId,
    this.calculatedAt,
    this.allReady = false,
    this.items = const [],
    this.plans = const [],
    this.allowedActions = const {},
  });

  final String analysisId;
  final int version;
  final String previewFingerprint;
  final String analysisFingerprint;
  final String? warehouseId;
  final String? calculatedAt;
  final bool allReady;
  final List<ProductionMaterialPlanPreviewItem> items;
  final List<ProductionMaterialPlanPreviewPlan> plans;
  final Set<String> allowedActions;

  bool get canSchedule =>
      items.isNotEmpty && items.every((item) => item.canSchedule);

  /// 兼容旧调用名；生成计划的业务资格现在等同可排产，物料是否齐套另读
  /// [allReady] / [ProductionMaterialPlanPreviewItem.canGenerate]。
  bool get canGenerate => canSchedule;

  factory ProductionMaterialPlanPreview.fromJson(
    Map<String, dynamic> json,
  ) => ProductionMaterialPlanPreview(
    analysisId: _string(json['analysisId']) ?? '',
    version: _int(json['version']) ?? 0,
    previewFingerprint:
        _string(json['previewFingerprint'] ?? json['fingerprint']) ?? '',
    analysisFingerprint: _string(json['fingerprint']) ?? '',
    warehouseId: _string(json['warehouseId']),
    calculatedAt: _string(json['calculatedAt']),
    allReady: json['allReady'] == true,
    items: _mapList(json['items'], ProductionMaterialPlanPreviewItem.fromJson),
    plans: _mapList(json['plans'], ProductionMaterialPlanPreviewPlan.fromJson),
    allowedActions: _stringList(json['allowedActions']).toSet(),
  );
}

class ProductionMaterialPlanPreviewItem {
  const ProductionMaterialPlanPreviewItem({
    required this.analysisLineId,
    this.requestedQty = 0,
    this.readyNowQty = 0,
    this.selectedQty = 0,
    this.canGenerate = false,
    this.reason,
    this.serverCanSchedule,
    this.serverMaxSchedulableQty,
    this.scheduleBlockedReason,
  });

  final String analysisLineId;
  final double requestedQty;
  final double readyNowQty;
  final double selectedQty;

  /// 历史字段：仅表示当前所选数量是否真实齐套，不再代表能否先排产。
  final bool canGenerate;
  final String? reason;
  final bool? serverCanSchedule;
  final double? serverMaxSchedulableQty;
  final String? scheduleBlockedReason;

  bool get materialReady => canGenerate;
  String? get materialReadinessReason => reason;
  bool get canSchedule => serverCanSchedule ?? canGenerate;
  double get maxSchedulableQty => serverMaxSchedulableQty ?? readyNowQty;

  factory ProductionMaterialPlanPreviewItem.fromJson(
    Map<String, dynamic> json,
  ) => ProductionMaterialPlanPreviewItem(
    analysisLineId: _string(json['analysisLineId']) ?? '',
    requestedQty: _double(json['requestedQty']) ?? 0,
    readyNowQty: _double(json['readyNowQty']) ?? 0,
    selectedQty: _double(json['selectedQty']) ?? 0,
    canGenerate: json['canGenerate'] == true,
    reason: _string(json['reason']),
    serverCanSchedule: json.containsKey('canSchedule')
        ? json['canSchedule'] == true
        : null,
    serverMaxSchedulableQty: _double(json['maxSchedulableQty']),
    scheduleBlockedReason: _string(json['scheduleBlockedReason']),
  );
}

class ProductionMaterialPlanPreviewPlan {
  const ProductionMaterialPlanPreviewPlan({
    this.clientPlanKey,
    this.productGoodsId,
    this.qty = 0,
    this.readyNowQty = 0,
    this.segmentStatus,
  });

  final String? clientPlanKey;
  final String? productGoodsId;
  final double qty;
  final double readyNowQty;
  final String? segmentStatus;

  factory ProductionMaterialPlanPreviewPlan.fromJson(
    Map<String, dynamic> json,
  ) => ProductionMaterialPlanPreviewPlan(
    clientPlanKey: _string(json['clientPlanKey']),
    productGoodsId: _string(json['productGoodsId']),
    qty: _double(json['qty']) ?? 0,
    readyNowQty: _double(json['readyNowQty']) ?? 0,
    segmentStatus: _string(json['segmentStatus']),
  );
}

class ProductionMaterialGenerateResult {
  const ProductionMaterialGenerateResult({
    required this.analysis,
    this.plans = const [],
  });

  final ProductionMaterialAnalysisView analysis;
  final List<ProductionGeneratedPlanRef> plans;

  factory ProductionMaterialGenerateResult.fromJson(
    Map<String, dynamic> json,
  ) => ProductionMaterialGenerateResult(
    analysis: ProductionMaterialAnalysisView.fromJson(
      (json['analysis'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    plans: _mapList(json['plans'], ProductionGeneratedPlanRef.fromJson),
  );
}

class ProductionGeneratedPlanRef {
  const ProductionGeneratedPlanRef({
    required this.planId,
    this.planNo,
    this.status,
    this.packageId,
    this.segmentIds = const [],
    this.drawIds = const [],
    this.drawDocuments = const [],
  });

  final String planId;
  final String? planNo;

  /// 计划状态：DRAFT（待审核）/ APPROVED（已审核下达）。
  final String? status;
  final String? packageId;
  final List<String> segmentIds;
  final List<String> drawIds;

  /// 随计划包自动生成的物料提货单（领料单）可读列表；待审核计划为空。
  final List<ProductionGeneratedDrawRef> drawDocuments;

  factory ProductionGeneratedPlanRef.fromJson(Map<String, dynamic> json) =>
      ProductionGeneratedPlanRef(
        planId: _string(json['planId']) ?? '',
        planNo: _string(json['planNo'] ?? json['billNo']),
        status: _string(json['status']),
        packageId: _string(json['packageId']),
        segmentIds: _stringList(json['segmentIds']),
        drawIds: _stringList(json['drawIds']),
        drawDocuments: _mapList(
          json['drawDocuments'],
          ProductionGeneratedDrawRef.fromJson,
        ),
      );
}

class ProductionGeneratedDrawRef {
  const ProductionGeneratedDrawRef({required this.drawId, this.billNo});

  final String drawId;
  final String? billNo;

  factory ProductionGeneratedDrawRef.fromJson(Map<String, dynamic> json) =>
      ProductionGeneratedDrawRef(
        drawId: _string(json['drawId'] ?? json['id']) ?? '',
        billNo: _string(json['billNo'] ?? json['requestBillNo']),
      );
}

List<T> _mapList<T>(Object? raw, T Function(Map<String, dynamic>) mapper) =>
    (raw as List?)
        ?.whereType<Map<Object?, Object?>>()
        .map((value) => mapper(value.cast<String, dynamic>()))
        .toList(growable: false) ??
    const [];

List<MaterialAnalysisNotificationTarget> _notificationTargets(Object? raw) {
  final values = raw as List?;
  if (values == null) return const [];
  final result = <MaterialAnalysisNotificationTarget>[];
  for (final value in values) {
    if (value is Map<Object?, Object?>) {
      result.add(
        MaterialAnalysisNotificationTarget.fromJson(
          value.cast<String, dynamic>(),
        ),
      );
      continue;
    }
    final route = MaterialSupplyRoute.fromWire(value);
    if (route != null) {
      result.add(MaterialAnalysisNotificationTarget(target: route));
    }
  }
  return result;
}

double _demandSupplyGap(Map<String, dynamic> json) {
  final explicit = _double(json['demandSupplyGapQty']);
  if (explicit != null) return explicit > 0 ? explicit : 0;
  final required = _double(json['requiredQty']) ?? 0;
  final allocated = _double(json['allocatedAvailableQty']) ?? 0;
  final exactPegged = _double(json['exactPeggedQty']) ?? 0;
  final covered = allocated > exactPegged ? allocated : exactPegged;
  final gap = required - covered;
  return gap > 0 ? gap : 0;
}

String? _string(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

double? _double(Object? value) => switch (value) {
  final num number => number.toDouble(),
  final String text => double.tryParse(text),
  _ => null,
};

int? _int(Object? value) => switch (value) {
  final num number => number.toInt(),
  final String text => int.tryParse(text),
  _ => null,
};

bool? _boolOrNull(Object? value) => switch (value) {
  final bool flag => flag,
  final num number => number != 0,
  final String text when text.toLowerCase() == 'true' => true,
  final String text when text.toLowerCase() == 'false' => false,
  _ => null,
};

double _normaliseRatio(Object? value) {
  final ratio = _double(value) ?? 0;
  return normalizeProgressRatio(ratio);
}

double? _normaliseNullableRatio(Object? value) {
  final ratio = _double(value);
  return ratio == null ? null : normalizeProgressRatio(ratio);
}

List<String> _path(Object? value) {
  if (value is List) return value.map((item) => item.toString()).toList();
  final text = _string(value);
  if (text == null) return const [];
  return text
      .split(RegExp(r'\s*(?:>|/|→)\s*'))
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
}

List<String> _stringList(Object? value) =>
    (value as List?)?.map((item) => item.toString()).toList(growable: false) ??
    const [];
