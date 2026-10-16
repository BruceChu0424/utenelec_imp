/// Whitespace separates required words; each word may match a different field.
/// Keep this contract aligned with the server's KeywordSearch.
String normalizedKeywordPhrase(String query) =>
    query.toLowerCase().replaceAll(RegExp(r'\s+', unicode: true), ' ').trim();

List<String> keywordSearchTerms(String query) => query
    .toLowerCase()
    .split(RegExp(r'\s+', unicode: true))
    .where((term) => term.isNotEmpty)
    .toSet()
    .toList(growable: false);

bool matchesKeywordSearch(Iterable<String?> fields, String query) {
  final values = fields
      .whereType<String>()
      .map((value) => value.toLowerCase())
      .toList();
  return keywordSearchTerms(
    query,
  ).every((term) => values.any((value) => value.contains(term)));
}

/// Rank only already-authorized candidates. Null is no ordinary match;
/// callers keep any explicitly separate approximate section after these tiers.
int? keywordSearchRank(Iterable<String?> fields, String query) {
  final values = fields
      .whereType<String>()
      .map((value) => value.trim().toLowerCase())
      .toList();
  if (!matchesKeywordSearch(values, query)) return null;
  final phrase = normalizedKeywordPhrase(query);
  if (phrase.isEmpty || values.any((value) => value == phrase)) return 0;
  if (values.any((value) => value.startsWith(phrase))) return 1;
  if (values.any((value) => value.contains(phrase))) return 2;
  return 3;
}

/// Name relevance wins over codes and contextual fields, without broadening the
/// authorized candidate set. An ordinary match must still contain every word.
int? keywordSearchRankWithPrimary(
  Iterable<String?> primary,
  Iterable<String?> fields,
  String query,
) {
  final all = [...primary, ...fields];
  final fallback = keywordSearchRank(all, query);
  if (fallback == null) return null;
  final preferred = keywordSearchRank(primary, query);
  return preferred ?? 4 + fallback;
}

/// Applies relevance to a complete in-memory candidate set. Ties retain the
/// source order; paginated API results must be ranked on the server instead.
List<T> rankedKeywordMatches<T>(
  Iterable<T> candidates,
  String query, {
  required Iterable<String?> Function(T) fields,
  Iterable<String?> Function(T)? primaryFields,
}) {
  if (keywordSearchTerms(query).isEmpty) return candidates.toList();
  final ranked = <({T item, int index, int rank})>[];
  var index = 0;
  for (final item in candidates) {
    final rank = primaryFields == null
        ? keywordSearchRank(fields(item), query)
        : keywordSearchRankWithPrimary(
            primaryFields(item),
            fields(item),
            query,
          );
    if (rank != null) ranked.add((item: item, index: index, rank: rank));
    index++;
  }
  ranked.sort((a, b) {
    final relevance = a.rank.compareTo(b.rank);
    return relevance != 0 ? relevance : a.index.compareTo(b.index);
  });
  return ranked.map((entry) => entry.item).toList();
}
