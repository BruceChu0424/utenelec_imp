import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:web/web.dart' as web;
import 'streaming_download_contract.dart';

HttpClientAdapter wrapStreamingDownloads(HttpClientAdapter original) =>
    _FetchApiRequests(original);

@JS()
extension type _ReadableHeaders(JSObject _) implements JSObject {
  external void forEach(JSFunction callback);
}

/// XHR both buffers streaming downloads and silently follows API redirects.
/// Fetch applies the same auth/audit/scope interceptors before dispatch, then
/// rejects redirects before credentials can escape the approved API endpoint.
class _FetchApiRequests implements HttpClientAdapter {
  _FetchApiRequests(this.original);
  final HttpClientAdapter original;
  final _active = <web.AbortController>{};
  bool _closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final streamingDownload =
        options.extra[streamingDownloadRequestKey] == true;
    if (!streamingDownload && options.followRedirects) {
      return original.fetch(options, requestStream, cancelFuture);
    }
    if (_closed) throw StateError('API transport is closed');
    final abort = web.AbortController();
    _active.add(abort);
    var cancelled = false;
    unawaited(
      cancelFuture?.then((_) {
        cancelled = true;
        abort.abort();
      }),
    );
    final Uint8List? body;
    try {
      // Dio has already encoded JSON, forms and multipart boundaries. Preserve
      // these exact bytes, with the existing small-body cap only for downloads.
      body = await _requestBytes(
        options,
        requestStream,
        cancelFuture,
        maxBytes: streamingDownload ? maxDownloadErrorBytes : null,
      );
    } catch (_) {
      _active.remove(abort);
      abort.abort();
      rethrow;
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
      body: body?.toJS,
      credentials: options.extra['withCredentials'] == true
          ? 'include'
          : 'omit',
      redirect: 'error',
      cache: 'no-store',
      signal: abort.signal,
    );
    final web.Response response;
    try {
      if (cancelled) {
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: 'API request cancelled',
        );
      }
      if (body != null) options.onSendProgress?.call(0, body.length);
      var pending = web.window.fetch(options.uri.toString().toJS, init).toDart;
      // Fetch does not expose connection/upload completion separately. Use the
      // earliest configured deadline until headers arrive; no shorter send or
      // receive limit may be silently replaced by a longer connect limit.
      final deadlines = <(Duration, DioException)>[
        if (options.connectTimeout case final timeout?
            when timeout > Duration.zero)
          (
            timeout,
            DioException.connectionTimeout(
              requestOptions: options,
              timeout: timeout,
            ),
          ),
        if (body != null &&
            options.sendTimeout != null &&
            options.sendTimeout! > Duration.zero)
          (
            options.sendTimeout!,
            DioException.sendTimeout(
              requestOptions: options,
              timeout: options.sendTimeout!,
            ),
          ),
        if (options.receiveTimeout case final timeout?
            when timeout > Duration.zero)
          (
            timeout,
            DioException.receiveTimeout(
              requestOptions: options,
              timeout: timeout,
            ),
          ),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      if (deadlines.isNotEmpty) {
        final deadline = deadlines.first;
        pending = pending.timeout(
          deadline.$1,
          onTimeout: () {
            abort.abort();
            throw deadline.$2;
          },
        );
      }
      response = await pending;
      // Fetch has no wire-upload progress event. Report completion only after
      // response headers arrive, never a fabricated intermediate percentage.
      if (body != null) options.onSendProgress?.call(body.length, body.length);
    } catch (error) {
      _active.remove(abort);
      if (error is DioException) rethrow;
      if (cancelled) {
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: 'API request cancelled',
        );
      }
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'API connection failed',
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
              reason: 'API request cancelled',
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

/// Cancel and time out request-stream preparation without waiting for another
/// chunk. Browser Fetch owns the subsequent wire upload; connectTimeout bounds
/// its wait for response headers and Dio handles receive timeouts/progress.
Future<Uint8List?> _requestBytes(
  RequestOptions options,
  Stream<Uint8List>? stream,
  Future<void>? cancelFuture, {
  int? maxBytes,
}) async {
  if (stream == null) return null;
  final bytes = BytesBuilder(copy: false);
  final completed = Completer<Uint8List>();
  Timer? timeout;
  late final StreamSubscription<Uint8List> subscription;

  void fail(Object error, [StackTrace? stack]) {
    if (completed.isCompleted) return;
    completed.completeError(error, stack);
    unawaited(subscription.cancel());
  }

  void watchSendTimeout() {
    timeout?.cancel();
    final duration = options.sendTimeout;
    if (duration == null || duration <= Duration.zero) return;
    timeout = Timer(duration, () {
      fail(
        DioException.sendTimeout(timeout: duration, requestOptions: options),
      );
    });
  }

  subscription = stream.listen(
    (chunk) {
      if (completed.isCompleted) return;
      if (maxBytes != null && bytes.length + chunk.length > maxBytes) {
        fail(StateError('Download request is too large'));
        return;
      }
      bytes.add(chunk);
      watchSendTimeout();
    },
    onError: fail,
    onDone: () {
      if (!completed.isCompleted) completed.complete(bytes.takeBytes());
    },
    cancelOnError: true,
  );
  watchSendTimeout();
  unawaited(
    cancelFuture?.then((_) {
      fail(
        DioException.requestCancelled(
          requestOptions: options,
          reason: 'API request cancelled',
        ),
      );
    }),
  );
  try {
    return await completed.future;
  } finally {
    timeout?.cancel();
  }
}
