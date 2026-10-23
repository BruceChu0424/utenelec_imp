import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import 'ui_work_budget.dart';

Future<Object?> executeDataCodec(
  String operation,
  Object? value, {
  bool Function()? isCurrent,
}) async {
  if (isCurrent?.call() == false) throw const UiWorkCancelled();
  final request = (operation, value);
  final result = _large(value)
      ? await compute(_execute, request, debugLabel: 'uten-data-codec')
      : _execute(request);
  if (isCurrent?.call() == false) throw const UiWorkCancelled();
  return result;
}

bool _large(Object? value) {
  var size = 0;
  final pending = <Object?>[value];
  while (pending.isNotEmpty) {
    final next = pending.removeLast();
    if (next is String) {
      size += next.length;
    } else if (next is Uint8List) {
      size += next.length;
    } else if (next is Map) {
      size += next.length * 8;
      pending.addAll(next.values);
    } else if (next is List) {
      size += next.length * 4;
      pending.addAll(next);
    } else {
      size += 8;
    }
    if (size >= 32 * 1024) return true;
  }
  return false;
}

Object? _execute((String, Object?) request) => switch (request.$1) {
  'json-encode' => jsonEncode(request.$2),
  'json-decode' => jsonDecode(request.$2 as String),
  'base64-encode' => base64Encode(request.$2 as Uint8List),
  'base64-decode' => base64Decode(request.$2 as String),
  'utf8-encode' => Uint8List.fromList(utf8.encode(request.$2 as String)),
  'utf8-decode' => utf8.decode(request.$2 as Uint8List),
  'utf8-decode-lossy' => utf8.decode(
    request.$2 as Uint8List,
    allowMalformed: true,
  ),
  _ => throw ArgumentError.value(request.$1, 'operation'),
};
