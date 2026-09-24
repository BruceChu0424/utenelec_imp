import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/models/paged_result.dart';

const productionMaterialIncrementPermission =
    'production_execution:request_material_increment';
const productionMaterialIncrementRefreshKey = 'production:material-increment';

class ProductionMaterialIncrementContext {
  ProductionMaterialIncrementContext(this.data);
  final Map<String, dynamic> data;
  String get segmentId => data['segmentId'] as String;
  String? get segmentCode => data['segmentCode'] as String?;
  String? get supplementProofId => data['supplementProofId'] as String?;
  String? get blockingReason => data['blockingReason'] as String?;
  bool get canSubmit => data['canSubmit'] == true;
  List<Map<String, dynamic>> get demands => (data['demands'] as List)
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList();
}

class ProductionMaterialIncrementRequest {
  ProductionMaterialIncrementRequest(this.data);
  final Map<String, dynamic> data;
  String get id => data['id'] as String;
  String get originalDemandId => data['originalDemandId'] as String;
  String get targetSegmentId => data['targetSegmentId'] as String;
  String get status => data['status'] as String;
  int get rowVersion => (data['rowVersion'] as num).toInt();
  bool get canApprove => data['canApprove'] == true;
  bool get canReturn => data['canReturn'] == true;
  bool get canCancel => data['canCancel'] == true;
  String text(String key) => data[key]?.toString() ?? '—';
  List<Map<String, dynamic>>? snapshotItems(String key) {
    Object? snapshot = data[key];
    if (snapshot is String) {
      try {
        snapshot = jsonDecode(snapshot);
      } on FormatException {
        return null;
      }
    }
    if (snapshot is! Map || snapshot['items'] is! List) return null;
    final rows = snapshot['items'] as List;
    if (rows.length != 1 || rows.single is! Map) return null;
    final row = Map<String, dynamic>.from(rows.single as Map);
    if (row['itemId'] != originalDemandId) return null;
    for (final key in [
      'requiredQty',
      'approvedIncrementQty',
      'authorizedQty',
    ]) {
      final value = num.tryParse(row[key]?.toString() ?? '');
      if (value == null || !value.isFinite || value < 0) return null;
    }
    return [row];
  }
}

class ProductionMaterialIncrementRepository {
  ProductionMaterialIncrementRepository(this.api);
  final ApiClient api;
  static const _base = '/production/material-increments';

  Future<ProductionMaterialIncrementContext> context(String segmentId) async =>
      ProductionMaterialIncrementContext(
        await api.get('$_base/segments/$segmentId/context'),
      );
  Future<ProductionMaterialIncrementRequest> detail(String id) async =>
      ProductionMaterialIncrementRequest(await api.get('$_base/requests/$id'));
  Future<ProductionMaterialIncrementRequest> cancel(
    ProductionMaterialIncrementRequest request,
    String reason,
  ) async => ProductionMaterialIncrementRequest(
    await api.post(
      '$_base/requests/${request.id}/cancel',
      body: {
        'expectedVersion': request.rowVersion,
        'reason': reason,
        'idempotencyKey': businessIdempotencyKey(
          'material-increment-cancel',
          '${request.id}|${request.rowVersion}|$reason',
        ),
      },
    ),
  );
  Future<PagedResult<ProductionMaterialIncrementRequest>> list({
    String status = 'PENDING',
    int page = 1,
  }) async => PagedResult.fromJson(
    await api.get(
      '$_base/requests',
      query: {'status': status, 'page': page, 'size': 20},
    ),
    ProductionMaterialIncrementRequest.new,
  );
  Future<ProductionMaterialIncrementRequest> submit({
    required ProductionMaterialIncrementContext context,
    required Map<String, dynamic> demand,
    required double deltaQty,
    required String reason,
  }) async => ProductionMaterialIncrementRequest(
    await api.post(
      '$_base/requests',
      body: {
        'originalDemandId': demand['originalDemandId'],
        'targetSegmentId': context.segmentId,
        'supplementProofId': ?context.supplementProofId,
        'deltaQty': deltaQty,
        'reason': reason,
        'expectedDemandVersion': demand['lockVersion'],
        'idempotencyKey': businessIdempotencyKey(
          'material-increment-request',
          '${demand['originalDemandId']}|${context.segmentId}|${context.supplementProofId}|${demand['lockVersion']}|${demand['requestGeneration']}|${demand['approvedIncrementQty']}|$deltaQty|$reason',
        ),
      },
    ),
  );
  Future<ProductionMaterialIncrementRequest> decide(
    ProductionMaterialIncrementRequest request, {
    required bool approve,
    required String reason,
  }) async => ProductionMaterialIncrementRequest(
    await api.post(
      '$_base/requests/${request.id}/${approve ? 'approve' : 'return'}',
      body: {
        'expectedVersion': request.rowVersion,
        'reason': reason,
        'idempotencyKey': businessIdempotencyKey(
          'material-increment-decision',
          '${request.id}|${request.rowVersion}|$approve|$reason',
        ),
      },
    ),
  );
}

final productionMaterialIncrementRepositoryProvider =
    Provider<ProductionMaterialIncrementRepository>(
      (ref) =>
          ProductionMaterialIncrementRepository(ref.watch(apiClientProvider)),
    );
