/// Reads additive server decimal-text properties without converting them through
/// a binary number. Legacy numeric properties remain display compatibility only.
Map<String, String> readExactDecimalTexts(Map<String, dynamic> json) => {
  for (final entry in json.entries)
    if (entry.key.endsWith('Exact') && entry.value is String)
      entry.key.substring(0, entry.key.length - 5): entry.value as String,
};
