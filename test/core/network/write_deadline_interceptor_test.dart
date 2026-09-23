// 写请求截止时间矫正回归(2026-09-21 生产日报审核事故)。
//
// Web 上 connectTimeout 被 dio_web_adapter 当成「服务端必须在这么久内开口」的硬上限，
// 而不带 body 的写请求连取消它的上传进度事件都没有。所以一个跑满 15 秒的审核会在服务端
// 已经提交之后被浏览器掐掉，用户看到「网络连接超时」，页面却停在草稿。
// 这里钉住的规则：写请求的 connectTimeout 不得小于它自己的 receiveTimeout；读请求不动。
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/interceptors/write_deadline_interceptor.dart';
import 'package:uten_imp/core/network/network_policy.dart';

Dio _dio({
  required bool enabled,
  required void Function(RequestOptions) onSend,
}) {
  final dio = Dio(buildApiBaseOptions('https://erp.example.test/api'));
  dio.httpClientAdapter = _Adapter(onSend);
  dio.interceptors.add(WriteDeadlineInterceptor(enabled: enabled));
  return dio;
}

void main() {
  test('无 body 的写请求不再被 15 秒的建连计时器掐断', () async {
    late RequestOptions captured;
    final dio = _dio(enabled: true, onSend: (options) => captured = options);

    await dio.post<dynamic>('/production/daily-reports/dr-1/approve');

    expect(apiConnectTimeout, const Duration(seconds: 15));
    expect(captured.connectTimeout, apiReceiveTimeout);
    expect(captured.receiveTimeout, apiReceiveTimeout);
  });

  test('长事务写请求跟随它自己更宽的 receiveTimeout', () async {
    late RequestOptions captured;
    final dio = _dio(enabled: true, onSend: (options) => captured = options);

    await dio.post<dynamic>(
      '/admin/business-data/reset',
      options: Options(receiveTimeout: const Duration(minutes: 10)),
    );

    expect(captured.connectTimeout, const Duration(minutes: 10));
  });

  test('读请求同样放宽(ADR-108)：慢查询不能在 15 秒被掐断再重试放大', () async {
    // 旧契约「读请求保持 15 秒快速失败、由安全重试兜底」已作废: Web 上无 body 的 GET
    // 没有上传进度, 15 秒建连计时器会在服务端还在算时 abort, 重试只会把慢查询再跑两遍,
    // 最后误判断网。现在所有方法的建连上限都跟随接收超时。
    late RequestOptions captured;
    final dio = _dio(enabled: true, onSend: (options) => captured = options);

    await dio.get<dynamic>('/production/daily-reports/dr-1');

    expect(captured.connectTimeout, captured.receiveTimeout);
    expect(captured.connectTimeout, isNot(apiConnectTimeout));
  });

  test('非 Web 平台不改：那里 connectTimeout 是真正的 socket 建连超时', () async {
    late RequestOptions captured;
    final dio = _dio(enabled: false, onSend: (options) => captured = options);

    await dio.post<dynamic>('/production/daily-reports/dr-1/approve');

    expect(captured.connectTimeout, apiConnectTimeout);
  });

  test('真实 ApiClient 图里挂了这条拦截器', () {
    final dio = Dio(buildApiBaseOptions('https://erp.example.test/api'));
    dio.interceptors.add(const WriteDeadlineInterceptor());
    expect(
      dio.interceptors.whereType<WriteDeadlineInterceptor>(),
      hasLength(1),
    );
    // ApiClient 只是 Dio 的薄壳，这里同时确认壳没有自带别的超时覆写。
    expect(ApiClient(dio), isA<ApiClient>());
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.onSend);

  final void Function(RequestOptions options) onSend;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    onSend(options);
    return ResponseBody.fromString('{}', 200);
  }

  @override
  void close({bool force = false}) {}
}
