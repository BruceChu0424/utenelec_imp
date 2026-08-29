/// Returns a user-facing currency label without leaking legacy numeric codes.
///
/// Currency identity continues to use UUID/code in APIs and persistence. The
/// old `001`/`002`/`003` values are business master-data codes, not meaningful
/// amount prefixes, so UI surfaces should prefer the readable master name.
String? financeCurrencyDisplayLabel({String? name, String? code}) {
  for (final candidate in [name, code]) {
    final value = candidate?.trim();
    if (value == null || value.isEmpty || value == '—') continue;
    if (RegExp(r'^\d+$').hasMatch(value)) continue;
    return value;
  }
  return null;
}
