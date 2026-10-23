import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'package:web/web.dart' as web;
import 'ui_work_budget.dart';

@JS('Object.keys')
external JSArray<JSString> _objectKeys(JSObject value);
@JS('Array.isArray')
external bool _isArray(JSAny value);

extension type _Request._(JSObject _) implements JSObject {
  external factory _Request({
    required JSNumber id,
    required JSString operation,
    required JSAny? value,
  });
}

final _codec = _CodecWorker();

Future<Object?> executeDataCodec(
  String operation,
  Object? value, {
  bool Function()? isCurrent,
}) async {
  final work = UiWorkBudget(
    maxItems: 2048,
    isCurrent: isCurrent,
    debugLabel: 'draft-codec-transfer',
  );
  work.ensureCurrent();
  if (_inlineSafe(value)) {
    return switch (operation) {
      'json-encode' => jsonEncode(value),
      'json-decode' => jsonDecode(value as String),
      'base64-encode' => base64Encode(value as Uint8List),
      'base64-decode' => base64Decode(value as String),
      'utf8-encode' => Uint8List.fromList(utf8.encode(value as String)),
      'utf8-decode' => utf8.decode(value as Uint8List),
      'utf8-decode-lossy' => utf8.decode(
        value as Uint8List,
        allowMalformed: true,
      ),
      _ => throw ArgumentError.value(operation),
    };
  }
  final JSAny? input;
  if (operation == 'json-encode') {
    input = await _jsonTokens(value, work);
  } else if (value is Uint8List) {
    input = value.toJS;
  } else {
    input = (value as String).toJS;
  }
  work.ensureCurrent();
  final result = await _codec.run(operation, input);
  work.ensureCurrent();
  if (operation == 'json-decode') return _materialise(result, work);
  if (operation == 'base64-decode' || operation == 'utf8-encode') {
    return (result as JSUint8Array).toDart;
  }
  return (result as JSString).toDart;
}

bool _inlineSafe(Object? value) {
  var size = 0;
  final stack = <Object?>[value];
  while (stack.isNotEmpty) {
    final item = stack.removeLast();
    if (item is String) {
      size += item.length;
    } else if (item is Uint8List) {
      size += item.length;
    } else if (item is Map<String, dynamic>) {
      size += item.length * 8;
      if (size >= 32768) return false;
      stack.addAll(item.keys);
      stack.addAll(item.values);
    } else if (item is List) {
      size += item.length * 4;
      if (size >= 32768) return false;
      stack.addAll(item);
    } else {
      size += 8;
    }
    if (size >= 32768) return false;
  }
  return true;
}

/// Numbers are rendered by Dart before transfer, preserving 1.0/-0.0 and the
/// existing codec's finite-number rejection. The worker quotes large strings.
Future<JSArray<JSAny?>> _jsonTokens(Object? value, UiWorkBudget work) async {
  final tokens = <JSAny?>[].toJS;
  final stack = <Object?>[value];
  while (stack.isNotEmpty) {
    final item = stack.removeLast();
    if (item is _Literal) {
      tokens.add(item.text.toJS);
    } else if (item is String) {
      tokens.add(<JSAny?>[1.toJS, item.toJS].toJS);
    } else if (item == null || item is bool || item is num) {
      tokens.add(jsonEncode(item).toJS);
    } else if (item is List) {
      tokens.add('['.toJS);
      stack.add(const _Literal(']'));
      for (var i = item.length - 1; i >= 0; i--) {
        stack.add(item[i]);
        if (i > 0) stack.add(const _Literal(','));
      }
    } else if (item is Map<String, dynamic>) {
      tokens.add('{'.toJS);
      stack.add(const _Literal('}'));
      final entries = item.entries.toList(growable: false);
      for (var i = entries.length - 1; i >= 0; i--) {
        stack.add(entries[i].value);
        stack.add(const _Literal(':'));
        stack.add(entries[i].key);
        if (i > 0) stack.add(const _Literal(','));
      }
    } else {
      throw JsonUnsupportedObjectError(item);
    }
    await work.checkpoint();
  }
  return tokens;
}

class _Literal {
  const _Literal(this.text);
  final String text;
}

Future<Object?> _materialise(JSAny? source, UiWorkBudget work) async {
  Future<Object?> visit(JSAny? value) async {
    work.ensureCurrent();
    if (value == null || value.isUndefinedOrNull) return null;
    if (value.typeofEquals('string')) return (value as JSString).toDart;
    if (value.typeofEquals('boolean')) return (value as JSBoolean).toDart;
    if (value.typeofEquals('number')) {
      final number = (value as JSNumber).toDartDouble;
      return number.isFinite &&
              !(number == 0 && number.isNegative) &&
              number == number.truncateToDouble()
          ? number.toInt()
          : number;
    }
    if (_isArray(value)) {
      final array = value as JSArray<JSAny?>;
      final result = <Object?>[];
      for (var i = 0; i < array.length; i++) {
        result.add(await visit(array[i]));
        await work.checkpoint();
      }
      return result;
    }
    final object = value as JSObject;
    final keys = _objectKeys(object).toDart;
    final result = <String, dynamic>{};
    for (final key in keys) {
      result[key.toDart] = await visit(object.getProperty<JSAny?>(key));
      await work.checkpoint();
    }
    return result;
  }

  final result = await visit(source);
  work.ensureCurrent();
  return result;
}

class _CodecWorker {
  web.Worker? _worker;
  Timer? _idle;
  int _id = 0;
  final _pending = <int, Completer<JSAny?>>{};
  Future<JSAny?> run(String operation, JSAny? value) async {
    _idle?.cancel();
    final worker = _ensure();
    final id = ++_id;
    final result = Completer<JSAny?>();
    _pending[id] = result;
    try {
      worker.postMessage(
        _Request(id: id.toJS, operation: operation.toJS, value: value),
      );
      return await result.future.timeout(const Duration(seconds: 60));
    } finally {
      _pending.remove(id);
      if (_pending.isEmpty) {
        _idle = Timer(const Duration(seconds: 20), () {
          _worker?.terminate();
          _worker = null;
        });
      }
    }
  }

  web.Worker _ensure() {
    if (_worker case final worker?) return worker;
    const workerPath = String.fromEnvironment(
      'UTEN_DATA_CODEC_WORKER_PATH',
      defaultValue: 'uten_data_codec_worker.js',
    );
    final worker = web.Worker(
      Uri.parse(web.document.baseURI).resolve(workerPath).toString().toJS,
    );
    worker.onmessage = ((web.MessageEvent event) {
      final data = event.data as JSObject;
      final id = data.getProperty<JSNumber>('id'.toJS).toDartInt;
      final pending = _pending[id];
      if (pending == null || pending.isCompleted) return;
      if (data.hasProperty('error'.toJS).toDart) {
        pending.completeError(
          const FormatException('Invalid local data encoding'),
        );
      } else {
        pending.complete(data.getProperty<JSAny?>('value'.toJS));
      }
    }).toJS;
    void fail() {
      worker.terminate();
      _worker = null;
      for (final pending in _pending.values) {
        if (!pending.isCompleted) {
          pending.completeError(
            StateError('Local data codec worker unavailable'),
          );
        }
      }
    }

    worker.onerror = ((web.Event _) => fail()).toJS;
    worker.onmessageerror = ((web.Event _) => fail()).toJS;
    return _worker = worker;
  }
}
