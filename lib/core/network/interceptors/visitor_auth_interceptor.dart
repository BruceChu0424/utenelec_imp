// Visitor refresh has the same immutable-owner rule as staff recovery, while
// retaining its separate credentials, endpoint and expiration event stream.
import 'package:dio/dio.dart';
import '../../security/secure_storage.dart';
import '../../security/auth_refresh_lock.dart';
import '../api_endpoints.dart';
import '../api_exception.dart';
import '../company_tls.dart';
import '../network_policy.dart';
import '../owned_dio.dart';
import '../rejected_request_replay.dart';
import '../visitor_session_event_bus.dart';
import 'token_refresh_result.dart';

class VisitorAuthInterceptor extends Interceptor {
  VisitorAuthInterceptor({
    required this.storage,
    required this.baseUrl,
    required this.replay,
    Dio Function()? dioFactory,
  }) : _dioFactory =
           dioFactory ?? (() => createCompanyDio(buildApiBaseOptions(baseUrl)));
  final SecureStorage storage;
  final String baseUrl;
  final Dio Function() _dioFactory;
  final Future<Response<dynamic>> Function(RequestOptions) replay;
  static const _ownerKey = 'uten.visitor.requestOwner';
  final _refreshing = <(String?, int), Future<TokenRefreshResult>>{};

  bool _public(String path) => path.contains('/visitor/auth/');

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (_public(options.path)) {
      options.headers.remove('Authorization');
      handler.next(options);
      return;
    }
    try {
      final current = await storage.getVisitorTokenSnapshot();
      final owner =
          options.extra.putIfAbsent(_ownerKey, () => current)
              as VisitorTokenSnapshot;
      if (!owner.isSameSession(current) ||
          options.extra['retried'] == true &&
              options.headers['Authorization'] !=
                  (current.hasAccessToken
                      ? 'Bearer ${current.accessToken}'
                      : null)) {
        handler.reject(_changed(options));
        return;
      }
      options.headers.remove('Authorization');
      if (current.hasAccessToken) {
        options.headers['Authorization'] = 'Bearer ${current.accessToken}';
      }
      handler.next(options);
    } catch (error, stack) {
      handler.reject(
        DioException(requestOptions: options, error: error, stackTrace: stack),
      );
    }
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    if (_public(response.requestOptions.path)) {
      handler.next(response);
      return;
    }
    try {
      final owner =
          response.requestOptions.extra[_ownerKey] as VisitorTokenSnapshot?;
      final current = await storage.getVisitorTokenSnapshot();
      if (owner == null || !owner.isSameSession(current)) {
        handler.reject(_changed(response.requestOptions));
      } else {
        handler.next(response);
      }
    } catch (error, stack) {
      handler.reject(
        DioException(
          requestOptions: response.requestOptions,
          error: error,
          stackTrace: stack,
        ),
      );
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    if (err.response?.statusCode != 401 ||
        _public(options.path) ||
        options.extra['retried'] == true) {
      handler.next(err);
      return;
    }
    try {
      final owner = options.extra[_ownerKey] as VisitorTokenSnapshot?;
      final current = await storage.getVisitorTokenSnapshot();
      if (owner == null || !owner.isSameSession(current)) {
        handler.next(_changed(options));
        return;
      }
      // A sibling already rotated this owner's credentials. A delayed 401 must
      // neither refresh a new owner nor spend the rotated refresh token again.
      final result =
          current.hasAccessToken &&
              options.headers['Authorization'] !=
                  'Bearer ${current.accessToken}'
          ? TokenRefreshResult.refreshed(current.accessToken!)
          : await _refresh(current);
      if (result.disposition == TokenRefreshDisposition.rejected) {
        if (current.sessionLineage == null) {
          handler.next(result.error ?? err);
          return;
        }
        if (await storage.clearVisitorTokensIfUnchanged(current)) {
          VisitorSessionEventBus.instance.expire(
            sessionLineage: current.sessionLineage!,
            intentGeneration: current.intentGeneration,
          );
          handler.next(result.error ?? err);
        } else {
          handler.next(_changed(options));
        }
        return;
      }
      if (result.disposition != TokenRefreshDisposition.refreshed) {
        handler.next(result.error ?? err);
        return;
      }
      final latest = await storage.getVisitorTokenSnapshot();
      if (!owner.isSameSession(latest) || !latest.hasAccessToken) {
        handler.next(_changed(options));
        return;
      }
      options.extra['retried'] = true;
      options.headers['Authorization'] = 'Bearer ${latest.accessToken}';
      markDefiniteRejectionForReplay(options);
      final response = await replay(options);
      if (!owner.isSameSession(await storage.getVisitorTokenSnapshot())) {
        handler.next(_changed(options));
        return;
      }
      handler.resolve(response);
    } on DioException catch (error) {
      handler.next(error);
    } catch (error, stack) {
      handler.next(
        DioException(requestOptions: options, error: error, stackTrace: stack),
      );
    }
  }

  Future<TokenRefreshResult> _refresh(VisitorTokenSnapshot owner) {
    final key = (owner.sessionLineage, owner.generation);
    return _refreshing.putIfAbsent(key, () {
      late final Future<TokenRefreshResult> operation;
      // Visitor records are shared across browser tabs. Serialize rotation for
      // this exact owner using the existing platform Web Lock / lease contract;
      // another owner can recover independently of a retired pending refresh.
      operation =
          AuthRefreshLock.runScoped(
            'visitor-refresh:$baseUrl:${owner.sessionLineage}:${owner.intentGeneration}',
            () => _refreshOwned(owner),
            requireWebLocks: true,
          ).whenComplete(() {
            if (identical(_refreshing[key], operation)) _refreshing.remove(key);
          });
      return operation;
    });
  }

  Future<TokenRefreshResult> _refreshOwned(VisitorTokenSnapshot owner) async {
    final options = RequestOptions(path: ApiEndpoints.visitorRefresh);
    try {
      final before = await storage.getVisitorTokenSnapshot();
      if (!before.isSameSession(owner)) {
        return TokenRefreshResult.unavailable(_changed(options));
      }
      if (!before.isSameRecord(owner)) return _latestResult(owner, options);
      if (!owner.hasRefreshToken) return const TokenRefreshResult.rejected();
      final response = await withOwnedDio(
        _dioFactory,
        (client) => client.post<dynamic>(
          ApiEndpoints.visitorRefresh,
          data: {'refreshToken': owner.refreshToken},
        ),
      );
      final body = response.data;
      final access = body is Map ? body['accessToken'] : null;
      final refresh = body is Map ? body['refreshToken'] : null;
      if (access is! String ||
          access.isEmpty ||
          refresh != null && (refresh is! String || refresh.isEmpty)) {
        return TokenRefreshResult.unavailable(invalidRefreshResponse(response));
      }
      if (!await storage.saveVisitorTokensIfUnchanged(
        expected: owner,
        accessToken: access,
        refreshToken: refresh as String?,
      )) {
        return _latestResult(owner, options);
      }
      return _latestResult(owner, options);
    } on DioException catch (error) {
      return isDefinitiveRefreshRejection(error.response)
          ? TokenRefreshResult.rejected(error)
          : TokenRefreshResult.unavailable(error);
    } catch (error, stack) {
      return TokenRefreshResult.unavailable(
        DioException(requestOptions: options, error: error, stackTrace: stack),
      );
    }
  }

  Future<TokenRefreshResult> _latestResult(
    VisitorTokenSnapshot owner,
    RequestOptions options,
  ) async {
    final latest = await storage.getVisitorTokenSnapshot();
    if (!owner.isSameSession(latest) || !latest.hasAccessToken) {
      return TokenRefreshResult.unavailable(_changed(options));
    }
    return TokenRefreshResult.refreshed(latest.accessToken!);
  }

  static DioException _changed(RequestOptions options) => DioException(
    requestOptions: options,
    error: ApiException('SESSION_CHANGED', '访问身份已变化，请重新进入页面'),
  );
}
