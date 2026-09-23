// 再认证拦截器回归 (ADR-110)。
//
// 钉住的规则：服务端回 403 REAUTH_REQUIRED 时向统一弹窗要一张一次性凭证，带
// X-Uten-Step-Up 把原请求原样重发且只重发一次；用户取消时原 403 照常抛出；
// 别的 403 一律不碰；并发要凭证时弹窗排队、一次只弹一个。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/interceptors/step_up_interceptor.dart';
import 'package:uten_imp/core/network/step_up_coordinator.dart';

void main() {
  void Function()? unregister;

  tearDown(() {
    unregister?.call();
    unregister = null;
  });

  test('403 REAUTH_REQUIRED: 弹框换到凭证后带请求头原样重发一次', () async {
    var prompts = 0;
    unregister = StepUpCoordinator.instance.register(() async {
      prompts++;
      return 'one-time-token';
    });
    final adapter = _Adapter((options) {
      if (options.headers[StepUpInterceptor.header] == 'one-time-token') {
        return _json(200, {'ok': true});
      }
      return _json(403, {'code': 'REAUTH_REQUIRED', 'message': '需要再认证'});
    });
    final dio = _dio(adapter);

    final response = await dio.put<dynamic>(
      '/admin/system-settings',
      data: {
        'changes': [
          {'key': 'lockout_minutes', 'value': '20', 'expectedValue': '15'},
        ],
      },
    );

    expect(response.statusCode, 200);
    expect(prompts, 1);
    expect(adapter.sent, hasLength(2));
    expect(adapter.sent.first.headers[StepUpInterceptor.header], isNull);
    expect(
      adapter.sent.last.headers[StepUpInterceptor.header],
      'one-time-token',
    );
    // 重发的是同一个请求：方法、路径、请求体都不变。
    expect(adapter.sent.last.method, 'PUT');
    expect(adapter.sent.last.path, '/admin/system-settings');
    expect(adapter.sent.last.data, adapter.sent.first.data);
  });

  test('用户取消输入：原 403 照常抛给页面，不重发', () async {
    unregister = StepUpCoordinator.instance.register(() async => null);
    final adapter = _Adapter(
      (_) => _json(403, {'code': 'REAUTH_REQUIRED', 'message': '需要再认证'}),
    );
    final dio = _dio(adapter);

    await expectLater(
      dio.post<dynamic>('/admin/users/u-1/reset-password'),
      throwsA(
        isA<DioException>().having(
          (e) => e.response?.statusCode,
          'status',
          403,
        ),
      ),
    );
    expect(adapter.sent, hasLength(1));
  });

  test('带凭证重发后仍被拒：只弹一次框、只重发一次，不会死循环', () async {
    var prompts = 0;
    unregister = StepUpCoordinator.instance.register(() async {
      prompts++;
      return 'stale-token';
    });
    final adapter = _Adapter(
      (_) => _json(403, {'code': 'REAUTH_REQUIRED', 'message': '凭证已用过'}),
    );
    final dio = _dio(adapter);

    await expectLater(
      dio.post<dynamic>('/admin/impersonation/enter'),
      throwsA(isA<DioException>()),
    );
    expect(prompts, 1);
    expect(adapter.sent, hasLength(2));
  });

  test('别的 403 (没有权限) 不弹框', () async {
    var prompts = 0;
    unregister = StepUpCoordinator.instance.register(() async {
      prompts++;
      return 'token';
    });
    final adapter = _Adapter(
      (_) => _json(403, {'code': 'FORBIDDEN', 'message': '没有权限'}),
    );
    final dio = _dio(adapter);

    await expectLater(
      dio.post<dynamic>('/admin/users/u-1/super-admin'),
      throwsA(isA<DioException>()),
    );
    expect(prompts, 0);
    expect(adapter.sent, hasLength(1));
  });

  test('没有登记弹窗 (如应用尚未挂载) 时直接把 403 抛出', () async {
    final adapter = _Adapter(
      (_) => _json(403, {'code': 'REAUTH_REQUIRED', 'message': '需要再认证'}),
    );
    final dio = _dio(adapter);

    await expectLater(
      dio.post<dynamic>('/admin/business-data/reset'),
      throwsA(isA<DioException>()),
    );
    expect(adapter.sent, hasLength(1));
  });

  test('并发要凭证时弹窗排队：前一个结束后才弹下一个，各拿各的凭证', () async {
    final gates = <Completer<String?>>[];
    var active = 0;
    var maxActive = 0;
    unregister = StepUpCoordinator.instance.register(() {
      active++;
      if (active > maxActive) maxActive = active;
      final gate = Completer<String?>();
      gates.add(gate);
      return gate.future.whenComplete(() => active--);
    });

    final first = StepUpCoordinator.instance.obtain();
    final second = StepUpCoordinator.instance.obtain();
    await Future<void>.delayed(Duration.zero);
    expect(gates, hasLength(1));

    gates.first.complete('token-1');
    expect(await first, 'token-1');
    await Future<void>.delayed(Duration.zero);
    expect(gates, hasLength(2));

    gates.last.complete('token-2');
    expect(await second, 'token-2');
    expect(maxActive, 1);
  });
}

Dio _dio(_Adapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(StepUpInterceptor(dio));
  return dio;
}

ResponseBody _json(int status, Map<String, Object?> body) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final ResponseBody Function(RequestOptions options) respond;
  final List<RequestOptions> sent = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // 记录请求头快照：重发时同一个 options 会被加上凭证头。
    sent.add(
      options.copyWith(headers: Map<String, dynamic>.of(options.headers)),
    );
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}
