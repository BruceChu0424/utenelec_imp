// 报工页「转下一道工序」候选返回的解析契约(V584/V585/V736, ADR-127)：
// 可送的上层工单(先急后缓) + 不能收的上层工单(原因) + 不可转原因 + 一行最多转给几个工单。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/production_direct_transfer_candidate.dart';

void main() {
  test(
    'parses receivers in urgency order, blocked parents and the receiver limit',
    () {
      final result = DirectTransferCandidatesResult.fromJson(const {
        'candidates': [
          {
            'demandId': 'urgent',
            'executionSegmentId': 'segment-1',
            'executionSegmentCode': 'ZX00000642',
            'executionSegmentStatus': 'WAITING',
            'planNo': 'PB20260915001',
            'unitName': '个',
            'receivingGoodsId': 'parent-goods',
            'receivingGoodsCode': 'V6000156',
            'receivingGoodsName': '成品甲',
            'requiredQty': 1000,
            'alreadyCoveredQty': 200,
            'remainingQty': 800,
          },
          {
            'demandId': 'later',
            'executionSegmentId': 'segment-2',
            'remainingQty': 5,
          },
        ],
        'blockedTargets': [
          {
            'demandId': 'far',
            'executionSegmentCode': 'ZX00000650',
            'receivingGoodsCode': 'V6000130',
            'reasonCode': 'DIFFERENT_WORKSHOP',
            'reason': '上层工单 ZX00000650 在二车间，跨车间必须送入仓库',
          },
        ],
        'receiverLimit': 30,
      });

      expect(result.candidates.map((row) => row.demandId), ['urgent', 'later']);
      expect(result.candidates.first.remainingQty, 800);
      expect(result.receiverLimit, 30);
      expect(result.blockedText, isNull);
      final blocked = result.blockedTargets.single;
      expect(blocked.reasonCode, 'DIFFERENT_WORKSHOP');
      expect(
        blocked.optionLabel,
        'ZX00000650 · V6000130 · 上层工单 ZX00000650 在二车间，跨车间必须送入仓库',
      );
      expect(
        result.candidates.first.optionLabel(600),
        'ZX00000642 · 成品甲 V6000156 · 还差 600 个',
        reason: '下拉条目 = 工单号 · 父件产品 · 本行还能分给它的数量',
      );
    },
  );

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
    expect(candidate.optionLabel(60), endsWith('持续生产中'));
  });

  test('no eligible receiver carries the server reason as the red text', () {
    final result = DirectTransferCandidatesResult.fromJson(const {
      'candidates': <dynamic>[],
      'unavailableReasonCode': 'DIFFERENT_WORKSHOP',
      'unavailableReason': '上层工单 ZX00000653 在二车间，跨车间必须送入仓库',
    });

    expect(result.unavailableReasonCode, 'DIFFERENT_WORKSHOP');
    expect(result.blockedText, '无法转到下一道工序：上层工单 ZX00000653 在二车间，跨车间必须送入仓库');
    expect(result.loadFailed, isFalse);
  });

  test('a failed read is not an empty list', () {
    const failed = DirectTransferCandidatesResult.loadFailed();

    expect(failed.loadFailed, isTrue);
    expect(failed.blockedText, '转给工单候选读取失败，请刷新后重试');
  });

  test('a minimal payload parses with no blocked parents and no limit', () {
    final result = DirectTransferCandidatesResult.fromJson(const {
      'candidates': [
        {'demandId': 'd', 'executionSegmentId': 's', 'remainingQty': 5},
      ],
    });

    expect(result.blockedText, isNull);
    expect(result.blockedTargets, isEmpty);
    expect(result.receiverLimit, greaterThan(1000));
  });
}
