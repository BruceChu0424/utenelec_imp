import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/utils/china_datetime.dart';
import '../../basic_data/models/master_facet.dart';
import '../models/quality_inspection_record.dart';

class QualityInspectionRecordRepository {
  const QualityInspectionRecordRepository(this.api);

  final ApiClient api;

  /// 2026-09-25 单号列统一：[sort]/[order] 表头排序（白名单
  /// sourceNo/referenceNo/sheetNo）；[sourceNo]/[referenceNo]/[sheetNo]
  /// 为单号列值筛选（精确匹配；sheetNo 仅 FQC 有列值）。
  Future<QualityInspectionRecordPage> list({
    required QualityInspectionRecordDomain domain,
    String? decision,
    String keyword = '',
    QualityInspectionDateRange? dateRange,
    String? sourceType,
    String? effective,
    String? disposition,
    int page = 1,
    int size = 40,
    String? sort,
    String? order,
    String? sourceNo,
    String? referenceNo,
    String? sheetNo,
  }) async {
    final json = await api.get(
      _listPath(domain),
      query: {
        if (decision?.trim().isNotEmpty == true) 'decision': decision!.trim(),
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        if (dateRange != null)
          'from': _fromInstant(dateRange).toIso8601String(),
        if (dateRange != null) 'to': _toInstant(dateRange).toIso8601String(),
        if (sourceType?.trim().isNotEmpty == true)
          'sourceType': sourceType!.trim(),
        if (effective?.trim().isNotEmpty == true)
          'effective': effective!.trim(),
        if (disposition?.trim().isNotEmpty == true)
          'disposition': disposition!.trim(),
        'page': page,
        'size': size,
        'sort': ?sort,
        'order': ?order,
        if (sourceNo?.isNotEmpty == true) 'sourceNo': sourceNo,
        if (referenceNo?.isNotEmpty == true) 'referenceNo': referenceNo,
        if (domain == QualityInspectionRecordDomain.fqc &&
            sheetNo?.isNotEmpty == true)
          'sheetNo': sheetNo,
      },
    );
    return QualityInspectionRecordPage.fromJson(json);
  }

  /// 单号列 facets（2026-09-25 单号列统一）：{sourceNo/referenceNo/sheetNo:
  /// [MasterFacetBucket]}，与列表同一过滤上下文（不含单号自身的值筛选）；
  /// IQC 无检查单号，sheetNo 恒为空表。
  Future<Map<String, List<MasterFacetBucket>>> facets({
    required QualityInspectionRecordDomain domain,
    String? decision,
    String keyword = '',
    QualityInspectionDateRange? dateRange,
    String? sourceType,
    String? effective,
    String? disposition,
  }) async {
    final json = await api.get(
      '${_listPath(domain)}/facets',
      query: {
        if (decision?.trim().isNotEmpty == true) 'decision': decision!.trim(),
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        if (dateRange != null)
          'from': _fromInstant(dateRange).toIso8601String(),
        if (dateRange != null) 'to': _toInstant(dateRange).toIso8601String(),
        if (sourceType?.trim().isNotEmpty == true)
          'sourceType': sourceType!.trim(),
        if (effective?.trim().isNotEmpty == true)
          'effective': effective!.trim(),
        if (disposition?.trim().isNotEmpty == true)
          'disposition': disposition!.trim(),
      },
    );
    final result = <String, List<MasterFacetBucket>>{};
    for (final entry in json.entries) {
      if (entry.value is List) {
        result[entry.key] = parseFacetBuckets(json, entry.key);
      }
    }
    return result;
  }

  Future<QualityInspectionRecord> detail({
    required QualityInspectionRecordDomain domain,
    required String recordId,
  }) async {
    final path = switch (domain) {
      QualityInspectionRecordDomain.iqc =>
        ApiEndpoints.procurementInspectionRecord(recordId),
      QualityInspectionRecordDomain.fqc =>
        ApiEndpoints.productionQualityInspectionRecord(recordId),
    };
    return QualityInspectionRecord.fromJson(await api.get(path));
  }

  String _listPath(QualityInspectionRecordDomain domain) => switch (domain) {
    QualityInspectionRecordDomain.iqc =>
      ApiEndpoints.procurementInspectionRecords,
    QualityInspectionRecordDomain.fqc =>
      ApiEndpoints.productionQualityInspectionRecords,
  };

  DateTime _fromInstant(QualityInspectionDateRange range) =>
      ChinaDateTime.wallTimeToUtc(
        DateTime.utc(range.start.year, range.start.month, range.start.day),
      );

  DateTime _toInstant(QualityInspectionDateRange range) =>
      ChinaDateTime.wallTimeToUtc(
        DateTime.utc(
          range.end.year,
          range.end.month,
          range.end.day,
        ).add(const Duration(days: 1)),
      ).subtract(const Duration(microseconds: 1));
}

class QualityInspectionDateRange {
  const QualityInspectionDateRange({required this.start, required this.end});

  final DateTime start;
  final DateTime end;
}

final qualityInspectionRecordRepositoryProvider =
    Provider<QualityInspectionRecordRepository>(
      (ref) => QualityInspectionRecordRepository(ref.watch(apiClientProvider)),
    );
