import 'package:dio/dio.dart';
import '../remote_mfa_coordinator.dart';
import 'automatic_request_interceptor.dart';

/// A successful verification still returns a failure to the original caller.
/// The user decides whether to continue. No read or write is silently replayed.
class RemoteMfaInterceptor extends Interceptor {
  RemoteMfaInterceptor({RemoteMfaCoordinator? coordinator})
    : _coordinator = coordinator ?? RemoteMfaCoordinator.instance;
  final RemoteMfaCoordinator _coordinator;
  static const _contextKey = 'uten.remoteMfa.context';
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_contextKey] = _coordinator.captureContext();
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final path = err.requestOptions.uri.path;
    final data = err.response?.data;
    if (err.requestOptions.headers[AutomaticRequestInterceptor.header] == '1' ||
        !_coordinator.matchesContext(err.requestOptions.extra[_contextKey]) ||
        err.response?.statusCode != 403 ||
        data is! Map ||
        data['code'] != 'MFA_REQUIRED' ||
        path.endsWith('/auth/login') ||
        path.endsWith('/auth/refresh') ||
        path.contains('/auth/mfa')) {
      handler.next(err);
      return;
    }
    try {
      final message = await _coordinator.obtain();
      if (message != null) {
        err.response!.data = <String, dynamic>{
          'code': 'MFA_RETRY_REQUIRED',
          'message': message,
        };
      }
    } catch (_) {
      /* Keep the original refusal when no prompt is available. */
    }
    handler.next(err);
  }
}
