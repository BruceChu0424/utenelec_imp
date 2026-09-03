// DailyGridRow.clone（明细复制/粘贴，2026-09-03）：
// 整行拷贝（含来源子任务引用与可报上限——日报保存强制每行有精确来源，且按来源
// 聚合校验累计不超可报量，拷引用不会放大申报）；仅 isFinal 重置（粘贴行是新一次
// 申报，不继承完结标记）。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/widgets/production_daily_grid_columns.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  test('clone 拷贝来源子任务引用与可报上限（保存端按来源聚合限报兜底）', () {
    final src = DailyGridRow()
      ..planItemId = 'plan-1'
      ..executionSegmentId = 'seg-1'
      ..executionSegmentSalesAllocationId = 'alloc-1'
      ..executionSegmentCode = 'SEG-A'
      ..executionSegmentVersion = 3
      ..salesOrderItemId = 'soi-1'
      ..salesOrderNo = 'SO-1'
      ..clientName = '客户A'
      ..unitRate = 1.5
      ..orderQty = 100
      ..maxReportQty = 60
      ..goods = const GoodsOption(id: 'g1', name: '货品1')
      ..colorId = 'c1'
      ..unitId = 'u1'
      ..isFinal = true;
    src.qty.text = '20';
    src.weight.text = '3.2';
    src.planNo.text = 'PP-1';
    src.remark.text = '备注';

    final c = src.clone();
    expect(c.planItemId, 'plan-1');
    expect(c.executionSegmentId, 'seg-1');
    expect(c.executionSegmentSalesAllocationId, 'alloc-1');
    expect(c.executionSegmentCode, 'SEG-A');
    expect(c.executionSegmentVersion, 3);
    expect(c.salesOrderItemId, 'soi-1');
    expect(c.salesOrderNo, 'SO-1');
    expect(c.clientName, '客户A');
    expect(c.unitRate, 1.5);
    expect(c.orderQty, 100);
    expect(c.maxReportQty, 60);
    expect(c.goods?.id, 'g1');
    expect(c.colorId, 'c1');
    expect(c.unitId, 'u1');
    expect(c.qty.text, '20');
    expect(c.weight.text, '3.2');
    expect(c.planNo.text, 'PP-1');
    expect(c.remark.text, '备注');
  });

  test('isFinal 重置：粘贴行是新一次申报，不继承完结标记', () {
    final src = DailyGridRow()..isFinal = true;

    expect(src.isFinal, isTrue);
    expect(src.clone().isFinal, isFalse);
  });

  test('FQC 恢复行 clone 保留授权引用，disposition 标签可用', () {
    final src = DailyGridRow()
      ..fqcRecoveryAuthorizationId = 'auth-1'
      ..fqcRecoveryDispositionCode = 'REWORK'
      ..fqcSourceReportNo = 'DR-1';

    final c = src.clone();
    expect(c.fqcRecoveryAuthorizationId, 'auth-1');
    expect(c.fqcRecoveryDispositionCode, 'REWORK');
    expect(c.fqcSourceReportNo, 'DR-1');
    expect(c.isFqcRecovery, isTrue);
    expect(c.recoveryLabel, '返工再检');
  });
}
