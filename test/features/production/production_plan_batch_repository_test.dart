import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';

class _RecordingApi extends ApiClient {
  _RecordingApi() : super(Dio());

  final posts = <(String, Object?)>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts.add((path, body));
    return {
      'done': [
        {'id': 'p1', 'billNo': 'SC1'},
      ],
      'skipped': [
        {'id': 'p2', 'billNo': 'SC2', 'reason': '只有草稿能审核'},
      ],
    };
  }
}

/// 生产计划批量审核 / 删除(permissions-06)：一次请求、服务端单事务；
/// 不再在前端逐张调单张接口，也不再有只在前端生效的批量专属码。
void main() {
  test('batch approve is one request carrying every selected id', () async {
    final api = _RecordingApi();
    final result = await ProductionPlanRepository(
      api,
    ).batchApprove(['p1', 'p2']);

    expect(api.posts, hasLength(1));
    expect(api.posts.single.$1, '/production/plans/batch-approve');
    expect(api.posts.single.$2, {
      'ids': ['p1', 'p2'],
    });
    expect(result.done.single.billNo, 'SC1');
    expect(result.skipped.single.reason, '只有草稿能审核');
  });

  test('batch delete is one request carrying every selected id', () async {
    final api = _RecordingApi();
    await ProductionPlanRepository(api).batchDelete(['p1', 'p2']);

    expect(api.posts, hasLength(1));
    expect(api.posts.single.$1, '/production/plans/batch-delete');
  });

  test('list page no longer loops over single-plan endpoints', () {
    final source = File(
      'lib/features/production/pages/production_plan_list_page.dart',
    ).readAsStringSync();
    expect(source, contains('.batchApprove(ids)'));
    expect(source, contains('.batchDelete(ids)'));
    expect(source, isNot(contains('for (final id in ids)')));
    expect(source, isNot(contains('productionPlanBatchApprove')));
    expect(source, isNot(contains('productionPlanBatchDelete')));
  });

  test(
    'batch size is capped client-side and a lost response is not called a rollback',
    () {
      final source = File(
        'lib/features/production/pages/production_plan_list_page.dart',
      ).readAsStringSync();
      // 与服务端 PlanBatchRequest.MAX_PLANS 同值，超过先请用户分批。
      expect(ProductionPlanRepository.batchLimit, 50);
      expect(
        source,
        contains('ids.length > ProductionPlanRepository.batchLimit'),
      );
      // 超时 / 断网：先刷新列表再请用户核对，不能提示「没有任何计划被处理」。
      expect(source, contains('error is NetworkTimeoutException'));
      expect(source, contains('没能确认批量'));
    },
  );
}
