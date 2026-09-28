// 货品发料方式切换预览 / 提交的请求与响应形状 (ADR-131)，对齐后端
// GoodsPeriodicMaterialDtos.IssueMethodPreview 与 IssueMethodItem：
//  1. 预览读 bomRows (action 代码)、blockers、unclearedDemands (计划单号 + 工单号)、
//     binBalances (warehouseName)、openPeriods (binName)、unsettledTheory、inProgressSegments；
//  2. 预览只对同一组「发料方式 + 分摊方式」有效；
//  3. 提交按工单领料时分摊方式必须为空，回收料字段名是 isRecycledMaterial。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_issue_method.dart';

void main() {
  test('预览按服务端字段解析', () {
    final p = GoodsIssueMethodPreview.fromJson(
      {
        'goodsId': 'pp',
        'goodsName': 'PP 颗粒',
        'version': 4,
        'currentIssueMethod': 'ORDER',
        'targetIssueMethod': 'PERIODIC',
        'targetCostBasis': 'OWN',
        'unitName': '千克',
        'massUnit': true,
        'suggestedBulkPackageQty': 25,
        'bomRows': [
          {
            'bomItemId': 'b1',
            'productCode': 'CP-1',
            'productName': '外壳',
            'qty': 0.0125,
            'unitWeightGrams': 12.5,
            'action': 'CONVERT',
            'note': '改成单个重量 12.5 克',
          },
          {'bomItemId': 'b2', 'productName': '底座', 'action': 'BLOCKED'},
        ],
        'unclearedDemands': [
          {
            'demandId': 'd1',
            'planNo': 'SC20260901',
            'segmentCode': 'SC20260901-01',
            'productName': '外壳',
            'unclearedQty': 3.5,
          },
        ],
        'binBalances': [
          {'warehouseId': 'w', 'warehouseName': '注塑车间内料仓', 'qty': 40},
        ],
        'openPeriods': [
          {
            'periodId': 'p',
            'binName': '注塑车间内料仓',
            'periodNo': 3,
            'startDate': '2026-09-01',
            'status': 'COUNTED',
          },
        ],
        'unsettledTheory': [
          {'binName': '注塑车间内料仓', 'productCount': 2, 'theoryQty': 12.3},
        ],
        'inProgressSegments': [
          {'segmentId': 's', 'segmentCode': 'SC-01', 'productName': '外壳'},
        ],
        'activeChoices': [
          {'productGoodsId': 'x', 'productName': '旋钮'},
        ],
        'blockers': ['还有 1 张工单按工单领过这种料、没有清账'],
        'canSwitch': false,
      },
      goodsId: 'pp',
      target: 'PERIODIC',
    );

    expect(p.version, 4);
    expect(p.canSwitch, isFalse);
    expect(p.blockers, ['还有 1 张工单按工单领过这种料、没有清账']);
    expect(p.bomRows, hasLength(2));
    expect(p.bomRows.first.mustFixFirst, isFalse);
    expect(p.bomRows.last.mustFixFirst, isTrue);
    expect(p.bomRows.first.actionLabel, '改成只填单个重量');
    expect(p.unclearedDemands.single.orderLabel, 'SC20260901 / SC20260901-01');
    expect(p.binBalances.single.warehouseName, '注塑车间内料仓');
    expect(p.openPeriods.single.periodNo, 3);
    expect(p.unsettledTheory.single.productCount, 2);
    expect(p.inProgressSegments.single.segmentCode, 'SC-01');
    expect(p.activeChoices.single.productName, '旋钮');
    expect(p.suggestedBulkPackageQty, 25);
    expect(p.matches('PERIODIC', 'OWN'), isTrue);
    expect(p.matches('PERIODIC', 'SHARED'), isFalse);
    expect(p.matches('ORDER', null), isFalse);
  });

  test('提交：按工单领料不带分摊方式，回收料字段名是 isRecycledMaterial', () {
    const order = GoodsIssueMethodChange(
      goodsId: 'pp',
      expectedVersion: 4,
      issueMethod: 'ORDER',
      periodicCostBasis: 'OWN',
      recycledMaterial: true,
    );
    expect(order.toJson(), {
      'goodsId': 'pp',
      'expectedVersion': 4,
      'issueMethod': 'ORDER',
      'periodicCostBasis': null,
      'bulkPackageQty': null,
      'isRecycledMaterial': true,
    });
    const periodic = GoodsIssueMethodChange(
      goodsId: 'pp',
      expectedVersion: 4,
      issueMethod: 'PERIODIC',
      periodicCostBasis: 'SHARED',
      bulkPackageQty: 25,
    );
    expect(periodic.toJson()['periodicCostBasis'], 'SHARED');
    expect(periodic.toJson()['bulkPackageQty'], 25);
  });
}
