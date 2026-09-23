// 「自动请求」声明回归 (ADR-110)。
//
// 钉住的规则：用户 30 秒内有过输入时发出的请求是人为请求 (不带声明头，服务端据此续期会话)；
// 超过 30 秒没有输入时发出的任何请求——不管是哪个端点、是否计数类——都带 X-Uten-Automatic: 1，
// 服务端不续期。按「人在不在场」判定，新增轮询不需要登记。重发的请求按重发时刻重新判定。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/interceptors/automatic_request_interceptor.dart';
import 'package:uten_imp/core/network/user_activity.dart';
import 'package:uten_imp/shared/widgets/user_activity_tracker.dart';

void main() {
  var now = DateTime(2026, 9, 23, 9);

  setUp(() {
    UserActivity.reset();
    now = DateTime(2026, 9, 23, 9);
    UserActivity.clock = () => now;
  });
  tearDown(UserActivity.reset);

  test('没有任何输入: 页面自己发的请求都声明为自动请求', () async {
    final adapter = _Adapter();
    final dio = _dio(adapter);

    await dio.get<dynamic>('/admin/server-status');
    await dio.get<dynamic>('/notices/unread-count-by-source');

    expect(
      adapter.sent.map((o) => o.headers[AutomaticRequestInterceptor.header]),
      ['1', '1'],
    );
  });

  test('刚有输入: 人为请求不带声明头; 超过 30 秒没有输入后同一个端点又带上', () async {
    final adapter = _Adapter();
    final dio = _dio(adapter);

    UserActivity.record();
    now = now.add(const Duration(seconds: 5));
    await dio.get<dynamic>('/production/material-analyses/abc');
    now = now.add(const Duration(seconds: 26));
    await dio.get<dynamic>('/production/material-analyses/abc');

    expect(adapter.sent.first.headers, isNot(contains('X-Uten-Automatic')));
    expect(adapter.sent.last.headers[AutomaticRequestInterceptor.header], '1');
  });

  test('重用同一份请求配置重发时按重发时刻重新判定', () async {
    final adapter = _Adapter();
    final dio = _dio(adapter);
    final options = RequestOptions(path: '/sales/orders', method: 'GET');

    await dio.fetch<dynamic>(options);
    UserActivity.record();
    await dio.fetch<dynamic>(options);

    expect(adapter.sent.first.headers[AutomaticRequestInterceptor.header], '1');
    expect(adapter.sent.last.headers, isNot(contains('X-Uten-Automatic')));
  });

  testWidgets('全局采集: 指针与按键都算输入 (含根导航器弹窗里的操作)', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              UserActivityTracker(),
              Center(child: Text('工作台')),
            ],
          ),
        ),
      ),
    );
    expect(UserActivity.lastInputAt, isNull);

    await tester.tapAt(const Offset(10, 10));
    expect(UserActivity.lastInputAt, now);

    now = now.add(const Duration(minutes: 1));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(20, 20));
    await gesture.moveTo(const Offset(40, 40));
    expect(UserActivity.lastInputAt, now);

    now = now.add(const Duration(minutes: 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(UserActivity.lastInputAt, now);
    await gesture.removePointer();
  });
}

Dio _dio(_Adapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(const AutomaticRequestInterceptor());
  return dio;
}

class _Adapter implements HttpClientAdapter {
  final List<RequestOptions> sent = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    sent.add(
      options.copyWith(headers: Map<String, dynamic>.of(options.headers)),
    );
    return ResponseBody.fromString(
      jsonEncode({'ok': true}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
