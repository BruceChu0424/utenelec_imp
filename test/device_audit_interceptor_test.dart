import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/audit/device_audit_store.dart';
import 'package:uten_imp/core/network/interceptors/device_audit_interceptor.dart';
import 'package:uten_imp/core/network/interceptors/safe_request_retry_interceptor.dart';

void main() {
  test(
    'adds device context and stores a response receipt without query data',
    () async {
      final store = _Store();
      late RequestOptions captured;
      final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
      dio.httpClientAdapter = _Adapter((options) {
        captured = options;
        return ResponseBody.fromString(
          '{}',
          200,
          headers: {
            DeviceAuditHeaders.serverRequestId: [
              '123e4567-e89b-42d3-a456-426614174000',
            ],
          },
        );
      });
      dio.interceptors.add(DeviceAuditInterceptor(store));

      await dio.get<dynamic>('/orders', queryParameters: {'keyword': '秘密条件'});

      expect(captured.headers[DeviceAuditHeaders.operationId], isNotEmpty);
      expect(captured.headers[DeviceAuditHeaders.context], isNotEmpty);
      expect(store.started, hasLength(1));
      expect(store.started.single.path, '/api/orders');
      expect(store.started.single.path, isNot(contains('keyword')));
      expect(
        store.completed.single.serverRequestId,
        '123e4567-e89b-42d3-a456-426614174000',
      );
      expect(store.completed.single.statusCode, 200);
    },
  );

  test('safe GET retry reuses one client event id', () async {
    final store = _Store();
    var attempts = 0;
    final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
    dio.httpClientAdapter = _Adapter((options) {
      attempts++;
      if (attempts == 1) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      }
      return ResponseBody.fromString('{}', 200);
    });
    dio.interceptors.add(DeviceAuditInterceptor(store));
    dio.interceptors.add(SafeRequestRetryInterceptor(dio));

    await dio.get<dynamic>('/health-view');

    expect(attempts, 2);
    expect(
      store.started.map((value) => value.clientEventId).toSet(),
      hasLength(1),
    );
  });

  test(
    'audit investigation sends device headers without writing a local receipt',
    () async {
      final store = _Store();
      late RequestOptions captured;
      final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
      dio.httpClientAdapter = _Adapter((options) {
        captured = options;
        return ResponseBody.fromString('{}', 200);
      });
      dio.interceptors.add(DeviceAuditInterceptor(store));

      await dio.post<dynamic>(
        '/admin/audit-logs/local-receipt-verifications/'
        '123e4567-e89b-42d3-a456-426614174099',
      );
      await Future<void>.delayed(Duration.zero);

      expect(captured.headers[DeviceAuditHeaders.operationId], isNotEmpty);
      expect(captured.headers[DeviceAuditHeaders.context], isNotEmpty);
      expect(store.started, isEmpty);
      expect(store.completed, isEmpty);
    },
  );
}

class _Store implements DeviceAuditStore {
  final started = <LocalAuditReceipt>[];
  final completed = <_Completion>[];

  static const _profile = DeviceAuditProfile(
    installationId: '123e4567-e89b-42d3-a456-426614174001',
    deviceName: '测试电脑',
    manufacturer: 'Uten',
    model: 'QA-1',
    platform: 'windows',
    osVersion: 'Windows Test',
    appVersion: '1.0.0',
    appBuild: 'test',
    formFactor: 'desktop',
  );

  @override
  Future<DeviceAuditProfile> profile() async => _profile;

  @override
  Future<void> beginReceipt({
    required String clientEventId,
    required String method,
    required String path,
    required DateTime startedAt,
    required DeviceAuditProfile device,
  }) async {
    started.add(
      LocalAuditReceipt(
        clientEventId: clientEventId,
        installationId: device.installationId,
        method: method,
        path: path,
        startedAt: startedAt.toIso8601String(),
        outcome: 'pending',
        device: device,
      ),
    );
  }

  @override
  Future<void> completeReceipt({
    required String clientEventId,
    required String outcome,
    required DateTime completedAt,
    int? statusCode,
    String? serverRequestId,
  }) async {
    completed.add(_Completion(clientEventId, statusCode, serverRequestId));
  }

  @override
  Future<LocalAuditReceipt?> findReceipt(String clientEventId) async => null;

  @override
  Future<void> updateRetentionMonths(int months) async {}
}

class _Completion {
  const _Completion(this.clientEventId, this.statusCode, this.serverRequestId);

  final String clientEventId;
  final int? statusCode;
  final String? serverRequestId;
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
