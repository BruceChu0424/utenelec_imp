/// Returns a user-facing currency label without leaking legacy numeric codes.
///
/// Currency identity continues to use UUID/code in APIs and persistence. The
/// old `001`/`002`/`003` values are business master-data codes, not meaningful
/// amount prefixes, so UI surfaces should prefer the readable master name.
String? financeCurrencyDisplayLabel({String? name, String? code}) {
  const knownNames = {
    'CNY': '人民币',
    'RMB': '人民币',
    'USD': '美金',
    'HKD': '港币',
    'EUR': '欧元',
    'JPY': '日元',
    'GBP': '英镑',
    'SGD': '新加坡元',
    'AUD': '澳元',
    'CAD': '加元',
    'KRW': '韩元',
    'RUB': '卢布',
  };
  String? readable(String? candidate) {
    final value = candidate?.trim();
    if (value == null || value.isEmpty || value == '—') return null;
    return RegExp(r'^\d+$').hasMatch(value) ? null : value;
  }

  final masterName = readable(name);
  final currencyCode = readable(code);
  if (masterName != null && RegExp(r'[\u3400-\u9fff]').hasMatch(masterName)) {
    return masterName;
  }
  return knownNames[masterName?.toUpperCase()] ??
      knownNames[currencyCode?.toUpperCase()] ??
      masterName ??
      currencyCode;
}
