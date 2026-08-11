import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';

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
  });

  final String planId;
  final String demandId;
  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorId;
  final String? colorName;
  final String? executionSegmentId;
  final String? executionSegmentCode;
  final double requiredQty;
  final double issuedQty;
  final double returnedQty;
  final double consumedQty;
  final double approvedLossQty;
  final double legalWipQty;
  final double maxReturnQty;
  final double unclearedQty;
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
      requiredQty: number('requiredQty'),
      issuedQty: number('issuedQty'),
      returnedQty: number('returnedQty'),
      consumedQty: number('consumedQty'),
      approvedLossQty: number('approvedLossQty'),
      legalWipQty: number('legalWipQty'),
      maxReturnQty: number('maxReturnQty'),
      unclearedQty: number('unclearedQty'),
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

  Future<List<ProductionMaterialClearanceRow>> clearance(String planId) async {
    final list = await api.getList(
      ApiEndpoints.productionMaterialClearance(planId),
    );
    return list.map(ProductionMaterialClearanceRow.fromJson).toList();
  }

  Future<List<ProductionMaterialSettlementSource>> settlementSources(
    String planId,
  ) async {
    final list = await api.getList(
      ApiEndpoints.productionMaterialSettlements(planId),
    );
    return list.map(ProductionMaterialSettlementSource.fromJson).toList();
  }

  Future<List<ProductionMaterialClearanceRow>> settle(
    String planId, {
    required String idempotencyKey,
    required List<ProductionMaterialSettlementLine> lines,
    String? reason,
  }) async {
    final list = await api.postList(
      ApiEndpoints.productionMaterialSettlements(planId),
      body: {
        'idempotencyKey': idempotencyKey,
        'reason': ?reason,
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
  }) async {
    final list = await api.postList(
      ApiEndpoints.productionMaterialSettlementReverse(planId),
      body: {
        'idempotencyKey': idempotencyKey,
        'reason': ?reason,
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
}

final productionMaterialRepositoryProvider =
    Provider<ProductionMaterialRepository>(
      (ref) => ProductionMaterialRepository(ref.watch(apiClientProvider)),
    );
