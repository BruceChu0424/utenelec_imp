import 'dart:convert';

/// Shared log v1: operational facts only. Never serialize arbitrary exceptions,
/// headers, request/response bodies, account data, or widget descriptions.
String diagnosticPath(String value) {
  if (value.length > 2048) return '/:oversize';
  final path = Uri.tryParse(value)?.path ?? '';
  return '/${path.split('/').where((s) => s.isNotEmpty).map((s) {
    return RegExp(r'^[a-z][a-z_-]{0,31}$').hasMatch(s) ? s : ':id';
  }).join('/')}';
}

const _fields = {
  'method',
  'path',
  'status',
  'durationMs',
  'bytes',
  'code',
  'phase',
  'count',
  'stage',
  'version',
  'build',
  'runtime',
  'os',
  'architecture',
  'exceptionType',
  'stack',
  'reason',
  'frameGapMs',
  'buildMs',
  'rasterMs',
};

String _safeText(String text, int limit) {
  if (text.length > 4096) return '[oversize]';
  final value = text
      .replaceAll(
        RegExp(r'Bearer\s+\S+', caseSensitive: false),
        'Bearer [redacted]',
      )
      .replaceAll(
        RegExp(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'),
        '[redacted]',
      )
      .replaceAll(
        RegExp(
          r'(password|accessToken|refreshToken|authorization)\s*[:=]\s*[^\s,;]+',
          caseSensitive: false,
        ),
        '[redacted]',
      );
  return value.length <= limit ? value : value.substring(0, limit);
}

String diagnosticRecord(
  String event,
  Map<String, Object?> fields, {
  String level = 'info',
  DateTime? at,
}) {
  final record = <String, Object?>{
    'schemaVersion': 1,
    'atUtc': (at ?? DateTime.now()).toUtc().toIso8601String(),
    'level': {'info', 'warning', 'error'}.contains(level) ? level : 'info',
    'event': RegExp(r'^[a-z0-9_.-]{1,80}$').hasMatch(event)
        ? event
        : 'diagnostic.invalid_event',
  };
  for (final entry in fields.entries) {
    final value = entry.value;
    if (!_fields.contains(entry.key) || value == null) continue;
    if (value is num && !value.isFinite) continue;
    if (value is! String && value is! num && value is! bool) continue;
    record[entry.key] = entry.key == 'path'
        ? diagnosticPath(value.toString())
        : value is num || value is bool
        ? value
        : _safeText(value.toString(), entry.key == 'stack' ? 1800 : 256);
  }
  return '${jsonEncode(record)}\n';
}

String diagnosticErrorKind(Object error) {
  // Inspect, but never store, exception text: Flutter descriptions can include
  // user-entered widget text or a server response.
  String text;
  try {
    text = error.toString();
  } catch (_) {
    return 'unhandled';
  }
  if (text.contains('Null check operator')) return 'null_check';
  if (text.contains('after dispose')) return 'retired_owner';
  if (text.contains('overflowed')) return 'layout_overflow';
  return 'unhandled';
}
