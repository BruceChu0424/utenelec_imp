/// A literal bounded page for business fixtures. It never rounds or rewrites
/// the supplied rows; lifecycle/ACL fixtures choose their own authorized set.
Map<String, dynamic> versionedSummaryTestResponse(
  List<Map<String, dynamic>> items,
  Map<String, dynamic>? query, {
  String revision = 'fixture-snapshot',
  String dataVersion = 'fixture-domain',
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
    'readScopeVersion': 'fixture-authority',
    'readSnapshotRevision': revision,
    'readDataVersion': dataVersion,
  };
}
