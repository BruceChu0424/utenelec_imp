import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_batch_repository.dart';

void main() {
  for (final entry in {
    BomBatchAction.add: 'ADD',
    BomBatchAction.remove: 'REMOVE',
    BomBatchAction.overwrite: 'OVERWRITE',
  }.entries) {
    test('${entry.value} preview only submits its reviewed command', () async {
      final api = _BatchApi()..previewResponse = _preview(entry.value);
      final repository = DioGoodsBomBatchRepository(api);
      final items = <Map<String, dynamic>>[
        {'componentGoodsId': 'washer', 'qty': 2, 'summary': '固定用'},
      ];
      final preview = await repository.preview(
        action: entry.key,
        targetGoodsIds: ['switch-1', 'switch-2'],
        items: entry.key == BomBatchAction.remove ? const [] : items,
        componentGoodsIds: entry.key == BomBatchAction.remove
            ? ['old-screw', 'old-washer']
            : const [],
      );

      expect(api.commands, hasLength(1));
      final command = api.commands.single;
      expect(command.$1, '/master/goods/bom/batch-maintenance/preview');
      expect(command.$2['action'], entry.value);
      expect(command.$2['targetGoodsIds'], ['switch-1', 'switch-2']);
      expect(
        command.$2['items'] ?? const <Map<String, dynamic>>[],
        entry.key == BomBatchAction.remove
            ? const <Map<String, dynamic>>[]
            : items,
      );
      expect(
        command.$2['componentGoodsIds'] ?? const <String>[],
        entry.key == BomBatchAction.remove
            ? ['old-screw', 'old-washer']
            : const <String>[],
      );
      expect(command.$2.containsKey('previewToken'), isFalse);
      expect(preview.previewToken, 'reviewed-token');
    });
  }

  test(
    'preview retains target changes and the complete shared impact',
    () async {
      final api = _BatchApi()..previewResponse = _preview('ADD');
      final preview = await DioGoodsBomBatchRepository(api).preview(
        action: BomBatchAction.add,
        targetGoodsIds: ['switch-1', 'switch-2'],
        items: [
          {'componentGoodsId': 'washer', 'qty': 2},
        ],
      );

      expect(preview.action, BomBatchAction.add);
      expect(preview.selectedTargetCount, 2);
      expect(preview.changedTargetCount, 1);
      expect(preview.added, 1);
      expect(preview.updated, 2);
      expect(preview.removed, 3);
      expect(preview.skipped, 4);
      expect(preview.otherUsageCount, 5);
      expect(preview.hiddenUsageCount, 1);
      expect(preview.expiresAt, DateTime.utc(2099));
      expect(preview.warnings, ['铁架也被其他产品引用']);
      final target = preview.targets.single;
      expect(target.goodsId, 'switch-1');
      expect(target.goodsCode, 'SW001');
      expect(target.goodsName, '单联开关');
      expect(target.added, 1);
      expect(target.updated, 2);
      expect(target.removed, 3);
      expect(target.skipped, 4);
      expect(preview.affectedProducts, hasLength(2));
      final shared = preview.affectedProducts.last;
      expect(shared.goodsId, 'shared-product');
      expect(shared.goodsCode, 'SH001');
      expect(shared.goodsName, '引用铁架的产品');
      expect(shared.selected, isFalse);
      expect(preview.affectedProducts.first.selected, isTrue);
    },
  );

  for (final confirmed in [false, true]) {
    test('commit forwards the exact token and consent=$confirmed', () async {
      final api = _BatchApi()..commitResponse = _result();
      final result = await DioGoodsBomBatchRepository(
        api,
      ).commit('reviewed-token', confirmSharedChanges: confirmed);

      expect(api.commands, hasLength(1));
      expect(
        api.commands.single.$1,
        '/master/goods/bom/batch-maintenance/commit',
      );
      expect(api.commands.single.$2, {
        'previewToken': 'reviewed-token',
        'confirmSharedChanges': confirmed,
      });
      expect(result.selectedTargetCount, 2);
      expect(result.changedTargetCount, 1);
      expect(result.added, 1);
      expect(result.updated, 2);
      expect(result.removed, 3);
      expect(result.skipped, 4);
      expect(result.affectedProductCount, 6);
      expect(result.targets.single.goodsId, 'switch-1');
      expect(result.targets.single.updated, 2);
      expect(result.warnings, ['铁架也被其他产品引用']);
    });
  }

  test(
    'mutable picker collections cannot change the in-flight intent',
    () async {
      final api = _BatchApi();
      final targetIds = ['switch-1'];
      final item = <String, dynamic>{
        'componentGoodsId': 'washer',
        'qty': 2,
        'summary': '已核对的用量',
      };
      final items = [item];
      final pending = DioGoodsBomBatchRepository(api).preview(
        action: BomBatchAction.add,
        targetGoodsIds: targetIds,
        items: items,
      );
      targetIds.add('unreviewed-product');
      item['qty'] = 99;
      items.clear();
      await pending;

      final body = api.commands.single.$2;
      expect(body['targetGoodsIds'], ['switch-1']);
      expect(body['items'], [
        {'componentGoodsId': 'washer', 'qty': 2, 'summary': '已核对的用量'},
      ]);
    },
  );

  test('optional absent or null details do not invent changes', () async {
    final api = _BatchApi()
      ..previewResponse = {
        'previewToken': 'empty-token',
        'action': 'REMOVE',
        'selectedTargetCount': 1,
        'changedTargetCount': 0,
        'added': 0,
        'removed': 0,
        'skipped': 1,
        'targets': [
          {'goodsId': 'switch-1', 'added': 0, 'removed': 0, 'skipped': 1},
        ],
        'affectedProducts': null,
        'otherUsageCount': null,
        'hiddenUsageCount': null,
        'expiresAt': null,
        'warnings': null,
      }
      ..commitResponse = {
        'selectedTargetCount': 1,
        'changedTargetCount': 0,
        'added': 0,
        'removed': 0,
        'skipped': 1,
        'updated': null,
        'targets': null,
        'warnings': null,
      };
    final repository = DioGoodsBomBatchRepository(api);
    final preview = await repository.preview(
      action: BomBatchAction.remove,
      targetGoodsIds: ['switch-1'],
      componentGoodsIds: ['absent-component'],
    );
    expect(preview.updated, 0);
    expect(preview.targets.single.updated, 0);
    expect(preview.targets.single.goodsCode, isNull);
    expect(preview.targets.single.goodsName, isNull);
    expect(preview.affectedProducts, isEmpty);
    expect(preview.otherUsageCount, 0);
    expect(preview.hiddenUsageCount, 0);
    expect(preview.expiresAt, isNull);
    expect(preview.warnings, isEmpty);

    final result = await repository.commit(
      preview.previewToken,
      confirmSharedChanges: false,
    );
    expect(result.updated, 0);
    expect(result.affectedProductCount, 0);
    expect(result.targets, isEmpty);
    expect(result.warnings, isEmpty);
  });

  test('rejected commands preserve the server business error', () async {
    final conflict = ApiException(
      'BOM_BATCH_CONFLICT',
      '组装信息已变化，请重新预览',
      httpStatus: 409,
      hasResponseCode: true,
    );
    final api = _BatchApi()..failure = conflict;
    final repository = DioGoodsBomBatchRepository(api);
    await expectLater(
      repository.commit('stale-token', confirmSharedChanges: true),
      throwsA(same(conflict)),
    );
    expect(api.commands, hasLength(1));
  });

  test('uncertain commit errors retain the reviewed receipt recovery path', () {
    for (final error in <Object>[
      NetworkException(),
      NetworkTimeoutException(),
      ApiException('INTERNAL', '网关没有返回回执', httpStatus: 502),
      ApiException('INTERNAL', '服务端错误', httpStatus: 500, hasResponseCode: true),
      ApiException(
        'CONFLICT',
        '错误页沿用了业务码',
        httpStatus: 503,
        hasResponseCode: true,
      ),
      StateError('response decoding failed'),
    ]) {
      expect(isBomBatchCommitUncertain(error), isTrue, reason: '$error');
    }
    for (final error in <Object>[
      ApiException(
        'BOM_BATCH_CONFLICT',
        '需要重新预览',
        httpStatus: 409,
        hasResponseCode: true,
      ),
      ApiException('FORBIDDEN', '权限已收回', httpStatus: 403),
      ApiException('INTERNAL', '请求格式明确被拒绝', httpStatus: 400),
      ApiException(
        'VALIDATION_FAILED',
        '组件不能是自己',
        httpStatus: 422,
        hasResponseCode: true,
      ),
      ApiException('SESSION_CHANGED', '登录已变化'),
      ApiException('SESSION_STATE_UNAVAILABLE', '无法确认登录'),
    ]) {
      expect(isBomBatchCommitUncertain(error), isFalse, reason: '$error');
    }
  });
}

Map<String, dynamic> _preview(String action) => {
  'previewToken': 'reviewed-token',
  'action': action,
  ..._result(),
  'affectedProducts': [
    {
      'goodsId': 'switch-1',
      'goodsCode': 'SW001',
      'goodsName': '单联开关',
      'selected': true,
    },
    {
      'goodsId': 'shared-product',
      'goodsCode': 'SH001',
      'goodsName': '引用铁架的产品',
      'selected': false,
    },
  ],
  'otherUsageCount': 5,
  'hiddenUsageCount': 1,
  'expiresAt': '2099-01-01T00:00:00Z',
};

Map<String, dynamic> _result() => {
  'selectedTargetCount': 2,
  'changedTargetCount': 1,
  'added': 1,
  'updated': 2,
  'removed': 3,
  'skipped': 4,
  'affectedProductCount': 6,
  'targets': [
    {
      'goodsId': 'switch-1',
      'goodsCode': 'SW001',
      'goodsName': '单联开关',
      'added': 1,
      'updated': 2,
      'removed': 3,
      'skipped': 4,
    },
  ],
  'warnings': ['铁架也被其他产品引用'],
};

class _BatchApi extends ApiClient {
  _BatchApi() : super(Dio());

  final commands = <(String, Map<String, dynamic>)>[];
  Map<String, dynamic> previewResponse = _preview('ADD');
  Map<String, dynamic> commitResponse = _result();
  Object? failure;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    commands.add((path, Map<String, dynamic>.from(body! as Map)));
    if (failure case final error?) throw error;
    return path.endsWith('/preview') ? previewResponse : commitResponse;
  }
}
