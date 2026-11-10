import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:web/web.dart' as web;
import 'file_upload_contract.dart';
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
  final _active = <web.AbortController, _FileUploadDeadline?>{};
  bool _closed = false;

  void _release(web.AbortController abort) {
    _active.remove(abort)?.dispose();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final streamingDownload =
        options.extra[streamingDownloadRequestKey] == true;
    final uploadTimeout = options.extra[fileUploadOverallTimeoutKey];
    if (uploadTimeout != null &&
        (uploadTimeout is! Duration || uploadTimeout <= Duration.zero)) {
      throw ArgumentError.value(uploadTimeout, fileUploadOverallTimeoutKey);
    }
    if (!streamingDownload &&
        uploadTimeout == null &&
        options.followRedirects) {
      return original.fetch(options, requestStream, cancelFuture);
    }
    if (_closed) throw StateError('API transport is closed');
    final abort = web.AbortController();
    final budget = uploadTimeout is Duration
        ? _FileUploadDeadline(options, uploadTimeout, () {
            abort.abort();
            _release(abort);
          })
        : null;
    _active[abort] = budget;
    var cancelled = false;
    unawaited(
      cancelFuture?.then((_) {
        cancelled = true;
        abort.abort();
        _release(abort);
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
        overallFailure: budget?.whenFailed,
      );
    } catch (_) {
      _release(abort);
      abort.abort();
      rethrow;
    }
    final web.Response response;
    try {
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
      if (cancelled) {
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: 'API request cancelled',
        );
      }
      if (body != null) options.onSendProgress?.call(0, body.length);
      var pending = web.window.fetch(options.uri.toString().toJS, init).toDart;
      // Explicit files use their one finite whole-transfer budget, including
      // preparation and the final response body. Ordinary requests retain the
      // earliest phase deadline; a long send must not widen unrelated reads.
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
      if (budget != null) {
        pending = budget.waitFor(pending);
      } else if (deadlines.isNotEmpty) {
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
      _release(abort);
      if (budget?.hasExpired == true) throw budget!.error;
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
    final web.ReadableStreamDefaultReader reader;
    try {
      _ReadableHeaders(response.headers).forEach(
        ((JSString value, JSString key) {
          responseHeaders[key.toDart] = [value.toDart];
        }).toJS,
      );
      final responseBody = response.body;
      if (responseBody == null) {
        _release(abort);
        return ResponseBody(
          const Stream<Uint8List>.empty(),
          response.status,
          headers: responseHeaders,
        );
      }
      reader = web.ReadableStreamDefaultReader(responseBody);
    } catch (_) {
      _release(abort);
      abort.abort();
      rethrow;
    }
    var responseClosed = false;
    var readerReleased = false;
    void releaseReader() {
      if (readerReleased) return;
      readerReleased = true;
      reader.releaseLock();
    }

    Stream<Uint8List> chunks() async* {
      var finished = false;
      try {
        while (true) {
          if (cancelled || responseClosed) return;
          final pending = reader.read().toDart;
          final next = await (budget?.waitFor(pending) ?? pending);
          if (next.done) {
            finished = true;
            break;
          }
          if (cancelled || responseClosed) return;
          yield (next.value as JSUint8Array).toDart;
        }
      } catch (_) {
        // Dio owns the public cancellation/receive-timeout result and closes
        // this source before cancelling its subscription. If an async* body
        // rethrows the resulting Fetch AbortError while read() is pending, Dart
        // rejects subscription.cancel() instead of sending a stream error; Dio
        // does not await that cleanup Future. A retired reader therefore ends
        // normally here. Live readers still propagate real failures below.
        if (cancelled || responseClosed) return;
        if (budget?.hasExpired == true) throw budget!.error;
        rethrow;
      } finally {
        _release(abort);
        if (!finished) abort.abort();
        releaseReader();
      }
    }

    return ResponseBody(
      chunks(),
      response.status,
      statusMessage: response.statusText,
      headers: responseHeaders,
      onClose: () {
        responseClosed = true;
        _release(abort);
        abort.abort();
        // A caller can close a streamed response before listening. Its async*
        // finally would never run, so retire the acquired reader here as well.
        releaseReader();
      },
    );
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    if (force) {
      for (final active in _active.entries.toList()) {
        active.value?.close();
        active.key.abort();
      }
      _active.clear();
    }
    original.close(force: force);
  }
}

class _FileUploadDeadline {
  _FileUploadDeadline(
    RequestOptions options,
    Duration duration,
    void Function() abort,
  ) : error = DioException(
        requestOptions: options,
        type: DioExceptionType.sendTimeout,
        message: 'File upload exceeded its overall time budget of $duration.',
      ) {
    _timer = Timer(duration, () {
      _hasExpired = true;
      _failure.complete(error);
      abort();
    });
  }

  final DioException error;
  final _failure = Completer<DioException>();
  late final Timer _timer;
  bool _hasExpired = false;
  Future<DioException> get whenFailed => _failure.future;
  bool get hasExpired => _hasExpired;

  Future<T> waitFor<T>(Future<T> operation) =>
      Future.any([operation, whenFailed.then<T>((error) => throw error)]);

  void dispose() => _timer.cancel();

  void close() {
    dispose();
    if (!_failure.isCompleted) {
      _failure.complete(
        DioException.connectionError(
          requestOptions: error.requestOptions,
          reason: 'API transport is closed',
        ),
      );
    }
  }
}

/// Cancel and time out request-stream preparation without waiting for another
/// chunk. Explicit file budgets also cover this pre-read; Fetch then consumes
/// the remaining same budget rather than restarting it at response headers.
Future<Uint8List?> _requestBytes(
  RequestOptions options,
  Stream<Uint8List>? stream,
  Future<void>? cancelFuture, {
  int? maxBytes,
  Future<DioException>? overallFailure,
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
  unawaited(overallFailure?.then((error) => fail(error)));
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
