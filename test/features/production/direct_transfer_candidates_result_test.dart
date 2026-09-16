// 报工页「转下一道工序」候选返回的解析契约(V584/V585)：
// 候选列表 + 空候选原因标记。缺线边仓曾被误读成「没有可投的上层工单/方向查错」，
// 这个标记就是为把两种空候选分开。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/production_direct_transfer_candidate.dart';

void main() {
  test('parses candidates and defaults the line-side flag to false', () {
    final result = DirectTransferCandidatesResult.fromJson(const {
      'candidates': [
        {
          'demandId': 'demand-uuid',
          'executionSegmentId': 'segment-uuid',
          'executionSegmentCode': 'ZX00000214',
          'planNo': 'PB20260915001',
          'goodsName': '外贸V5开关带三极多功能插座功能件',
          'unitName': '个',
          'receivingGoodsCode': 'HV5G001',
          'receivingGoodsName': '外贸V5开关带三极多功能插座功能件',
          'requiredQty': 1000,
          'alreadyCoveredQty': 200,
          'remainingQty': 800,
        },
      ],
      'lineSideWarehouseMissing': false,
    });

    expect(result.candidates, hasLength(1));
    expect(result.candidates.single.demandId, 'demand-uuid');
    expect(result.candidates.single.remainingQty, 800);
    expect(result.lineSideWarehouseMissing, isFalse);
    expect(
      result.candidates.single.label,
      contains('外贸V5开关带三极多功能插座功能件 HV5G001'),
      reason: '收起态一行以父件产品名+编号开头，车间认「投给谁」认的是产品',
    );
    expect(
      result.candidates.single.label,
      contains('还差 800'),
      reason: '还差多少是选择候选时的关键量，必须在收起态可见',
    );
    expect(
      result.candidates.single.secondaryLabel,
      contains('ZX00000214'),
      reason: '下拉第二行放工单号，别挤占产品行',
    );
  });

  test('empty candidates with line-side missing marks the real reason', () {
    final result = DirectTransferCandidatesResult.fromJson(const {
      'candidates': <dynamic>[],
      'lineSideWarehouseMissing': true,
    });

    expect(result.candidates, isEmpty);
    expect(result.lineSideWarehouseMissing, isTrue);
  });

  test('missing flag field falls back to false for old payloads', () {
    final result = DirectTransferCandidatesResult.fromJson(const {
      'candidates': <dynamic>[],
    });

    expect(result.candidates, isEmpty);
    expect(result.lineSideWarehouseMissing, isFalse);
  });
}
