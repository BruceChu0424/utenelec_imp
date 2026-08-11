import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/interceptors/safe_request_retry_interceptor.dart';
import 'package:uten_imp/core/network/network_policy.dart';

void main() {
  test('所有 API 客户端与刷新请求使用有限超时', () {
    final options = buildApiBaseOptions('https://erp.example.cn/api');
    expect(options.connectTimeout, apiConnectTimeout);
    expect(options.sendTimeout, apiSendTimeout);
    expect(options.receiveTimeout, apiReceiveTimeout);
  });

  test('只重试安全读请求的瞬时故障', () {
    final get = RequestOptions(path: '/items', method: 'GET');
    final post = RequestOptions(path: '/items', method: 'POST');

    expect(
      shouldRetrySafeRequest(
        DioException(
          requestOptions: get,
          type: DioExceptionType.connectionTimeout,
        ),
      ),
      isTrue,
    );
    expect(
      shouldRetrySafeRequest(
        DioException(
          requestOptions: post,
          type: DioExceptionType.connectionTimeout,
        ),
      ),
      isFalse,
    );
    expect(
      shouldRetrySafeRequest(
        DioException.badResponse(
          statusCode: 503,
          requestOptions: get,
          response: Response<void>(requestOptions: get, statusCode: 503),
        ),
      ),
      isTrue,
    );
    expect(
      shouldRetrySafeRequest(
        DioException.badResponse(
          statusCode: 500,
          requestOptions: get,
          response: Response<void>(requestOptions: get, statusCode: 500),
        ),
      ),
      isFalse,
    );
  });

  test('超时转换成可恢复的中文错误', () async {
    final dio = Dio(buildApiBaseOptions('https://erp.example.cn/api'));
    dio.httpClientAdapter = _Adapter((options) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.receiveTimeout,
      );
    });

    await expectLater(
      ApiClient(dio).get('/slow'),
      throwsA(
        isA<NetworkTimeoutException>()
            .having((e) => e.code, 'code', 'NETWORK_TIMEOUT')
            .having((e) => e.message, 'message', contains('网络连接超时')),
      ),
    );
  });

  test('瞬时失败的 GET 重试一次，POST 不自动重放', () async {
    var getAttempts = 0;
    final getDio = Dio(buildApiBaseOptions('https://erp.example.cn/api'));
    getDio.httpClientAdapter = _Adapter((options) {
      getAttempts++;
      if (getAttempts == 1) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      }
      return ResponseBody.fromString('{}', 200);
    });
    getDio.interceptors.add(SafeRequestRetryInterceptor(getDio));

    expect(await getDio.get<dynamic>('/items'), isA<Response<dynamic>>());
    expect(getAttempts, 2);

    var postAttempts = 0;
    final postDio = Dio(buildApiBaseOptions('https://erp.example.cn/api'));
    postDio.httpClientAdapter = _Adapter((options) {
      postAttempts++;
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      );
    });
    postDio.interceptors.add(SafeRequestRetryInterceptor(postDio));

    await expectLater(
      postDio.post<dynamic>('/items'),
      throwsA(isA<DioException>()),
    );
    expect(postAttempts, 1);
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.responder);

  final ResponseBody Function(RequestOptions options) responder;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => responder(options);

  @override
  void close({bool force = false}) {}
}
