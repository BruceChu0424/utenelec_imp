import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/admin/repositories/audit_log_repository.dart';

void main() {
  test(
    'actors uses the personnel directory endpoint and parses visitor type',
    () async {
      final api = _CaptureApi({
        'items': [
          {
            'actorId': '123e4567-e89b-42d3-a456-426614174099',
            'account': 'visitor-1',
            'actorType': 'visitor',
            'displayName': '访客一',
            'department': '外部访客',
            'lastActivityAt': '2026-08-29T08:00:00+08:00',
          },
        ],
        'page': 1,
        'size': 20,
        'total': 1,
        'totalPages': 1,
      });
      final repository = DioAuditLogRepository(api);

      final page = await repository.actors(keyword: ' 访客 ');

      expect(api.path, '/admin/audit-logs/actors');
      expect(api.query, {'page': 1, 'size': 20, 'keyword': '访客'});
      expect(page.items.single.actorType, 'visitor');
      expect(page.items.single.primaryLabel, '访客一');
    },
  );

  test(
    'ordinary list uses actor UUID, Beijing dates and activity rows',
    () async {
      final api = _CaptureApi(_emptyPage);
      final repository = DioAuditLogRepository(api);

      await repository.list(
        actorId: '123e4567-e89b-42d3-a456-426614174099',
        actorScope: 'user',
        dateFrom: '2026-08-01',
        dateTo: '2026-08-31',
      );

      expect(api.query?['actorId'], '123e4567-e89b-42d3-a456-426614174099');
      expect(api.query?['actorScope'], 'user');
      expect(api.query?['activityOnly'], isTrue);
      expect(api.query?['dateFrom'], '2026-08-01');
      expect(api.query?['dateTo'], '2026-08-31');
      expect(api.query, isNot(contains('actorAccount')));
    },
  );

  test('anonymous summary keeps the bounded date scope', () async {
    final api = _CaptureApi(_emptySummary);
    final repository = DioAuditLogRepository(api);

    await repository.summary(
      actorScope: 'anonymous',
      dateFrom: '2026-08-29',
      dateTo: '2026-08-29',
    );

    expect(api.path, '/admin/audit-logs/summary');
    expect(api.query?['actorScope'], 'anonymous');
    expect(api.query?['activityOnly'], isTrue);
    expect(api.query?['dateFrom'], '2026-08-29');
    expect(api.query?['dateTo'], '2026-08-29');
    expect(api.query, isNot(contains('actorId')));
  });

  test('exact request investigation can include database evidence', () async {
    final api = _CaptureApi(_emptyPage);
    final repository = DioAuditLogRepository(api);

    await repository.list(
      requestId: '123e4567-e89b-42d3-a456-426614174012',
      activityOnly: false,
      size: 100,
    );

    expect(api.query?['requestId'], '123e4567-e89b-42d3-a456-426614174012');
    expect(api.query?['activityOnly'], isFalse);
    expect(api.query?['size'], 100);
    expect(api.query, isNot(contains('actorId')));
    expect(api.query, isNot(contains('dateFrom')));
  });
}

const _emptyPage = <String, dynamic>{
  'items': <dynamic>[],
  'page': 1,
  'size': 20,
  'total': 0,
  'totalPages': 0,
  'snapshotId': 0,
};

const _emptySummary = <String, dynamic>{
  'total': 0,
  'riskCount': 0,
  'criticalCount': 0,
  'failedCount': 0,
  'dataChangeCount': 0,
  'dailyTrend': <dynamic>[],
};

class _CaptureApi extends ApiClient {
  _CaptureApi(this.response) : super(Dio());

  final Map<String, dynamic> response;
  String? path;
  Map<String, dynamic>? query;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    this.path = path;
    this.query = query;
    return response;
  }
}
