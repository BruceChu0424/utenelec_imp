import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:web/web.dart' as web;
import 'streaming_download_contract.dart';

HttpClientAdapter wrapStreamingDownloads(HttpClientAdapter original) =>
    _FetchDownloads(original);

@JS()
extension type _ReadableHeaders(JSObject _) implements JSObject {
  external void forEach(JSFunction callback);
}

/// Dio's XHR adapter buffers an arraybuffer even for ResponseType.stream.
/// Fetch is used only after the same Dio auth/audit/scope interceptors run.
class _FetchDownloads implements HttpClientAdapter {
  _FetchDownloads(this.original);
  final HttpClientAdapter original;
  final _active = <web.AbortController>{};
  bool _closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.extra[streamingDownloadRequestKey] != true) {
      return original.fetch(options, requestStream, cancelFuture);
    }
    if (_closed) throw StateError('Download transport is closed');
    final abort = web.AbortController();
    _active.add(abort);
    var cancelled = false;
    unawaited(
      cancelFuture?.then((_) {
        cancelled = true;
        abort.abort();
      }),
    );
    final body = BytesBuilder(copy: false);
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        if (body.length + chunk.length > maxDownloadErrorBytes) {
          _active.remove(abort);
          throw StateError('Download request is too large');
        }
        body.add(chunk);
      }
    }
    final headers = web.Headers();
    options.headers.forEach((key, value) {
      if (key.toLowerCase() != Headers.contentLengthHeader && value != null) {
        headers.set(
          key,
          value is Iterable ? value.join(', ') : value.toString(),
        );
      }
    });
    final init = web.RequestInit(
      method: options.method,
      headers: headers,
      body: body.length == 0 ? null : body.takeBytes().toJS,
      credentials: options.extra['withCredentials'] == true
          ? 'include'
          : 'omit',
      redirect: 'error',
      cache: 'no-store',
      signal: abort.signal,
    );
    final web.Response response;
    try {
      var pending = web.window.fetch(options.uri.toString().toJS, init).toDart;
      final timeout = options.connectTimeout;
      if (timeout != null && timeout > Duration.zero) {
        pending = pending.timeout(
          timeout,
          onTimeout: () {
            abort.abort();
            throw DioException.connectionTimeout(
              requestOptions: options,
              timeout: timeout,
            );
          },
        );
      }
      response = await pending;
    } catch (error) {
      _active.remove(abort);
      if (error is DioException) rethrow;
      if (cancelled) {
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: 'Download cancelled',
        );
      }
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'File connection failed',
        error: error,
      );
    }
    final responseHeaders = <String, List<String>>{};
    _ReadableHeaders(response.headers).forEach(
      ((JSString value, JSString key) {
        responseHeaders[key.toDart] = [value.toDart];
      }).toJS,
    );
    final responseBody = response.body;
    if (responseBody == null) {
      _active.remove(abort);
      return ResponseBody(
        const Stream<Uint8List>.empty(),
        response.status,
        headers: responseHeaders,
      );
    }
    final reader = web.ReadableStreamDefaultReader(responseBody);
    Stream<Uint8List> chunks() async* {
      var finished = false;
      try {
        while (true) {
          final next = await reader.read().toDart;
          if (next.done) {
            finished = true;
            break;
          }
          if (cancelled) {
            throw DioException.requestCancelled(
              requestOptions: options,
              reason: 'Download cancelled',
            );
          }
          yield (next.value as JSUint8Array).toDart;
        }
      } finally {
        _active.remove(abort);
        if (!finished) abort.abort();
        reader.releaseLock();
      }
    }

    return ResponseBody(
      chunks(),
      response.status,
      statusMessage: response.statusText,
      headers: responseHeaders,
      onClose: () {
        _active.remove(abort);
        abort.abort();
      },
    );
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    if (force) {
      for (final active in _active.toList()) {
        active.abort();
      }
      _active.clear();
    }
    original.close(force: force);
  }
}
