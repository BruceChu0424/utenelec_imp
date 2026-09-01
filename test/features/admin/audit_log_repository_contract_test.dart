import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/admin/models/audit_log_entry.dart';
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

  test(
    'sessions use actor UUID, Beijing dates and ten-card pagination',
    () async {
      final api = _CaptureApi({
        'items': [
          {
            'sessionId': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
            'actorId': '123e4567-e89b-42d3-a456-426614174099',
            'actorDisplay': '王小明(sales01)',
            'actorPosition': '销售专员',
            'loginAt': '2026-08-29T23:30:00Z',
            'startAction': 'login',
            'startLabel': '员工登录',
            'firstActivityAt': '2026-08-29T23:31:00Z',
            'lastActivityAt': '2026-08-30T01:00:00Z',
            'refreshExpiresAt': '2026-09-05T23:30:00Z',
            'refreshCredentialStatus': 'active',
            'refreshCredentialStatusLabel': '凭证有效',
            'status': 'active',
            'statusLabel': '仍在线',
            'operationCount': 12,
            'eventCount': 14,
            'successCount': 13,
            'failureCount': 1,
            'riskCount': 2,
            'postLogoutCount': 0,
            'timelinePartial': false,
          },
        ],
        'page': 1,
        'size': 10,
        'total': 1,
        'snapshotAuditId': 9001,
      });
      final repository = DioAuditLogRepository(api);

      final page = await repository.sessions(
        actorId: '123e4567-e89b-42d3-a456-426614174099',
        dateFrom: '2026-08-30',
        dateTo: '2026-08-30',
      );

      expect(api.path, '/admin/audit-sessions');
      expect(api.query, {
        'actorId': '123e4567-e89b-42d3-a456-426614174099',
        'dateFrom': '2026-08-30',
        'dateTo': '2026-08-30',
        'page': 1,
        'size': 10,
      });
      expect(page.snapshotAuditId, 9001);
      expect(page.totalPages, 1);
      expect(page.items.single.operationCount, 12);
      expect(page.items.single.statusLabel, '仍在线');
    },
  );

  test(
    'session events use keyset cursor and a stable audit snapshot',
    () async {
      final api = _CaptureApi({
        'items': [
          {
            'id': 42,
            'action': 'view_sales_order_detail_history',
            'actionLabel': '查看销售订单历史单据',
            'objectLabel': '销售订单',
            'targetName': 'SO-2026-001(旧系统编号 86)',
            'targetDisplayName': '销售订货单',
            'targetBusinessCode': 'SO-2026-001',
            'targetLegacyCode': '86',
            'resultLabel': '成功',
          },
        ],
        'nextCursorAt': '2026-08-30T00:30:00Z',
        'nextCursorId': 77,
        'hasMore': true,
        'snapshotAuditId': 9001,
      });
      final repository = DioAuditLogRepository(api);

      final page = await repository.sessionEvents(
        sessionId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        cursorAt: '2026-08-30T01:00:00Z',
        cursorId: 88,
        snapshotAuditId: 9001,
      );

      expect(
        api.path,
        '/admin/audit-sessions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/events',
      );
      expect(api.query, {
        'size': 20,
        'cursorAt': '2026-08-30T01:00:00Z',
        'cursorId': 88,
        'snapshotAuditId': 9001,
      });
      expect(page.items.single.targetDisplayName, '销售订货单');
      expect(page.items.single.targetBusinessCode, 'SO-2026-001');
      expect(page.items.single.targetLegacyCode, '86');
    },
  );

  test('session summary supports a direct detail-page deep link', () async {
    final api = _CaptureApi({
      'sessionId': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      'actorId': '123e4567-e89b-42d3-a456-426614174099',
      'actorDisplay': '王小明（sales01）',
      'startAction': 'login',
      'startLabel': '员工登录',
      'firstActivityAt': '2026-08-30T07:00:00+08:00',
      'lastActivityAt': '2026-08-30T08:00:00+08:00',
      'status': 'normal_logout',
      'statusLabel': '正常退出',
      'operationCount': 3,
      'eventCount': 5,
      'successCount': 5,
      'failureCount': 0,
      'postLogoutCount': 0,
      'timelinePartial': false,
      'snapshotAuditId': 9001,
    });
    final repository = DioAuditLogRepository(api);

    final summary = await repository.sessionSummary(
      sessionId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      snapshotAuditId: 9001,
    );

    expect(
      api.path,
      '/admin/audit-sessions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
    );
    expect(api.query, {'snapshotAuditId': 9001});
    expect(summary.actorDisplay, '王小明（sales01）');
    expect(summary.statusLabel, '正常退出');
    expect(summary.snapshotAuditId, 9001);
  });

  test('full audit detail parses structured business object evidence', () {
    final detail = AuditLogDetail.fromJson({
      'id': 42,
      'action': 'view_sales_order_detail_history',
      'targetName': 'SO-2026-001(旧系统编号 86)',
      'targetDisplayName': '销售订货单',
      'targetBusinessCode': 'SO-2026-001',
      'targetLegacyCode': '86',
    });

    expect(detail.targetDisplayName, '销售订货单');
    expect(detail.targetBusinessCode, 'SO-2026-001');
    expect(detail.targetLegacyCode, '86');
    expect(detail.targetName, 'SO-2026-001(旧系统编号 86)');
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
