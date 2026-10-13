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
    'CHF': '瑞士法郎',
    'CHINESE YUAN': '人民币',
    'RENMINBI': '人民币',
    'US DOLLAR': '美金',
    'UNITED STATES DOLLAR': '美金',
    'HONG KONG DOLLAR': '港币',
    'EURO': '欧元',
    'JAPANESE YEN': '日元',
    'POUND STERLING': '英镑',
    'BRITISH POUND': '英镑',
    'SINGAPORE DOLLAR': '新加坡元',
    'AUSTRALIAN DOLLAR': '澳元',
    'CANADIAN DOLLAR': '加元',
    'SOUTH KOREAN WON': '韩元',
    'RUSSIAN RUBLE': '卢布',
    'SWISS FRANC': '瑞士法郎',
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
