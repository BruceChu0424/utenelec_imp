import '../../../shared/paging/versioned_summary_read.dart';

/// Business callers select a real authorized lifecycle range; the common
/// reader does not infer completion from amounts, dates or captions.
enum FinanceSummaryScope { active, history, all }

Future<List<Map<String, dynamic>>> readCompleteFinanceSummaries({
  required Future<Map<String, dynamic>> Function(
    int page,
    int size,
    String? snapshotRevision,
  )
  loadPage,
  required bool Function() isCurrent,
  required Object? Function(Map<String, dynamic> row) idOf,
}) => readCompleteVersionedSummaries<Map<String, dynamic>>(
  loadPage: loadPage,
  isCurrent: isCurrent,
  batchSize: 1000,
  decode: (row) => Map<String, dynamic>.unmodifiable(row),
  idOf: idOf,
);
