import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/audit/device_audit_store.dart';
import 'package:uten_imp/core/network/interceptors/device_audit_interceptor.dart';

void main() {
  test(
    'device audit header stays within its explicit request budget',
    () async {
      final repeated = List.filled(800, '长').join();
      final store = _BudgetStore(
        DeviceAuditProfile(
          installationId: '123e4567-e89b-42d3-a456-426614174001',
          platform: 'web',
          appVersion: '1.0.0',
          appBuild: 'test',
          deviceName: repeated,
          manufacturer: repeated,
          model: repeated,
          osVersion: repeated,
          formFactor: repeated,
          browserName: repeated,
          locale: repeated,
          timeZone: repeated,
        ),
      );
      late RequestOptions captured;
      final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
      dio.httpClientAdapter = _Adapter((options) {
        captured = options;
        return ResponseBody.fromString('{}', 200);
      });
      dio.interceptors.add(DeviceAuditInterceptor(store));

      await dio.get<dynamic>('/header-budget');

      final encoded = captured.headers[DeviceAuditHeaders.context]! as String;
      expect(
        encoded.length,
        lessThanOrEqualTo(DeviceAuditInterceptor.maxEncodedContextLength),
      );
      final decoded = jsonDecode(utf8.decode(base64Url.decode(encoded))) as Map;
      expect(decoded['installationId'], '123e4567-e89b-42d3-a456-426614174001');
      expect(decoded['platform'], 'web');
      expect(decoded['clientEventAt'], isNotNull);
    },
  );
}

class _BudgetStore implements DeviceAuditStore {
  _BudgetStore(this.device);

  final DeviceAuditProfile device;

  @override
  Future<DeviceAuditProfile> profile() async => device;

  @override
  Future<void> beginReceipt({
    required String clientEventId,
    required String method,
    required String path,
    required DateTime startedAt,
    required DeviceAuditProfile device,
  }) async {}

  @override
  Future<void> completeReceipt({
    required String clientEventId,
    required String outcome,
    required DateTime completedAt,
    int? statusCode,
    String? serverRequestId,
  }) async {}

  @override
  Future<LocalAuditReceipt?> findReceipt(String clientEventId) async => null;

  @override
  Future<void> updateRetentionMonths(int months) async {}
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
