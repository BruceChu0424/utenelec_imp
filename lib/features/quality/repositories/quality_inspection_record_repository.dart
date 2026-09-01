import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/quality_inspection_record.dart';

class QualityInspectionRecordRepository {
  const QualityInspectionRecordRepository(this.api);

  final ApiClient api;

  Future<QualityInspectionRecordPage> list({
    required QualityInspectionRecordDomain domain,
    String? decision,
    String keyword = '',
    QualityInspectionDateRange? dateRange,
    int page = 1,
    int size = 40,
  }) async {
    final json = await api.get(
      _listPath(domain),
      query: {
        if (decision?.trim().isNotEmpty == true) 'decision': decision!.trim(),
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        if (dateRange != null)
          'from': _fromInstant(dateRange).toIso8601String(),
        if (dateRange != null) 'to': _toInstant(dateRange).toIso8601String(),
        'page': page,
        'size': size,
      },
    );
    return QualityInspectionRecordPage.fromJson(json);
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
