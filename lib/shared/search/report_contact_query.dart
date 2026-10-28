import '../../core/network/api_client.dart';
import '../../features/basic_data/models/master_facet.dart';
import '../paging/paged_query_identity.dart';

/// A report keeps its full flat criteria as its read identity, while contact
/// values use the existing ContactSensitiveFilter body at the HTTP boundary.
class ReportContactQuery {
  factory ReportContactQuery(Map<String, dynamic> parameters) {
    final filters = <String, String?>{
      for (final entry in parameters.entries)
        if (_contactKey(entry.key))
          _filterKey(entry.key): entry.value?.toString(),
    };
    final publicFilters = withoutContactSensitiveValues(filters);
    final sensitive = contactSensitiveFilterBody(
      filters,
      keyword: parameters['keyword']?.toString(),
    );
    return ReportContactQuery._(
      _freeze({
        for (final entry in parameters.entries)
          if (entry.key != 'keyword' &&
              (!_contactKey(entry.key) ||
                  !_typedContactKey(entry.key) &&
                      publicFilters.containsKey(_filterKey(entry.key))))
            entry.key: entry.value,
      }),
      _freeze(sensitive),
    );
  }
  const ReportContactQuery._(this.query, this.body);
  final Map<String, dynamic> query;
  final Map<String, dynamic> body;
  Map<String, dynamic> get exportBody =>
      body.isEmpty ? const {} : Map.unmodifiable({'sensitiveFilter': body});

  Future<Map<String, dynamic>> fetch(ApiClient api, String endpoint) =>
      body.isEmpty
      ? api.get(endpoint, query: query)
      : api.post('$endpoint/search', query: query, body: body);

  static bool hasContactUrlValues(Map<String, dynamic> parameters) =>
      parameters.entries.any(
        (entry) =>
            _contactKey(entry.key) &&
            entry.value != null &&
            entry.value.toString().trim().isNotEmpty &&
            (_typedContactKey(entry.key) ||
                entry.value != kMasterFilterNullValue),
      );

  static String _filterKey(String key) =>
      key.startsWith('f.') ? key.substring(2) : key;
  static bool _contactKey(String key) {
    final filter = _filterKey(key);
    return kContactSensitiveFilterKeys.contains(
      filter.startsWith('search.') ? filter.substring(7) : filter,
    );
  }

  static bool _typedContactKey(String key) =>
      _filterKey(key).startsWith('search.') && _contactKey(key);

  static Map<String, dynamic> _freeze(Map<String, dynamic> values) =>
      Map.unmodifiable({
        for (final entry in values.entries)
          entry.key: freezePagedReadQuery(entry.value),
      });
}

/// This map is sent only inside the private POST job request, never as a URL.
/// The ordinary report adapter consumes the same flat f.search.* parameters.
Map<String, dynamic> reportContactExportJobParameters(
  Map<String, dynamic> query,
  Map<String, dynamic> body,
) {
  if (ReportContactQuery.hasContactUrlValues(query)) {
    throw const FormatException('敏感列检索必须通过私有请求体提供');
  }
  final parameters = Map<String, dynamic>.of(query);
  final sensitive = body['sensitiveFilter'];
  if (sensitive == null) return parameters;
  if (sensitive is! Map) throw const FormatException('敏感报表检索请求体无效');
  for (final entry in sensitive.entries) {
    final key = entry.key.toString(), value = entry.value;
    if (value == null) continue;
    if (key == 'columnSearch') {
      if (value is! Map) throw const FormatException('敏感列检索请求体无效');
      for (final column in value.entries) {
        final field = column.key.toString();
        if (!kContactSensitiveFilterKeys.contains(field) ||
            column.value is Map ||
            column.value is Iterable) {
          throw const FormatException('敏感列检索请求体无效');
        }
        if (column.value != null) {
          parameters['f.search.$field'] = column.value.toString();
        }
      }
    } else if (key == 'keyword') {
      if (value is Map || value is Iterable) {
        throw const FormatException('敏感报表检索请求体无效');
      }
      parameters['keyword'] = value.toString();
    } else if (kContactSensitiveFilterKeys.contains(key)) {
      if (value is Map || value is Iterable) {
        throw const FormatException('敏感报表检索请求体无效');
      }
      parameters['f.search.$key'] = value.toString();
    } else {
      throw const FormatException('敏感报表检索请求体无效');
    }
  }
  return parameters;
}
