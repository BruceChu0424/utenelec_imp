import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../performance/ui_work_budget.dart';

@JS('Object.keys')
external JSArray<JSString> _objectKeys(JSObject value);

@JS('Array.isArray')
external bool _isArray(JSAny value);

extension type _DecodeRequest._(JSObject _) implements JSObject {
  external factory _DecodeRequest({
    required JSNumber id,
    required JSUint8Array bytes,
  });
}

/// Same-origin worker decoding plus cooperative Dart model materialisation.
///
/// The worker has no API/storage access, cache, imports or logging. It receives
/// only an already-authorised response and is retired with its owning client.
/// Large responses never silently fall back to a blocking main-thread parse.
class ResponsiveJsonDecoder {
  web.Worker? _worker;
  bool _disposed = false;
  int _nextId = 0;
  final _pending = <int, Completer<JSAny?>>{};

  Future<Object?> decodeBytes(
    Uint8List bytes, {
    bool Function()? isCurrent,
  }) async {
    if (_disposed) throw StateError('JSON decoder is disposed');
    if (isCurrent?.call() == false) throw const UiWorkCancelled();
    if (bytes.isEmpty) return null;
    if (bytes.length < 64 * 1024) {
      return jsonDecode(utf8.decode(bytes, allowMalformed: true));
    }
    final worker = _ensureWorker();
    final id = ++_nextId;
    final result = Completer<JSAny?>();
    _pending[id] = result;
    try {
      worker.postMessage(_DecodeRequest(id: id.toJS, bytes: bytes.toJS));
      final decoded = await result.future.timeout(const Duration(seconds: 30));
      return await _materialise(decoded, isCurrent);
    } finally {
      _pending.remove(id);
    }
  }

  web.Worker _ensureWorker() {
    if (_worker case final worker?) return worker;
    // document.baseURI preserves Flutter deployments below a path prefix and
    // does not depend on the currently selected client-side route.
    final base = web.document.baseURI;
    final url = Uri.parse(base).resolve('uten_json_worker.js').toString();
    final worker = web.Worker(url.toJS);
    worker.onmessage = ((web.MessageEvent event) {
      final message = event.data as JSObject;
      final id = (message.getProperty<JSNumber>('id'.toJS)).toDartInt;
      final completer = _pending[id];
      if (completer == null || completer.isCompleted) return;
      if (message.hasProperty('error'.toJS).toDart) {
        completer.completeError(const FormatException('Invalid JSON response'));
      } else {
        completer.complete(message.getProperty<JSAny?>('value'.toJS));
      }
    }).toJS;
    worker.onerror = ((web.Event _) {
      _failPending(StateError('JSON worker is unavailable'));
    }).toJS;
    worker.onmessageerror = ((web.Event _) {
      _failPending(StateError('JSON worker response is invalid'));
    }).toJS;
    return _worker = worker;
  }

  Future<Object?> _materialise(
    JSAny? source,
    bool Function()? isCurrent,
  ) async {
    // One JSON property is much cheaper than a business projection row. The
    // elapsed-time cap still applies; a larger item cap avoids timer overhead
    // dominating responses with many scalar fields.
    final work = UiWorkBudget(
      maxItems: 4096,
      isCurrent: () => !_disposed && isCurrent?.call() != false,
      debugLabel: 'json-materialisation',
    );
    final stack = <_Container>[];
    Object? wrap(JSAny? value) {
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
        final target = List<Object?>.filled(array.length, null);
        stack.add(_Container.array(array, target));
        return target;
      }
      final object = value as JSObject;
      final target = <String, dynamic>{};
      stack.add(_Container.object(object, target, _objectKeys(object).toDart));
      return target;
    }

    work.ensureCurrent();
    final result = wrap(source);
    while (stack.isNotEmpty) {
      final container = stack.last;
      if (container.index == container.length) {
        stack.removeLast();
        continue;
      }
      final index = container.index++;
      if (container.keys case final keys?) {
        final key = keys[index];
        container.map![key.toDart] = wrap(
          container.source.getProperty<JSAny?>(key),
        );
      } else {
        container.list![index] = wrap(
          (container.source as JSArray<JSAny?>)[index],
        );
      }
      await work.checkpoint();
    }
    work.ensureCurrent();
    return result;
  }

  void _failPending(Object error) {
    _worker?.terminate();
    _worker = null;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
  }

  void dispose() {
    _disposed = true;
    _failPending(StateError('JSON decoder is disposed'));
  }
}

class _Container {
  _Container.array(this.source, this.list) : map = null, keys = null;
  _Container.object(this.source, this.map, this.keys) : list = null;

  final JSObject source;
  final List<Object?>? list;
  final Map<String, dynamic>? map;
  final List<JSString>? keys;
  int index = 0;
  int get length => keys?.length ?? list!.length;
}
