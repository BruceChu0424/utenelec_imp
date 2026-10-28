/// Immutable column criteria shared by server-paged table views.
class TableColumnQuery {
  const TableColumnQuery({
    this.searches = const {},
    this.sort,
    this.ascending = true,
  });

  final Map<String, String?> searches;
  final String? sort;
  final bool ascending;

  TableColumnQuery search(String key, String? value) {
    final next = Map<String, String?>.of(searches);
    final text = value?.trim();
    if (text == null || text.isEmpty) {
      next.remove(key);
    } else {
      next[key] = text;
    }
    return TableColumnQuery(
      searches: Map.unmodifiable(next),
      sort: sort,
      ascending: ascending,
    );
  }

  TableColumnQuery sorted(String? key, bool ascending) => TableColumnQuery(
    searches: searches,
    sort: key,
    ascending: key == null ? true : ascending,
  );
}

Map<String, dynamic> tableColumnParameters(
  Map<String, String?> searches,
  String? sort,
  bool ascending,
) => {
  for (final entry in searches.entries)
    if (entry.key.startsWith('search.') &&
        entry.value?.trim().isNotEmpty == true)
      entry.key: entry.value!.trim(),
  'sort': ?sort,
  if (sort != null) 'order': ascending ? 'asc' : 'desc',
};
