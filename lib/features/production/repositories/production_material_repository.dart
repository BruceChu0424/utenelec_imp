import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/production_direct_transfer_candidate.dart';
import '../models/production_material_usage_source.dart';
import '../models/production_material_return.dart';

class ProductionMaterialCapabilities {
  const ProductionMaterialCapabilities({
    this.canSettle = false,
    this.canReverse = false,
    this.canClose = false,
    this.canRequestReturn = false,
  });
  final bool canSettle;
  final bool canReverse;
  final bool canClose;
  final bool canRequestReturn;
  factory ProductionMaterialCapabilities.fromJson(Map<String, dynamic> json) =>
      ProductionMaterialCapabilities(
        canSettle: json['canSettle'] == true,
        canReverse: json['canReverse'] == true,
        canClose: json['canClose'] == true,
        canRequestReturn: json['canRequestReturn'] == true,
      );
}

class ProductionMaterialClearanceRow {
  const ProductionMaterialClearanceRow({
    required this.planId,
    required this.demandId,
    required this.goodsId,
    required this.requiredQty,
    required this.issuedQty,
    required this.returnedQty,
    required this.consumedQty,
    required this.approvedLossQty,
    required this.legalWipQty,
    required this.maxReturnQty,
    required this.unclearedQty,
    required this.canClose,
    this.goodsCode,
    this.goodsName,
    this.colorId,
    this.colorName,
    this.executionSegmentId,
    this.executionSegmentCode,
    this.unitName,
    this.pendingReturnQty = 0,
    double? availableToSettleQty,
  }) : availableToSettleQty =
           availableToSettleQty ??
           (unclearedQty > pendingReturnQty
               ? unclearedQty - pendingReturnQty
               : 0);

  final String planId;
  final String demandId;
  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorId;
  final String? colorName;
  final String? executionSegmentId;
  final String? executionSegmentCode;

  /// The base unit saved on this material demand, not a display-unit conversion.
  final String? unitName;
  final double requiredQty;
  final double issuedQty;
  final double returnedQty;
  final double consumedQty;
  final double approvedLossQty;
  final double legalWipQty;
  final double maxReturnQty;
  final double unclearedQty;
  final double pendingReturnQty;
  final double availableToSettleQty;
  final bool canClose;

  factory ProductionMaterialClearanceRow.fromJson(Map<String, dynamic> json) {
    double number(String key) => (json[key] as num?)?.toDouble() ?? 0;
    return ProductionMaterialClearanceRow(
      planId: json['planId'] as String,
      demandId: json['demandId'] as String,
      goodsId: json['goodsId'] as String,
      goodsCode: json['goodsCode'] as String?,
      goodsName: json['goodsName'] as String?,
      colorId: json['colorId'] as String?,
      colorName: json['colorName'] as String?,
      executionSegmentId: json['executionSegmentId'] as String?,
      executionSegmentCode: json['executionSegmentCode'] as String?,
      unitName: json['unitName'] as String?,
      requiredQty: number('requiredQty'),
      issuedQty: number('issuedQty'),
      returnedQty: number('returnedQty'),
      consumedQty: number('consumedQty'),
      approvedLossQty: number('approvedLossQty'),
      legalWipQty: number('legalWipQty'),
      maxReturnQty: number('maxReturnQty'),
      unclearedQty: number('unclearedQty'),
      pendingReturnQty: number('pendingReturnQty'),
      availableToSettleQty: json['availableToSettleQty'] == null
          ? (number('unclearedQty') - number('pendingReturnQty')).clamp(
              0,
              double.infinity,
            )
          : number('availableToSettleQty'),
      canClose: json['canClose'] == true,
    );
  }
}

class ProductionMaterialSettlementSource {
  const ProductionMaterialSettlementSource({
    required this.postingId,
    required this.eventId,
    required this.demandId,
    required this.goodsId,
    required this.settlementType,
    required this.postedQtyBase,
    required this.reversedQtyBase,
    required this.reversibleQtyBase,
    required this.createdAt,
    this.goodsCode,
    this.goodsName,
    this.colorId,
    this.colorName,
    this.reason,
    this.createdBy,
    this.executionSegmentId,
    this.executionSegmentCode,
    this.unitName,
  });

  final String postingId;
  final String eventId;
  final String demandId;
  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorId;
  final String? colorName;
  final String settlementType;
  final double postedQtyBase;
  final double reversedQtyBase;
  final double reversibleQtyBase;
  final String? reason;
  final String createdAt;
  final String? createdBy;
  final String? executionSegmentId;
  final String? executionSegmentCode;
  final String? unitName;

  factory ProductionMaterialSettlementSource.fromJson(
    Map<String, dynamic> json,
  ) {
    double number(String key) => (json[key] as num?)?.toDouble() ?? 0;
    return ProductionMaterialSettlementSource(
      postingId: json['postingId'] as String,
      eventId: json['eventId'] as String,
      demandId: json['demandId'] as String,
      goodsId: json['goodsId'] as String,
      goodsCode: json['goodsCode'] as String?,
      goodsName: json['goodsName'] as String?,
      colorId: json['colorId'] as String?,
      colorName: json['colorName'] as String?,
      settlementType: json['settlementType']?.toString() ?? '',
      postedQtyBase: number('postedQtyBase'),
      reversedQtyBase: number('reversedQtyBase'),
      reversibleQtyBase: number('reversibleQtyBase'),
      reason: json['reason'] as String?,
      createdAt: json['createdAt']?.toString() ?? '',
      createdBy: json['createdBy'] as String?,
      executionSegmentId: json['executionSegmentId'] as String?,
      executionSegmentCode: json['executionSegmentCode'] as String?,
      unitName: json['unitName'] as String?,
    );
  }
}

class ProductionMaterialSettlementLine {
  const ProductionMaterialSettlementLine({
    required this.demandId,
    required this.settlementType,
    required this.qtyBase,
    this.sourcePostingId,
  });

  final String demandId;
  final String settlementType;
  final double qtyBase;
  final String? sourcePostingId;

  Map<String, dynamic> toJson() => {
    'demandId': demandId,
    'settlementType': settlementType,
    'qtyBase': qtyBase,
    'sourcePostingId': ?sourcePostingId,
  };
}

class ProductionMaterialRepository {
  ProductionMaterialRepository(this.api);

  final ApiClient api;

  Future<List<ProductionMaterialUsageSource>> materialUsageSources(
    String planId, {
    required String executionSegmentId,
  }) async {
    final rows = await api.getList(
      '/stock/production-materials/plans/$planId/material-usage-sources',
      query: {'executionSegmentId': executionSegmentId},
    );
    return rows
        .map(ProductionMaterialUsageSource.fromJson)
        .toList(growable: false);
  }

  /// 报工页「转下一道工序」的候选上层工单(V584/V585)。
  /// 服务端只返回同车间、同货品同颜色、还缺料的工单——跨车间必须走仓库。
  /// 候选为空且 [DirectTransferCandidatesResult.lineSideWarehouseMissing]
  /// 时，是本车间缺同主仓线边仓，不是没有上层工单可投。
  Future<DirectTransferCandidatesResult> directTransferCandidates({
    required String executionSegmentId,
    required String goodsId,
    String? colorId,
  }) async {
    final json = await api.get(
      '/production/direct-transfers/candidates',
      query: {
        'executionSegmentId': executionSegmentId,
        'goodsId': goodsId,
        'colorId': ?colorId,
      },
    );
    return DirectTransferCandidatesResult.fromJson(json);
  }

  Future<ProductionMaterialCapabilities> capabilities(
    String planId, {
    String? executionSegmentId,
  }) async => ProductionMaterialCapabilities.fromJson(
    await api.get(
      ApiEndpoints.productionMaterialCapabilities(planId),
      query: {'executionSegmentId': ?executionSegmentId},
    ),
  );

  Future<List<ProductionMaterialClearanceRow>> clearance(
    String planId, {
    String? executionSegmentId,
  }) async {
    final list = await api.getList(
      ApiEndpoints.productionMaterialClearance(planId),
      query: {'executionSegmentId': ?executionSegmentId},
    );
    return list.map(ProductionMaterialClearanceRow.fromJson).toList();
  }

  Future<List<ProductionMaterialSettlementSource>> settlementSources(
    String planId, {
    String? executionSegmentId,
  }) async {
    final list = await api.getList(
      ApiEndpoints.productionMaterialSettlements(planId),
      query: {'executionSegmentId': ?executionSegmentId},
    );
    return list.map(ProductionMaterialSettlementSource.fromJson).toList();
  }

  Future<List<ProductionMaterialClearanceRow>> settle(
    String planId, {
    required String idempotencyKey,
    required List<ProductionMaterialSettlementLine> lines,
    String? reason,
    String? executionSegmentId,
  }) async {
    final list = await api.postList(
      ApiEndpoints.productionMaterialSettlements(planId),
      body: {
        'idempotencyKey': idempotencyKey,
        'reason': ?reason,
        'executionSegmentId': ?executionSegmentId,
        'lines': [for (final line in lines) line.toJson()],
      },
    );
    return list.map(ProductionMaterialClearanceRow.fromJson).toList();
  }

  Future<List<ProductionMaterialClearanceRow>> reverseSettlement(
    String planId, {
    required String idempotencyKey,
    required List<ProductionMaterialSettlementLine> lines,
    String? reason,
    String? executionSegmentId,
  }) async {
    final list = await api.postList(
      ApiEndpoints.productionMaterialSettlementReverse(planId),
      body: {
        'idempotencyKey': idempotencyKey,
        'reason': ?reason,
        'executionSegmentId': ?executionSegmentId,
        'lines': [for (final line in lines) line.toJson()],
      },
    );
    return list.map(ProductionMaterialClearanceRow.fromJson).toList();
  }

  Future<List<ProductionMaterialClearanceRow>> close(String planId) async {
    final list = await api.postList(
      ApiEndpoints.productionMaterialClose(planId),
    );
    return list.map(ProductionMaterialClearanceRow.fromJson).toList();
  }

  String _returnsPath(String planId) =>
      '/stock/production-materials/plans/$planId/return-requests';

  Future<List<ProductionMaterialReturnSource>> returnSources(
    String planId, {
    String? executionSegmentId,
  }) async => (await api.getList(
    '${_returnsPath(planId)}/sources',
    query: {'executionSegmentId': ?executionSegmentId},
  )).map(ProductionMaterialReturnSource.fromJson).toList();

  Future<List<ProductionMaterialReturnDocument>> returnRequests(
    String planId, {
    String? executionSegmentId,
  }) async => (await api.getList(
    _returnsPath(planId),
    query: {'executionSegmentId': ?executionSegmentId},
  )).map(ProductionMaterialReturnDocument.fromJson).toList();

  Future<List<ProductionMaterialReturnDocument>> requestReturn(
    String planId, {
    required String idempotencyKey,
    required List<Map<String, dynamic>> items,
    String? executionSegmentId,
    String? reason,
  }) async => (await api.postList(
    _returnsPath(planId),
    body: {
      'idempotencyKey': idempotencyKey,
      'executionSegmentId': ?executionSegmentId,
      'reason': ?reason,
      'items': items,
    },
  )).map(ProductionMaterialReturnDocument.fromJson).toList();

  Future<ProductionMaterialReturnDocument> cancelReturn(
    String planId,
    String documentId, {
    required String idempotencyKey,
    required String reason,
  }) async => ProductionMaterialReturnDocument.fromJson(
    await api.post(
      '${_returnsPath(planId)}/$documentId/cancel',
      body: {'idempotencyKey': idempotencyKey, 'reason': reason},
    ),
  );
}

final productionMaterialRepositoryProvider =
    Provider<ProductionMaterialRepository>(
      (ref) => ProductionMaterialRepository(ref.watch(apiClientProvider)),
    );
