// 报工页「转下一道工序」候选返回的解析契约(V584/V585/V595)：
// 候选列表 + 上次报工的记忆(去向 + 父件产品)。V595 起线边仓由服务端自动配置，
// 「缺线边仓」不再是空候选的原因，记忆字段取而代之。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/production_direct_transfer_candidate.dart';

void main() {
  test('parses candidates and the remembered destination', () {
    final result = DirectTransferCandidatesResult.fromJson(const {
      'candidates': [
        {
          'demandId': 'demand-uuid',
          'executionSegmentId': 'segment-uuid',
          'executionSegmentCode': 'ZX00000214',
          'executionSegmentStatus': 'WAITING',
          'planNo': 'PB20260915001',
          'goodsName': '外贸V5开关带三极多功能插座功能件',
          'unitName': '个',
          'receivingGoodsId': 'parent-goods',
          'receivingGoodsCode': 'HV5G001',
          'receivingGoodsName': '外贸V5开关带三极多功能插座功能件',
          'requiredQty': 1000,
          'alreadyCoveredQty': 200,
          'remainingQty': 800,
        },
      ],
      'lastDestination': 'WORKSHOP',
      'lastReceivingGoodsId': 'parent-goods',
      'lastReceivingGoodsName': '外贸V5开关带三极多功能插座功能件',
    });

    expect(result.candidates, hasLength(1));
    expect(result.candidates.single.demandId, 'demand-uuid');
    expect(result.candidates.single.remainingQty, 800);
    expect(result.hasMemory, isTrue);
    expect(result.lastDestination, 'WORKSHOP');
    expect(
      result.rememberedCandidate?.demandId,
      'demand-uuid',
      reason: '上次投给的父件产品只对应一个候选时直接命中',
    );
    expect(
      result.candidates.single.label,
      contains('外贸V5开关带三极多功能插座功能件 HV5G001'),
      reason: '收起态一行以父件产品名+编号开头，车间认「投给谁」认的是产品',
    );
    expect(
      result.candidates.single.label,
      contains('最多可送 800'),
      reason: '本来源可直送额度是关键量，不能误称整个接收任务的缺口',
    );
    expect(
      result.candidates.single.secondaryLabel,
      contains('ZX00000214'),
      reason: '下拉第二行放工单号，别挤占产品行',
    );
  });

  test('continuous receiving work orders are labelled in the dropdown', () {
    final candidate = ProductionDirectTransferCandidate.fromJson(const {
      'demandId': 'demand-uuid',
      'executionSegmentId': 'segment-uuid',
      'executionSegmentCode': 'ZX00000215',
      'executionSegmentStatus': 'IN_PROGRESS',
      'continuousSupply': true,
      'remainingQty': 60,
      'unitName': '个',
    });

    expect(candidate.continuousSupply, isTrue);
    expect(candidate.secondaryLabel, contains('持续生产中'));
  });

  test('memory does not guess between two work orders of the same product', () {
    final result = DirectTransferCandidatesResult.fromJson(const {
      'candidates': [
        {
          'demandId': 'demand-1',
          'executionSegmentId': 'segment-1',
          'receivingGoodsId': 'parent-goods',
          'remainingQty': 10,
        },
        {
          'demandId': 'demand-2',
          'executionSegmentId': 'segment-2',
          'receivingGoodsId': 'parent-goods',
          'remainingQty': 20,
        },
      ],
      'lastDestination': 'WORKSHOP',
      'lastReceivingGoodsId': 'parent-goods',
    });

    expect(result.rememberedCandidate, isNull);
  });

  test('old payloads without memory fields still parse', () {
    final result = DirectTransferCandidatesResult.fromJson(const {
      'candidates': <dynamic>[],
    });

    expect(result.candidates, isEmpty);
    expect(result.hasMemory, isFalse);
    expect(result.rememberedCandidate, isNull);
  });
}
