import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/health_probe.dart';

class _ProbeAdapter implements HttpClientAdapter {
  _ProbeAdapter({
    this.status = 200,
    this.body = '{"status":"UP"}',
    this.failure,
  });

  final int status;
  final String body;
  final DioExceptionType? failure;
  final requests = <RequestOptions>[];
  bool closed = false;

  Dio create(BaseOptions options) => Dio(options)..httpClientAdapter = this;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (failure != null) {
      throw DioException(requestOptions: options, type: failure!);
    }
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        if (status == 302)
          'location': ['https://cloud.example.test/actuator/health'],
      },
    );
  }

  @override
  void close({bool force = false}) => closed = true;
}

void main() {
  for (final status in [200, 302, 401, 403, 404, 500, 503]) {
    test(
      'local HTTP $status proves reachability without a credentialed request',
      () async {
        final adapter = _ProbeAdapter(
          status: status,
          body: '{"status":"DOWN"}',
        );
        expect(
          await probeServerReachability(
            'https://local.example.test',
            dioFactory: adapter.create,
          ),
          isTrue,
        );
        expect(adapter.requests.single.method, 'GET');
        expect(
          adapter.requests.single.path,
          'https://local.example.test/actuator/health',
        );
        expect(adapter.requests.single.followRedirects, isFalse);
        expect(
          adapter.requests.single.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('authorization')),
        );
        expect(adapter.closed, isTrue);
      },
    );
  }

  test(
    'recovery health still requires HTTP200 and a valid explicit UP payload',
    () async {
      final healthy = _ProbeAdapter();
      expect(
        await probeHealth(
          'https://local.example.test',
          dioFactory: healthy.create,
        ),
        isTrue,
      );
      for (final adapter in [
        _ProbeAdapter(status: 503, body: '{"status":"DOWN"}'),
        _ProbeAdapter(body: '<html>not actuator</html>'),
        _ProbeAdapter(status: 302),
      ]) {
        expect(
          await probeHealth(
            'https://local.example.test',
            dioFactory: adapter.create,
          ),
          isFalse,
        );
        expect(adapter.requests, hasLength(1));
        expect(adapter.requests.single.followRedirects, isFalse);
        expect(adapter.closed, isTrue);
      }
    },
  );

  for (final failure in [
    DioExceptionType.connectionError,
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.badCertificate,
  ]) {
    test(
      'transport failure $failure does not report the local server reachable',
      () async {
        final adapter = _ProbeAdapter(failure: failure);
        expect(
          await probeServerReachability(
            'https://local.example.test',
            dioFactory: adapter.create,
          ),
          isFalse,
        );
        expect(adapter.requests, hasLength(1));
        expect(adapter.closed, isTrue);
      },
    );
  }
}
