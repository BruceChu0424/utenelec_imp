import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

import '../performance/ui_work_budget.dart';

class ResponsiveJsonDecoder {
  bool _disposed = false;

  Future<Object?> decodeBytes(
    Uint8List bytes, {
    bool Function()? isCurrent,
  }) async {
    if (_disposed) throw StateError('JSON decoder is disposed');
    if (isCurrent?.call() == false) throw const UiWorkCancelled();
    if (bytes.isEmpty) return null;
    final result = bytes.length < 64 * 1024
        ? _decode(bytes)
        : await compute(_decode, bytes, debugLabel: 'uten-json-decode');
    if (_disposed) throw StateError('JSON decoder is disposed');
    if (isCurrent?.call() == false) throw const UiWorkCancelled();
    return result;
  }

  void dispose() => _disposed = true;
}

Object? _decode(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes, allowMalformed: true));
