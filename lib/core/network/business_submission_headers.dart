/// Replayable business headers exclude login credentials and generated wire framing.
/// Authentication continues to come from the current authenticated request scope.
Map<String, dynamic> businessSubmissionHeaders(Object? value) {
  if (value == null) return <String, dynamic>{};
  if (value is! Map) throw StateError('原业务请求头格式不完整，请保留原请求');
  const forbidden = {
    'authorization',
    'proxy-authorization',
    'cookie',
    'set-cookie',
    'host',
    'content-length',
    'content-type',
    'transfer-encoding',
    'connection',
    'x-uten-step-up',
    'x-uten-step-up-token',
    'x-api-key',
  };
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is! String) throw StateError('原业务请求头名称无效，请保留原请求');
    final name = entry.key as String, lower = name.toLowerCase();
    if (forbidden.contains(lower) ||
        lower.contains('access-token') ||
        lower.contains('refresh-token') ||
        lower.contains('password') ||
        lower.contains('credential')) {
      throw StateError('原业务请求不能保存或重放登录凭据、认证信息或传输头');
    }
    if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(name)) {
      throw StateError('原业务请求头名称无效，请保留原请求');
    }
    final item = entry.value;
    if (item == null || item is String || item is num || item is bool) {
      result[name] = item;
    } else if (item is List && item.every((v) => v is String)) {
      result[name] = List<String>.unmodifiable(item.cast<String>());
    } else {
      throw StateError('原业务请求头内容不完整，请保留原请求');
    }
  }
  return Map<String, dynamic>.unmodifiable(result);
}
