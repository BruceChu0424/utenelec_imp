/// Gateway configuration is distinct from verification-code TTL/rate limits.
class SmsSettings {
  SmsSettings.fromJson(Map<String, dynamic> json)
    : revision = _required(json['revision']),
      version = json['version'] is int ? json['version'] as int : 0,
      source = _required(json['source']),
      provider = _required(json['provider']),
      effectiveProvider = _required(json['effectiveProvider']),
      endpoint = _text(json['endpoint']),
      allowedEndpoints = List<String>.unmodifiable(
        json['allowedEndpoints'] is List
            ? (json['allowedEndpoints'] as List)
                  .whereType<String>()
                  .where((value) => value.isNotEmpty)
                  .toSet()
            : const <String>[],
      ),
      signName = _text(json['signName']),
      templateCode = _text(json['templateCode']),
      accessKeyConfigured = json['accessKeyConfigured'] == true,
      accessKeyIdHint = json['accessKeyIdHint'] as String?,
      secretUnreadable = json['secretUnreadable'] == true,
      canManage = _capabilities(json)['canManage'] == true,
      canUseLog = _capabilities(json)['canUseLog'] == true,
      status = _required(json['status']),
      detail = json['detail'] as String?,
      applyMode = _required(json['applyMode']) {
    if (revision.isEmpty || !const {'ENV', 'DATABASE'}.contains(source)) {
      throw const FormatException('Invalid SMS configuration response');
    }
  }
  final String revision, source, provider, effectiveProvider;
  final int version;
  final String endpoint, signName, templateCode, status, applyMode;
  final List<String> allowedEndpoints;
  final String? accessKeyIdHint, detail;
  final bool accessKeyConfigured, secretUnreadable, canManage, canUseLog;

  static Map<String, dynamic> _capabilities(Map<String, dynamic> json) =>
      json['capabilities'] is Map<String, dynamic>
      ? json['capabilities'] as Map<String, dynamic>
      : const {};
}

String _text(Object? value) => value is String ? value : '';
String _required(Object? value) {
  if (value is! String) {
    throw const FormatException('Invalid SMS configuration response');
  }
  return value;
}
