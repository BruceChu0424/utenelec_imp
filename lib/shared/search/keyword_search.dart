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

/// Parse one query once when filtering/ranking a complete local candidate set.
/// Matching remains literal and deterministic: every word must occur in a field.
class KeywordSearchQuery {
  KeywordSearchQuery(String query) : phrase = normalizedKeywordPhrase(query) {
    terms = phrase.isEmpty
        ? const []
        : phrase.split(' ').toSet().toList(growable: false);
  }
  final String phrase;
  late final List<String> terms;

  List<String> _values(Iterable<String?> fields) => [
    for (final value in fields)
      if (value != null) value.trim().toLowerCase(),
  ];

  bool _matches(List<String> values) =>
      terms.every((term) => values.any((value) => value.contains(term)));

  bool matches(Iterable<String?> fields) => _matches(_values(fields));

  int? _rank(List<String> values) {
    if (!_matches(values)) return null;
    if (phrase.isEmpty || values.any((value) => value == phrase)) return 0;
    if (values.any((value) => value.startsWith(phrase))) return 1;
    if (values.any((value) => value.contains(phrase))) return 2;
    return 3;
  }

  int? rank(Iterable<String?> fields) => _rank(_values(fields));

  int? rankWithPrimary(Iterable<String?> primary, Iterable<String?> fields) {
    final preferred = _values(primary);
    final fallback = _rank([...preferred, ..._values(fields)]);
    if (fallback == null) return null;
    return _rank(preferred) ?? 4 + fallback;
  }
}

bool matchesKeywordSearch(Iterable<String?> fields, String query) =>
    KeywordSearchQuery(query).matches(fields);

/// Rank only already-authorized candidates. Null is no ordinary match;
/// callers keep any explicitly separate approximate section after these tiers.
int? keywordSearchRank(Iterable<String?> fields, String query) =>
    KeywordSearchQuery(query).rank(fields);

/// Name relevance wins over codes and contextual fields, without broadening the
/// authorized candidate set. An ordinary match must still contain every word.
int? keywordSearchRankWithPrimary(
  Iterable<String?> primary,
  Iterable<String?> fields,
  String query,
) => KeywordSearchQuery(query).rankWithPrimary(primary, fields);

/// Applies relevance to a complete in-memory candidate set. Ties retain the
/// source order; paginated API results must be ranked on the server instead.
List<T> rankedKeywordMatches<T>(
  Iterable<T> candidates,
  String query, {
  required Iterable<String?> Function(T) fields,
  Iterable<String?> Function(T)? primaryFields,
}) {
  final parsed = KeywordSearchQuery(query);
  if (parsed.terms.isEmpty) return candidates.toList();
  final ranked = <({T item, int index, int rank})>[];
  var index = 0;
  for (final item in candidates) {
    final rank = primaryFields == null
        ? parsed.rank(fields(item))
        : parsed.rankWithPrimary(primaryFields(item), fields(item));
    if (rank != null) ranked.add((item: item, index: index, rank: rank));
    index++;
  }
  ranked.sort((a, b) {
    final relevance = a.rank.compareTo(b.rank);
    return relevance != 0 ? relevance : a.index.compareTo(b.index);
  });
  return ranked.map((entry) => entry.item).toList();
}
