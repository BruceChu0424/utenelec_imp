import 'dart:async';

import 'package:dio/dio.dart';

/// Reserve transport capacity for visible rows and category counts. Every
/// request still crosses the ordinary authentication and read-scope fences;
/// this scheduler neither caches responses nor changes query/headers/retries.
class PageReadPriorityInterceptor extends Interceptor {
  PageReadPriorityInterceptor({
    this.maximumReads = 6,
    this.maximumAuxiliary = 2,
    this.isCurrent,
  });

  final int maximumReads;
  final int maximumAuxiliary;
  final Future<bool> Function(RequestOptions)? isCurrent;
  final _foreground = <_PendingRead>[];
  final _auxiliary = <_PendingRead>[];
  final _active = <RequestOptions, bool>{};
  bool _scheduled = false;
  bool _closed = false;
  static const _queuedAt = 'uten.pageRead.queuedAt';
  static const _dispatchedAt = 'uten.pageRead.dispatchedAt';
  final _clock = Stopwatch()..start();
  final _samples = <PageReadTiming>[];

  /// Bounded credential-free diagnostics. Paths never include query values.
  List<PageReadTiming> get timings => List.unmodifiable(_samples);

  static bool auxiliaryPath(String path) =>
      RegExp(r'/(?:facets|lookup|dict)(?:/|$)').hasMatch(Uri.parse(path).path);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final read =
        options.method == 'GET' ||
        (options.method == 'POST' && options.path.endsWith('/facets'));
    if (!read ||
        options.responseType == ResponseType.stream ||
        options.responseType == ResponseType.bytes) {
      handler.next(options);
      return;
    }
    final pending = _PendingRead(options, handler);
    options.extra[_queuedAt] = _clock.elapsedMicroseconds;
    final auxiliary = auxiliaryPath(options.path);
    final auxiliaryActive = _active.values.where((value) => value).length;
    if (!_closed &&
        options.cancelToken?.isCancelled != true &&
        _active.length < maximumReads &&
        _foreground.isEmpty &&
        (!auxiliary ||
            (_auxiliary.isEmpty && auxiliaryActive < maximumAuxiliary))) {
      // Authentication just finished. An immediately admitted request adds no
      // credential-store round trip or extra scheduling gap. Only a request
      // which really waited must revalidate that frozen identity below.
      _active[options] = auxiliary;
      options.extra[_dispatchedAt] = _clock.elapsedMicroseconds;
      handler.next(options);
      return;
    }
    (auxiliary ? _auxiliary : _foreground).add(pending);
    final cancellation = options.cancelToken;
    if (cancellation != null) {
      unawaited(
        cancellation.whenCancel.then((error) {
          if (_foreground.remove(pending) || _auxiliary.remove(pending)) {
            handler.reject(error);
            _schedule();
          }
        }),
      );
    }
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    // Return released capacity to waiting foreground work before auxiliaries.
    scheduleMicrotask(() {
      _scheduled = false;
      while (_active.length < maximumReads) {
        final auxiliaryActive = _active.values.where((value) => value).length;
        final queue = _foreground.isNotEmpty
            ? _foreground
            : auxiliaryActive < maximumAuxiliary
            ? _auxiliary
            : null;
        if (queue == null || queue.isEmpty) break;
        final pending = queue.removeAt(0);
        final options = pending.options;
        if (_closed || options.cancelToken?.isCancelled == true) {
          pending.handler.reject(
            options.cancelToken?.cancelError ??
                DioException.requestCancelled(
                  requestOptions: options,
                  reason: 'Read client closed',
                ),
          );
          continue;
        }
        _active[options] = auxiliaryPath(options.path);
        options.extra[_dispatchedAt] = _clock.elapsedMicroseconds;
        unawaited(_dispatch(pending));
      }
    });
  }

  Future<void> _dispatch(_PendingRead pending) async {
    final options = pending.options;
    try {
      // Auth already froze this request's identity. Waiting for a slot must not
      // allow it to adopt a login/impersonation which happened in the meantime.
      if (isCurrent != null && !await isCurrent!(options)) {
        throw DioException(
          requestOptions: options,
          error: 'Read identity retired while waiting',
          response: Response(
            requestOptions: options,
            statusCode: 409,
            data: const {
              'code': 'SESSION_CHANGED',
              'message': '读取身份已变化，请重新进入页面',
            },
          ),
        );
      }
      if (_closed || options.cancelToken?.isCancelled == true) {
        throw options.cancelToken?.cancelError ??
            DioException.requestCancelled(
              requestOptions: options,
              reason: 'Read client closed',
            );
      }
      pending.handler.next(options);
    } on DioException catch (error) {
      _complete(options);
      pending.handler.reject(error);
    } catch (error) {
      _complete(options);
      pending.handler.reject(
        DioException(requestOptions: options, error: error),
      );
    }
  }

  void _complete(RequestOptions options) {
    if (_active.remove(options) == null) return;
    final queued = options.extra.remove(_queuedAt) as int?;
    final dispatched = options.extra.remove(_dispatchedAt) as int?;
    if (queued != null && dispatched != null) {
      if (_samples.length == 256) _samples.removeAt(0);
      _samples.add(
        PageReadTiming(
          path: Uri.parse(options.path).path,
          queueMicroseconds: dispatched - queued,
          readMicroseconds: _clock.elapsedMicroseconds - dispatched,
        ),
      );
    }
    _schedule();
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _complete(response.requestOptions);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _complete(err.requestOptions);
    handler.next(err);
  }

  void close() {
    _closed = true;
    for (final pending in [..._foreground, ..._auxiliary]) {
      pending.handler.reject(
        DioException.requestCancelled(
          requestOptions: pending.options,
          reason: 'Read client closed',
        ),
      );
    }
    _foreground.clear();
    _auxiliary.clear();
  }
}

class PageReadTiming {
  const PageReadTiming({
    required this.path,
    required this.queueMicroseconds,
    required this.readMicroseconds,
  });
  final String path;
  final int queueMicroseconds;
  final int readMicroseconds;
}

class _PendingRead {
  _PendingRead(this.options, this.handler);
  final RequestOptions options;
  final RequestInterceptorHandler handler;
}
