import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/models/paged_result.dart';

const productionOverproductionRateRefreshKey = 'production:overproduction-rate';
const productionOverproductionRateRequestPermission =
    'production_execution:request_overproduction_rate';

double? productionRateNumber(Object? value) => value is num
    ? value.toDouble()
    : value is String
    ? double.tryParse(value)
    : null;

String productionRateText(double? rate) {
  if (rate == null || !rate.isFinite) return '—';
  final value = (rate * 100)
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
  return '$value%';
}

String productionRateStatus(String? status) => switch (status) {
  'PENDING' => '待计划部审批',
  'APPROVED' => '已通过',
  'RETURNED' => '已退回',
  _ => '状态待核对',
};

class ProductionOverproductionRateContext {
  ProductionOverproductionRateContext(this.data);
  final Map<String, dynamic> data;
  String get segmentId => data['segmentId'] as String;
  String? get segmentCode => data['segmentCode'] as String?;
  double? get effectiveRate => productionRateNumber(data['effectiveRate']);
  double? get pendingRate => productionRateNumber(data['pendingRate']);
  String? get pendingRequestId => data['pendingRequestId'] as String?;
  int get rateVersion => (data['rateVersion'] as num).toInt();
  int get requestGeneration =>
      (data['requestGeneration'] as num?)?.toInt() ?? 0;
  bool get canSubmit => data['canSubmit'] == true;
}

class ProductionOverproductionRateRequest {
  ProductionOverproductionRateRequest(this.data);
  final Map<String, dynamic> data;
  String get id => data['id'] as String;
  String get segmentId => data['segmentId'] as String;
  String? get planNo => data['planNo'] as String?;
  String? get segmentCode => data['segmentCode'] as String?;
  String? get goodsName => data['goodsName'] as String?;
  String? get goodsCode => data['goodsCode'] as String?;
  String? get status => data['status'] as String?;
  String? get reason => data['reason'] as String?;
  String? get submittedByName => data['submittedByName'] as String?;
  String? get submittedAt => data['submittedAt'] as String?;
  String? get decisionReason => data['decisionReason'] as String?;
  String? get blockingReason => data['blockingReason'] as String?;
  double? get beforeRate => productionRateNumber(data['beforeRate']);
  double? get requestedRate => productionRateNumber(data['requestedRate']);
  int get rowVersion => (data['rowVersion'] as num).toInt();
  bool get canApprove => data['canApprove'] == true;
  bool get canReturn => data['canReturn'] == true;

  List<Map<String, dynamic>>? snapshotItems(String key) {
    Object? value = data[key];
    if (value is String) {
      try {
        value = jsonDecode(value);
      } on FormatException {
        return null;
      }
    }
    if (value is! Map || value['items'] is! List) return null;
    final rows = (value['items'] as List)
        .whereType<Map<dynamic, dynamic>>()
        .toList();
    if (rows.isEmpty || rows.length != (value['items'] as List).length) {
      return null;
    }
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }
}

class ProductionOverproductionRateRepository {
  ProductionOverproductionRateRepository(this.api);
  final ApiClient api;
  static const _base = '/production/overproduction-rate';

  Future<ProductionOverproductionRateContext> context(String segmentId) async =>
      ProductionOverproductionRateContext(
        await api.get('$_base/segments/$segmentId'),
      );
  Future<ProductionOverproductionRateRequest> detail(String id) async =>
      ProductionOverproductionRateRequest(await api.get('$_base/requests/$id'));
  Future<PagedResult<ProductionOverproductionRateRequest>> list({
    String status = 'PENDING',
    int page = 1,
    int size = 20,
  }) async => PagedResult.fromJson(
    await api.get(
      '$_base/requests',
      query: {'status': status, 'page': page, 'size': size},
    ),
    ProductionOverproductionRateRequest.new,
  );

  Future<ProductionOverproductionRateRequest> submit(
    ProductionOverproductionRateContext context,
    double rate,
    String reason,
  ) async => ProductionOverproductionRateRequest(
    await api.post(
      '$_base/requests',
      body: {
        'segmentId': context.segmentId,
        'expectedRateVersion': context.rateVersion,
        'requestedRate': rate,
        'reason': reason,
        'idempotencyKey': businessIdempotencyKey(
          'production-rate-request',
          '${context.segmentId}|${context.rateVersion}|${context.requestGeneration}|$rate|$reason',
        ),
      },
    ),
  );

  Future<ProductionOverproductionRateRequest> decide(
    ProductionOverproductionRateRequest request, {
    required bool approve,
    String reason = '',
  }) async => ProductionOverproductionRateRequest(
    await api.post(
      '$_base/requests/${request.id}/${approve ? 'approve' : 'return'}',
      body: {
        'expectedVersion': request.rowVersion,
        'idempotencyKey': businessIdempotencyKey(
          'production-rate-decision',
          '${request.id}|${request.rowVersion}|$approve|$reason',
        ),
        'reason': reason,
      },
    ),
  );
}

final productionOverproductionRateRepositoryProvider =
    Provider<ProductionOverproductionRateRepository>(
      (ref) =>
          ProductionOverproductionRateRepository(ref.watch(apiClientProvider)),
    );
