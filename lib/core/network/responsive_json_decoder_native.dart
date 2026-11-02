import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

import '../performance/ui_work_budget.dart';
import '../performance/data_work_queue.dart';

class ResponsiveJsonDecoder {
  bool _disposed = false;

  Future<Object?> decodeBytes(
    Uint8List bytes, {
    bool Function()? isCurrent,
  }) async {
    if (_disposed) throw StateError('JSON decoder is disposed');
    if (isCurrent?.call() == false) throw const UiWorkCancelled();
    if (bytes.isEmpty) return null;
    final Object? result;
    try {
      result = bytes.length < 64 * 1024
          ? _decode(bytes)
          : await dataWorkQueue.run(
              () => compute(_decode, bytes, debugLabel: 'uten-json-decode'),
              isCurrent: () => !_disposed && isCurrent?.call() != false,
            );
    } on UiWorkCancelled {
      if (_disposed) throw StateError('JSON decoder is disposed');
      rethrow;
    }
    if (_disposed) throw StateError('JSON decoder is disposed');
    if (isCurrent?.call() == false) throw const UiWorkCancelled();
    return result;
  }

  void dispose() => _disposed = true;
}

Object? _decode(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes, allowMalformed: true));
