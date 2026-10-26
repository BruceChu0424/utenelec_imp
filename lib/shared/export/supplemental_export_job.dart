/// These private request adapters preserve the original audit and actual-cost contracts.
String? supplementalExportJobDomain(String endpoint) => switch (endpoint) {
  '/admin/audit-logs/export' => 'audit',
  '/master/goods/cost-sheets/actual/export' => 'goods_actual_cost',
  _ => null,
};

String supplementalExportJobReport(String domain, String? tableKey) =>
    domain == 'audit'
    ? tableKey ==
              'features.admin.pages.audit_overview_widgets.AuditSessionTable.build.1'
          ? 'sessions'
          : 'activity'
    : 'snapshot';

Map<String, dynamic> supplementalExportJobParameters(
  String domain,
  Map<String, dynamic> query,
  Map<String, dynamic> body,
) {
  const controls = {
    'password',
    'format',
    'columnProjection',
    'report',
    'sort',
    'order',
    'page',
    'size',
    'includeCount',
    'includeFacets',
    'includeTotals',
    'metadataReuse',
    'readScopeVersion',
  };
  const costFields = {
    'goodsId',
    'executionSegmentId',
    'from',
    'to',
    'revisionId',
    'expectedDigest',
  };
  final source = domain == 'goods_actual_cost' ? body : query;
  final parameters = <String, dynamic>{};
  for (final entry in source.entries) {
    if (controls.contains(entry.key) || entry.value == null) continue;
    if (domain == 'goods_actual_cost' && !costFields.contains(entry.key)) {
      throw const FormatException('实际成本导出条件无效');
    }
    if (entry.value is Map || entry.value is List) {
      throw const FormatException('导出条件必须使用原查询标量');
    }
    parameters[entry.key] = entry.value.toString();
  }
  if (query['sort'] != null) parameters['sort'] = query['sort'];
  if (query['order'] != null) parameters['order'] = query['order'];
  return parameters;
}
