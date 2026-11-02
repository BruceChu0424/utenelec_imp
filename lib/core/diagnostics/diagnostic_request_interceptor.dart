import 'package:dio/dio.dart';
import 'diagnostic_log.dart';

/// Records operation shape/timing, never headers, query values or bodies.
class DiagnosticRequestInterceptor extends Interceptor {
  final _clocks = Expando<Stopwatch>();
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    _clocks[options] = Stopwatch()..start();
    AppDiagnostics.record(
      'request.begin',
      fields: {'method': options.method, 'path': options.path},
    );
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _finish(response.requestOptions, response.statusCode, null);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _finish(err.requestOptions, err.response?.statusCode, err.type.name);
    handler.next(err);
  }

  void _finish(RequestOptions options, int? status, String? code) {
    final watch = _clocks[options];
    _clocks[options] = null;
    AppDiagnostics.record(
      code == null ? 'request.end' : 'request.failed',
      level: code == null ? 'info' : 'warning',
      fields: {
        'method': options.method,
        'path': options.path,
        'status': status,
        'durationMs': watch?.elapsedMilliseconds,
        'code': code,
      },
    );
  }
}
