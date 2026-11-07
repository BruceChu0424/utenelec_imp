import 'package:dio/dio.dart';

/// A literal bounded page for business fixtures. It never rounds or rewrites
/// the supplied rows; lifecycle/ACL fixtures choose their own authorized set.
Map<String, dynamic> versionedSummaryTestResponse(
  List<Map<String, dynamic>> items,
  Map<String, dynamic>? query, {
  String revision = 'fixture-snapshot',
  String dataVersion = 'fixture-domain',
  String scopeVersion = 'fixture-authority',
}) {
  final page = query?['page'] as int? ?? 1;
  final size = query?['size'] as int? ?? 100;
  final start = (page - 1) * size;
  return {
    'items': start >= items.length
        ? <Map<String, dynamic>>[]
        : items.sublist(start, (start + size).clamp(0, items.length)),
    'page': page,
    'size': size,
    'total': items.length,
    'totalPages': (items.length + size - 1) ~/ size,
    'scope': query?['scope'] ?? 'all',
    'readScopeVersion': scopeVersion,
    'readSnapshotRevision': revision,
    'readDataVersion': dataVersion,
  };
}

/// Inspect the real complete-master transport without changing RequestOptions.
/// Old GET/POST search contracts remain independently testable by their callers.
Map<String, dynamic> masterSummaryTestParameters(RequestOptions request) {
  if (request.method != 'POST' || !request.path.endsWith('/summaries')) {
    throw StateError('Expected an exact master summary read');
  }
  final body = Map<String, dynamic>.from(request.data as Map);
  final filter = Map<String, dynamic>.from(body['filter'] as Map);
  final columns = Map<String, dynamic>.from(
    filter['columnSearch'] as Map? ?? const {},
  );
  return {
    ...filter,
    for (final entry in columns.entries) 'search.${entry.key}': entry.value,
    for (final key in ['page', 'size', 'sort', 'order'])
      if (body.containsKey(key)) key: body[key],
  };
}

Map<String, dynamic> masterSummaryTestResponse(
  List<Map<String, dynamic>> items,
  RequestOptions request,
) {
  final parameters = masterSummaryTestParameters(request);
  const revision =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  if (parameters['size'] != 100 ||
      request.queryParameters['readSnapshotRevision'] !=
          (parameters['page'] == 1 ? null : revision)) {
    throw StateError(
      'Summary fixture requires bounded100 and the first revision',
    );
  }
  return versionedSummaryTestResponse(
    items,
    parameters,
    revision: revision,
    dataVersion:
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  );
}
