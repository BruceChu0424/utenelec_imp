import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/admin/repositories/audit_log_repository.dart';

void main() {
  test(
    'list forwards audit filters and parses the high-water boundary',
    () async {
      late RequestOptions captured;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            captured = request;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: const {
                  'items': <dynamic>[],
                  'page': 3,
                  'size': 40,
                  'total': 81,
                  'totalPages': 3,
                  'snapshotId': 9223372036854775806,
                },
              ),
            );
          },
        ),
      );

      final repository = DioAuditLogRepository(ApiClient(dio));
      final page = await repository.list(
        page: 3,
        size: 40,
        action: 'http_',
        actorId: '123e4567-e89b-42d3-a456-426614174099',
        actorAccount: 'admin',
        keyword: ' goods/123 ',
        targetType: ' goods ',
        targetId: ' 123 ',
        eventSource: ' database ',
        requestId: ' 123e4567-e89b-42d3-a456-426614174012 ',
        operationKind: ' update ',
        actorScope: ' user ',
        snapshotId: 0,
        riskLevel: 'high',
        eventCategory: 'data_change',
        outcome: 'success',
        dateFrom: '2026-07-26',
        dateTo: '2026-08-01',
      );

      expect(captured.method, 'GET');
      expect(captured.uri.path, '/api/admin/audit-logs');
      expect(captured.uri.queryParameters, const {
        'page': '3',
        'size': '40',
        'action': 'http_',
        'actorId': '123e4567-e89b-42d3-a456-426614174099',
        'actorAccount': 'admin',
        'keyword': 'goods/123',
        'targetType': 'goods',
        'targetId': '123',
        'eventSource': 'database',
        'requestId': '123e4567-e89b-42d3-a456-426614174012',
        'operationKind': 'update',
        'actorScope': 'user',
        'activityOnly': 'true',
        'snapshotId': '0',
        'riskLevel': 'high',
        'eventCategory': 'data_change',
        'outcome': 'success',
        'dateFrom': '2026-07-26',
        'dateTo': '2026-08-01',
      });
      expect(page.page, 3);
      expect(page.totalPages, 3);
      expect(page.snapshotId, 9223372036854775806);
    },
  );

  test(
    'summary forwards the same basic filters and high-water boundary',
    () async {
      late RequestOptions captured;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            captured = request;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: const {
                  'total': 0,
                  'riskCount': 0,
                  'criticalCount': 0,
                  'failedCount': 0,
                  'dataChangeCount': 0,
                  'dailyTrend': <dynamic>[],
                },
              ),
            );
          },
        ),
      );

      final repository = DioAuditLogRepository(ApiClient(dio));
      await repository.summary(
        action: 'login',
        actorId: '123e4567-e89b-42d3-a456-426614174099',
        actorAccount: 'admin',
        keyword: 'client',
        targetType: 'clients',
        targetId: 'client-1',
        eventSource: 'security',
        requestId: '123e4567-e89b-42d3-a456-426614174012',
        operationKind: 'read',
        actorScope: 'system',
        snapshotId: 9001,
        eventCategory: 'authentication',
        dateFrom: '2026-07-26',
        dateTo: '2026-08-01',
      );

      expect(captured.method, 'GET');
      expect(captured.uri.path, '/api/admin/audit-logs/summary');
      expect(captured.uri.queryParameters, const {
        'action': 'login',
        'actorId': '123e4567-e89b-42d3-a456-426614174099',
        'actorAccount': 'admin',
        'keyword': 'client',
        'targetType': 'clients',
        'targetId': 'client-1',
        'eventSource': 'security',
        'requestId': '123e4567-e89b-42d3-a456-426614174012',
        'operationKind': 'read',
        'actorScope': 'system',
        'activityOnly': 'true',
        'snapshotId': '9001',
        'eventCategory': 'authentication',
        'dateFrom': '2026-07-26',
        'dateTo': '2026-08-01',
      });
      expect(captured.uri.queryParameters, isNot(contains('riskLevel')));
      expect(captured.uri.queryParameters, isNot(contains('outcome')));
    },
  );
}
