import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/utils/idempotency_key.dart';
import 'production_overproduction_rate_repository.dart';
import '../models/reportable_plan_line.dart';

const productionSupplementRequestPermission =
    'production_execution:request_supplement_plan';

class ProductionOutputSupplementPreview {
  ProductionOutputSupplementPreview(this.data);
  final Map<String, dynamic> data;
  String get sourceSegmentId => data['sourceSegmentId'] as String;
  String get fingerprint => data['fingerprint'] as String;
  String? get sourceSalesAllocationId =>
      data['sourceSalesAllocationId'] as String?;
  double get actualQty => productionRateNumber(data['actualQty'])!;
  double get plannedQty => productionRateNumber(data['plannedQty'])!;
  double get originalReportQty =>
      productionRateNumber(data['originalReportQty'])!;
  double get supplementQty => productionRateNumber(data['supplementQty'])!;
  double? get effectiveRate => productionRateNumber(data['effectiveRate']);
  double? get thresholdQty => productionRateNumber(data['thresholdQty']);
  bool get requiresSupplement => data['requiresSupplement'] == true;
}

class ProductionOutputSupplementReportLine {
  ProductionOutputSupplementReportLine(this.data);
  final Map<String, dynamic> data;
  int get inputLineIndex => (data['inputLineIndex'] as num).toInt();
  String get sourceSegmentId => data['sourceExecutionSegmentId'] as String;
  String? get sourceSalesAllocationId =>
      data['sourceSalesAllocationId'] as String?;
  double get actualQty => productionRateNumber(data['actualQty'])!;
  double get originalReportQty =>
      productionRateNumber(data['originalReportQty'])!;
  double get supplementQty => productionRateNumber(data['supplementQty'])!;
  bool get requiresSupplement => data['requiresSupplement'] == true;
}

class ProductionOutputSupplementReportPreview {
  ProductionOutputSupplementReportPreview(Map<String, dynamic> json)
    : requiresSupplements = json['requiresSupplements'] == true,
      lines = (json['lines'] as List)
          .map(
            (line) => ProductionOutputSupplementReportLine(
              Map<String, dynamic>.from(line as Map),
            ),
          )
          .toList();
  final bool requiresSupplements;
  final List<ProductionOutputSupplementReportLine> lines;
}

class ProductionOutputSupplementView {
  ProductionOutputSupplementView(this.data);
  final Map<String, dynamic> data;
  String get id => data['id'] as String;
  String get status => data['status'] as String;
  String get sourceSegmentId => data['sourceSegmentId'] as String;
  String? get excludedReportId => data['excludedReportId'] as String?;
  int? get inputLineIndex => (data['inputLineIndex'] as num?)?.toInt();
  Map<String, dynamic>? get reportContext {
    Object? snapshot = data['reportContext'];
    if (snapshot == null) return null;
    if (snapshot is String) snapshot = jsonDecode(snapshot);
    if (snapshot is! Map) throw const FormatException('申请时填写内容不完整');
    return Map<String, dynamic>.from(snapshot);
  }

  List<Map<String, dynamic>>? get relatedSupplements {
    final rows = data['relatedSupplements'];
    if (rows == null) return null;
    if (rows is! List) throw const FormatException('追加关联不完整');
    return rows.map((row) => Map<String, dynamic>.from(row as Map)).toList();
  }

  Map<int, ReportablePlanLine>? get inputSources {
    final rows = data['inputSources'];
    if (rows == null) return null;
    if (rows is! List) throw const FormatException('申请来源不完整');
    final sources = <int, ReportablePlanLine>{};
    for (final raw in rows) {
      final row = Map<String, dynamic>.from(raw as Map);
      final index = (row['inputLineIndex'] as num).toInt();
      if (index < 0 || sources.containsKey(index)) {
        throw const FormatException('申请来源行重复或无效');
      }
      sources[index] = ReportablePlanLine.fromJson(
        Map<String, dynamic>.from(row['sourceLine'] as Map),
      );
    }
    return sources;
  }

  String? get sourceSalesAllocationId =>
      data['sourceSalesAllocationId'] as String?;
  String? get planId => data['planId'] as String?;
  String? get planNo => data['planNo'] as String?;
  String? get proofId => data['proofId'] as String?;
  String? get supplementSegmentId => data['supplementSegmentId'] as String?;
  String? get supplementSegmentStatus =>
      data['supplementSegmentStatus'] as String?;
  bool get canStart => data['canStart'] == true;
  ReportablePlanLine? get sourceLine =>
      data['sourceLine'] is Map<String, dynamic>
      ? ReportablePlanLine.fromJson(data['sourceLine'] as Map<String, dynamic>)
      : null;
  int? get supplementSegmentVersion =>
      (data['supplementSegmentVersion'] as num?)?.toInt();
  double get actualQty => productionRateNumber(data['actualQty'])!;
  double get originalReportQty =>
      productionRateNumber(data['originalReportQty'])!;
  double get supplementQty => productionRateNumber(data['supplementQty'])!;
}

class ProductionOutputSupplementRepository {
  ProductionOutputSupplementRepository(this.api);
  final ApiClient api;
  static const _base = '/production/actual-output-supplements';
  Future<ProductionOutputSupplementReportPreview> previewReport(
    Map<String, dynamic> report, {
    String? excludedReportId,
  }) async => ProductionOutputSupplementReportPreview(
    await api.post(
      '$_base/preview-report',
      body: {'report': report, 'excludedReportId': ?excludedReportId},
    ),
  );
  Future<ProductionOutputSupplementPreview> preview({
    required String segmentId,
    required double actualQty,
    String? sourceSalesAllocationId,
    String? excludedReportId,
  }) async => ProductionOutputSupplementPreview(
    await api.post(
      '$_base/preview',
      body: {
        'sourceExecutionSegmentId': segmentId,
        'actualQty': actualQty,
        'sourceSalesAllocationId': ?sourceSalesAllocationId,
        'excludedReportId': ?excludedReportId,
      },
    ),
  );
  Future<ProductionOutputSupplementView> create(
    ProductionOutputSupplementPreview preview, {
    required String billDate,
    String? deliveryDate,
    String? remark,
    String? excludedReportId,
    Map<String, dynamic>? reportContext,
    int? inputLineIndex,
  }) async => ProductionOutputSupplementView(
    await api.post(
      _base,
      body: {
        'sourceExecutionSegmentId': preview.sourceSegmentId,
        'actualQty': preview.actualQty,
        'sourceSalesAllocationId': ?preview.sourceSalesAllocationId,
        'fingerprint': preview.fingerprint,
        'billDate': billDate,
        'deliveryDate': ?deliveryDate,
        'remark': ?remark,
        'excludedReportId': ?excludedReportId,
        'reportContext': ?reportContext,
        'inputLineIndex': ?inputLineIndex,
        'idempotencyKey': businessIdempotencyKey(
          'actual-output-supplement',
          '${preview.sourceSegmentId}|${preview.fingerprint}|${preview.actualQty}|$billDate|$deliveryDate|$remark|$excludedReportId|$inputLineIndex',
        ),
      },
    ),
  );
  Future<ProductionOutputSupplementView> detail(String id) async =>
      ProductionOutputSupplementView(await api.get('$_base/$id'));
  Future<ProductionOutputSupplementView> approve(String id) async =>
      ProductionOutputSupplementView(
        await api.post(
          '$_base/$id/approve',
          body: {
            'idempotencyKey': businessIdempotencyKey(
              'actual-supplement-approve',
              id,
            ),
          },
        ),
      );
}

final productionOutputSupplementRepositoryProvider =
    Provider<ProductionOutputSupplementRepository>(
      (ref) =>
          ProductionOutputSupplementRepository(ref.watch(apiClientProvider)),
    );
