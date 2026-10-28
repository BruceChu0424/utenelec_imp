import 'dart:convert';

const _masterReports = {
  '/master/goods/export': 'goods',
  '/master/clients/export': 'client',
  '/master/suppliers/export': 'supplier',
  '/master/accounts/export': 'account',
  '/master/currencies/export': 'currency',
  '/master/colors/export': 'color',
  '/master/units/export': 'unit',
  '/master/moulds/export': 'mould',
  '/master/warehouses/export': 'warehouse',
  '/master/reference-methods/settlement-admin/export': 'settlement_method',
};

String? masterExportJobReport(String endpoint) => _masterReports[endpoint];

/// Preserve the original request's DTO types and body-only contact filters.
/// A JSON string fits the task's private string-parameter contract without
/// flattening UUID sets, exact decimal text, or column-search maps.
Map<String, dynamic> masterExportJobParameters(
  String report,
  Map<String, dynamic> query,
  Map<String, dynamic> body,
) {
  final contact =
      report == 'client' || report == 'supplier' || report == 'account';
  const controls = {
    'password',
    'report',
    'sort',
    'order',
    'format',
    'page',
    'size',
    'includeCount',
    'includeFacets',
    'includeTotals',
  };
  const sensitiveKeys = {'keyword', 'mobile', 'phone', 'phone2', 'bankAccount'};
  const sensitiveColumns = {
    'mobile',
    'phone',
    'phone2',
    'bankAccount',
    'bankAccountNo',
  };
  const booleanKeys = {
    'excludeDisabled',
    'excludeStub',
    'disabledOnly',
    'stubOnly',
    'includeRelated',
    'excludeLegacyFinanceStub',
    'selectableOnly',
    'accountable',
    'defective',
  };
  final filter = <String, dynamic>{};
  final searches = <String, dynamic>{};
  for (final entry in query.entries) {
    final key = entry.key;
    if (controls.contains(key) || (contact && sensitiveKeys.contains(key))) {
      continue;
    }
    if (key.startsWith('search.')) {
      final field = key.substring(7);
      if (contact && sensitiveColumns.contains(field)) {
        throw const FormatException('联系方式列搜索必须通过私有请求体提供');
      }
      searches[field] = entry.value;
      continue;
    }
    if (key == 'columnSearch' && entry.value is Map) {
      searches.addAll(Map<String, dynamic>.from(entry.value as Map));
      continue;
    }
    var value = entry.value;
    if (key == 'nullFields' || key == 'categoryRootIds') {
      if (value is String) {
        value = value
            .split(',')
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toList();
      } else if (value is Iterable) {
        value = value.toList(growable: false);
      }
    } else if (booleanKeys.contains(key) && value is String) {
      if (value.trim().isEmpty) continue;
      value = switch (value.trim().toLowerCase()) {
        'true' || '1' || 'yes' || 'on' => true,
        'false' || '0' || 'no' || 'off' => false,
        _ => value,
      };
    }
    if (value != null) filter[key] = value;
  }
  final sensitive = body['sensitiveFilter'];
  if (sensitive != null) {
    if (!contact || sensitive is! Map) {
      throw const FormatException('主档导出筛选请求体无效');
    }
    for (final entry in sensitive.entries) {
      final key = entry.key.toString();
      if (key == 'columnSearch' && entry.value is Map) {
        searches.addAll(Map<String, dynamic>.from(entry.value as Map));
      } else if (sensitiveKeys.contains(key) && entry.value != null) {
        filter[key] = entry.value;
      } else if (entry.value != null) {
        throw const FormatException('主档导出筛选请求体无效');
      }
    }
  }
  if (searches.isNotEmpty) filter['columnSearch'] = searches;
  return {
    'filter': jsonEncode(filter),
    if (query['sort'] != null) 'sort': query['sort'],
    if (query['order'] != null) 'order': query['order'],
  };
}
