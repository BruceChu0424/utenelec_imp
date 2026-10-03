/// Legacy master codes identify records, never currencies. Only explicit known
/// labels establish equivalence; conflicting code/name evidence is rejected.
String? financeDocumentCurrency({String? code, String? name}) {
  String? resolve(String? value) => switch (value?.trim().toUpperCase()) {
    'CNY' || 'RMB' || '人民币' => 'CNY',
    'USD' || '美元' || '美金' => 'USD',
    'EUR' || '欧元' => 'EUR',
    'HKD' || '港币' || '港元' => 'HKD',
    'JPY' || '日元' => 'JPY',
    'GBP' || '英镑' => 'GBP',
    'KRW' || '韩元' => 'KRW',
    _ => null,
  };
  final fromCode = resolve(code);
  final fromName = resolve(name);
  if (fromCode != null && fromName != null && fromCode != fromName) return null;
  return fromCode ?? fromName;
}
