import 'production_material_analysis.dart';

const materialAggregateMaxGroups = 500;
const materialAggregateMaxSources = 10000;

/// Packs whole independent material intents into one request, preserving order.
/// A material draft always stays inside one request. When its sources differ in
/// workshop, worker or overproduction rate it is sent as several request groups
/// (ADR-120 §8); [requestGroupsByKey] carries that count so the window never
/// exceeds the server's group limit. Missing entries count as one group.
List<String> materialAggregateRequestWindow(
  Map<String, int> sourcesByGroup, {
  Map<String, int> requestGroupsByKey = const {},
}) {
  for (final entry in sourcesByGroup.entries) {
    if (entry.value < 1 || entry.value > materialAggregateMaxSources) {
      throw ArgumentError.value(
        entry.value,
        entry.key,
        'material source scope must be 1..$materialAggregateMaxSources',
      );
    }
  }
  final result = <String>[];
  var sources = 0;
  var groups = 0;
  for (final entry in sourcesByGroup.entries) {
    final weight = requestGroupsByKey[entry.key] ?? 1;
    if (groups + weight > materialAggregateMaxGroups ||
        sources + entry.value > materialAggregateMaxSources) {
      break;
    }
    result.add(entry.key);
    sources += entry.value;
    groups += weight;
  }
  return result;
}

/// A visible total for exact source nodes. Decimal input stays text until the
/// server allocates its four-decimal source quantities and public remainder.
class MaterialAggregateOrderGroupInput {
  const MaterialAggregateOrderGroupInput({
    required this.clientGroupKey,
    required this.materialLineIds,
    required this.route,
    required this.qty,
    this.allowPublicExtra = false,
    this.departmentId,
    this.workerId,
    this.teamDepartmentId,
    this.billDate,
    this.deliveryDate,
    this.productNo,
    this.allowedOverproductionRate,
    this.safetyQty = '0',
    this.sourceRequestedQtyByMaterialLineId,
  });
  final String clientGroupKey, qty;
  final List<String> materialLineIds;
  final MaterialSupplyRoute route;
  final bool allowPublicExtra;
  final String? departmentId,
      workerId,
      teamDepartmentId,
      billDate,
      deliveryDate,
      productNo;
  final double? allowedOverproductionRate;
  final String safetyQty;
  final Map<String, String>? sourceRequestedQtyByMaterialLineId;

  Map<String, dynamic> toJson() => {
    'clientGroupKey': clientGroupKey,
    'materialLineIds': materialLineIds,
    'route': route.wireName,
    'qty': qty,
    'allowPublicExtra': allowPublicExtra,
    'departmentId': ?departmentId,
    'workerId': ?workerId,
    'teamDepartmentId': ?teamDepartmentId,
    'billDate': ?billDate,
    'deliveryDate': ?deliveryDate,
    'productNo': ?productNo,
    'allowedOverproductionRate': ?allowedOverproductionRate,
    'safetyQty': safetyQty,
    'sourceRequestedQtyByMaterialLineId': ?sourceRequestedQtyByMaterialLineId,
  };
}

class MaterialAggregateOrderRequest {
  const MaterialAggregateOrderRequest({
    required this.analysisId,
    required this.version,
    required this.fingerprint,
    required this.idempotencyKey,
    required this.warehouseId,
    required this.billDate,
    required this.groups,
    this.deliveryDate,
    this.approveNow = false,
    this.skipAutoClaim = false,
  });
  final String analysisId, fingerprint, idempotencyKey, warehouseId, billDate;
  final int version;
  final String? deliveryDate;
  final bool approveNow;

  /// ADR-099 修订(2026-09-29)：true = 用户选择「足额下单，不扣可用数量」，
  /// 服务端跳过汇总提交里的自动认领（自制公共超产/同主仓公共在途）；
  /// 缺省 false = 原行为（先认领、只为余量新下单）。
  final bool skipAutoClaim;
  final List<MaterialAggregateOrderGroupInput> groups;
  Map<String, dynamic> toJson({String? previewFingerprint}) => {
    'version': version,
    'fingerprint': fingerprint,
    'idempotencyKey': idempotencyKey,
    'warehouseId': warehouseId,
    'billDate': billDate,
    'deliveryDate': ?deliveryDate,
    'approveNow': approveNow,
    'groups': [for (final group in groups) group.toJson()],
    'previewFingerprint': ?previewFingerprint,
    if (skipAutoClaim) 'skipAutoClaim': true,
  };
}

class MaterialAggregateSourceAllocation {
  MaterialAggregateSourceAllocation.fromJson(Map<String, dynamic> json)
    : materialLineId = json['materialLineId'] as String,
      hasOriginalMaterialLineIds = json.containsKey('originalMaterialLineIds'),
      originalMaterialLineIds = List<String>.from(
        json.containsKey('originalMaterialLineIds')
            ? json['originalMaterialLineIds'] as List? ?? const []
            : [json['materialLineId'] as String],
      ),
      analysisLineId = json['analysisLineId'] as String?,
      sourceLabel = json['sourceLabel'] as String? ?? '',
      allocationPriority = (json['allocationPriority'] as num?)?.toInt() ?? 0,
      needDate = json['needDate'] as String?,
      sourceRequiredQty = _amount(json['sourceRequiredQty']),
      remainingQty = _amount(json['remainingQty']),
      allocatedQty = _amount(json['allocatedQty']),
      orderedQty = _amount(json['orderedQty']);
  final String materialLineId, sourceLabel;

  /// Exact original request identities represented by this effective ledger row.
  final List<String> originalMaterialLineIds;
  final bool hasOriginalMaterialLineIds;
  final String? analysisLineId, needDate;
  final int allocationPriority;
  final double sourceRequiredQty, remainingQty, allocatedQty, orderedQty;
}

class MaterialAggregateChildRequirement {
  MaterialAggregateChildRequirement.fromJson(Map<String, dynamic> json)
    : materialLineId = json['materialLineId'] as String?,
      goodsId = json['goodsId'] as String,
      goodsCode = json['goodsCode'] as String? ?? '',
      goodsName = json['goodsName'] as String? ?? '',
      colorId = json['colorId'] as String?,
      colorName = json['colorName'] as String? ?? '',
      unitId = json['unitId'] as String?,
      unitName = json['unitName'] as String? ?? '',
      relativeBomPath = json['relativeBomPath'] as String? ?? '',
      controlStage = json['controlStage'] as String? ?? '',
      consumptionBasis = json['consumptionBasis'] as String? ?? '',
      bomQty = _amount(json['bomQty']),
      basisOutputQty = _amount(json['basisOutputQty']),
      allowPartialPackage = json['allowPartialPackage'] == true,
      requiredQty = _amount(json['requiredQty']);
  final String? materialLineId, colorId, unitId;
  final String goodsId,
      goodsCode,
      goodsName,
      colorName,
      unitName,
      relativeBomPath,
      controlStage,
      consumptionBasis;
  final double bomQty, basisOutputQty, requiredQty;
  final bool allowPartialPackage;
}

class MaterialAggregateOrderGroupPreview {
  MaterialAggregateOrderGroupPreview.fromJson(Map<String, dynamic> json)
    : clientGroupKey = json['clientGroupKey'] as String,
      compatibilityKey = json['compatibilityKey'] as String? ?? '',
      route = MaterialSupplyRoute.fromWire(json['route']),
      goodsId = json['goodsId'] as String,
      goodsCode = json['goodsCode'] as String? ?? '',
      goodsName = json['goodsName'] as String? ?? '',
      colorId = json['colorId'] as String?,
      colorName = json['colorName'] as String? ?? '',
      unitId = json['unitId'] as String?,
      unitName = json['unitName'] as String? ?? '',
      sourceRequiredQty = _amount(json['sourceRequiredQty']),
      orderedQty = _amount(json['orderedQty']),
      remainingQty = _amount(json['remainingQty']),
      requestedQty = _amount(json['requestedQty']),
      publicExtraQty = _amount(json['publicExtraQty']),
      safetyQty = _amount(json['safetyQty']),
      departmentId = json['departmentId'] as String?,
      workerId = json['workerId'] as String?,
      teamDepartmentId = json['teamDepartmentId'] as String?,
      billDate = json['billDate'] as String?,
      deliveryDate = json['deliveryDate'] as String?,
      productNo = json['productNo'] as String?,
      allowedOverproductionRate = (json['allowedOverproductionRate'] as num?)
          ?.toDouble(),
      sources = _list(
        json['sources'],
        MaterialAggregateSourceAllocation.fromJson,
      ),
      sharedBomChildren = _list(
        json['sharedBomChildren'],
        MaterialAggregateChildRequirement.fromJson,
      ),
      blockedReason = json['blockedReason'] as String?,
      existingBatchId = json['existingBatchId'] as String?,
      priorOutputQty = _amount(json['priorOutputQty']);
  final String clientGroupKey,
      compatibilityKey,
      goodsId,
      goodsCode,
      goodsName,
      colorName,
      unitName;
  final MaterialSupplyRoute? route;
  final String? colorId,
      unitId,
      departmentId,
      workerId,
      teamDepartmentId,
      billDate,
      deliveryDate,
      productNo,
      blockedReason;
  final double sourceRequiredQty,
      orderedQty,
      remainingQty,
      requestedQty,
      publicExtraQty,
      safetyQty;
  final double? allowedOverproductionRate;
  final List<MaterialAggregateSourceAllocation> sources;
  final List<MaterialAggregateChildRequirement> sharedBomChildren;
  final String? existingBatchId;
  final double priorOutputQty;
}

class MaterialAggregateOrderPreview {
  MaterialAggregateOrderPreview.fromJson(Map<String, dynamic> json)
    : analysisId = json['analysisId'] as String,
      version = (json['version'] as num).toInt(),
      fingerprint = json['fingerprint'] as String,
      previewFingerprint = json['previewFingerprint'] as String,
      groups = _list(
        json['groups'],
        MaterialAggregateOrderGroupPreview.fromJson,
      ),
      analysis = ProductionMaterialAnalysisView.fromJson(
        Map<String, dynamic>.from(json['analysis'] as Map),
      );
  final String analysisId, fingerprint, previewFingerprint;
  final int version;
  final List<MaterialAggregateOrderGroupPreview> groups;
  final ProductionMaterialAnalysisView analysis;
}

class MaterialAggregateOrderBatch {
  MaterialAggregateOrderBatch.fromJson(Map<String, dynamic> json)
    : batchId = json['batchId'] as String?,
      clientGroupKey = json['clientGroupKey'] as String,
      route = MaterialSupplyRoute.fromWire(json['route']),
      documentType = json['documentType'] as String? ?? '',
      documentId = json['documentId'] as String?,
      documentNo = json['documentNo'] as String? ?? '',
      planId = json['planId'] as String?,
      anchorAnalysisItemId = json['anchorAnalysisItemId'] as String?,
      qty = _amount(json['qty']),
      publicExtraQty = _amount(json['publicExtraQty']),
      generatedPlan = json['generatedPlan'] is Map
          ? ProductionGeneratedPlanRef.fromJson(
              Map<String, dynamic>.from(json['generatedPlan'] as Map),
            )
          : null,
      sources = _list(
        json['sources'],
        MaterialAggregateSourceAllocation.fromJson,
      );
  final String clientGroupKey, documentType, documentNo;
  final String? batchId, documentId, planId, anchorAnalysisItemId;
  final MaterialSupplyRoute? route;
  final double qty, publicExtraQty;
  final ProductionGeneratedPlanRef? generatedPlan;
  final List<MaterialAggregateSourceAllocation> sources;
}

class MaterialAggregateOrderResult {
  MaterialAggregateOrderResult.fromJson(Map<String, dynamic> json)
    : analysis = ProductionMaterialAnalysisView.fromJson(
        Map<String, dynamic>.from(json['analysis'] as Map),
      ),
      replayed = json['replayed'] == true,
      batches = _list(json['batches'], MaterialAggregateOrderBatch.fromJson),
      materialIdentityBridges = _list(
        json['materialIdentityBridges'],
        MaterialAggregateIdentityBridge.fromJson,
      );
  final ProductionMaterialAnalysisView analysis;
  final bool replayed;
  final List<MaterialAggregateOrderBatch> batches;
  final List<MaterialAggregateIdentityBridge> materialIdentityBridges;
}

class MaterialAggregateIdentityBridge {
  MaterialAggregateIdentityBridge.fromJson(Map<String, dynamic> json)
    : fromMaterialLineIds = List<String>.from(
        json['fromMaterialLineIds'] as List? ?? const [],
      ),
      toMaterialLineId = json['toMaterialLineId'] as String,
      relativeBomPath = json['relativeBomPath'] as String? ?? '',
      requiredQty = _amount(json['requiredQty']);
  final List<String> fromMaterialLineIds;
  final String toMaterialLineId, relativeBomPath;
  final double requiredQty;
}

double _amount(Object? value) => (value as num?)?.toDouble() ?? 0;
List<T> _list<T>(Object? value, T Function(Map<String, dynamic>) decode) => [
  for (final item in value as List? ?? const [])
    decode(Map<String, dynamic>.from(item as Map)),
];
