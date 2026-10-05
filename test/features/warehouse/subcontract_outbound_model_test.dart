// 委外领料出仓模型(ADR-143 §4.3): 列表一行 = 一张待发料领料单; 拣货明细按草稿
// 明细 id 与出仓单草稿一一对上, 数量只能改少(≤ 委外提交的领料数量)。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/warehouse/models/subcontract_outbound.dart';
import 'package:uten_imp/features/warehouse/widgets/subcontract_outbound_detail_table.dart';

import 'subcontract_outbound_test_support.dart';

void main() {
  test('列表行解析: 一行一张领料单, 不带计划量/草稿量等旧字段', () {
    final task = OutboundTask.fromJson({
      'issueId': 'issue-1',
      'issueBillNo': 'EC-1',
      'planId': 'plan-1',
      'orderId': 'order-1',
      'orderBillNo': 'EO-1',
      'supplierName': '加工商',
      'warehouseId': 'leaf-1',
      'warehouseName': '原料仓',
      'lineCount': 3,
      'materialKindCount': 2,
      'submittedAt': '2026-10-04T01:00:00Z',
      'submittedByName': '委外小王',
    });
    expect(task.issueId, 'issue-1');
    expect(task.issueBillNo, 'EC-1');
    expect(task.warehouseName, '原料仓');
    expect(task.lineCount, 3);
    expect(task.materialKindCount, 2);
    expect(task.submittedByName, '委外小王');
  });

  test('拣货详情解析: 领料数量、当前数量、库位与回厂交回的委外件', () {
    final detail = OutboundTaskDetail.fromJson({
      'issueId': 'issue-1',
      'issueBillNo': 'EC-1',
      'orderBillNo': 'EO-1',
      'warehouseId': 'leaf-1',
      'version': 7,
      'lines': [
        outboundPickLine(
          issueItemId: 'item-a',
          planItemId: 'plan-a',
          requestedQty: 40,
          stockAvailableQty: 35,
          locationHint: 'B-02',
          parentGoodsName: '组装件 P',
        )..['qty'] = 30,
      ],
    });
    final line = detail.lines.single;
    expect(detail.version, 7);
    expect(line.requestedQty, 40);
    expect(line.qty, 30);
    expect(line.stockAvailableQty, 35);
    expect(line.locationHint, 'B-02');
    expect(line.parentGoodsName, '组装件 P');
  });

  group('拣货行与出仓单草稿对行', () {
    OutboundTaskDetail task(List<Map<String, dynamic>> lines) =>
        OutboundTaskDetail.fromJson({'issueId': 'issue-1', 'lines': lines});
    SubcontractDocDetail document(List<Map<String, dynamic>> items) =>
        SubcontractDocDetail.fromJson({
          'id': 'issue-1',
          'status': 0,
          'items': items,
        });

    test('按草稿明细 id 对上, 回传草稿原样的货品颜色单位与来源链', () {
      final lines = subcontractOutboundLinesOf(
        task([outboundPickLine(issueItemId: 'item-a', planItemId: 'plan-a')]),
        document([
          outboundDocItem(
            id: 'item-a',
            planItemId: 'plan-a',
            orderItemId: 'order-item-a',
            colorId: 'color-a',
            unitId: 'unit-a',
            unitRate: 12,
            qty: 80,
          ),
        ]),
      )!;
      addTearDown(() => lines.single.dispose());
      final payload = lines.single.toPayload();
      expect(payload['id'], 'item-a');
      expect(payload['planItemId'], 'plan-a');
      expect(payload['orderItemId'], 'order-item-a');
      expect(payload['colorId'], 'color-a');
      expect(payload['unitId'], 'unit-a');
      expect(payload['unitRate'], 12);
      expect(payload['parentGoodsId'], 'sc-goods-1');
      expect(payload['qty'], 80);
    });

    final mismatches =
        <String, (List<Map<String, dynamic>>, List<Map<String, dynamic>>)>{
          '草稿少一行': (
            [
              outboundPickLine(issueItemId: 'item-a', planItemId: 'plan-a'),
              outboundPickLine(issueItemId: 'item-b', planItemId: 'plan-b'),
            ],
            [outboundDocItem(id: 'item-a', planItemId: 'plan-a')],
          ),
          '草稿多一行': (
            [outboundPickLine(issueItemId: 'item-a', planItemId: 'plan-a')],
            [
              outboundDocItem(id: 'item-a', planItemId: 'plan-a'),
              outboundDocItem(id: 'item-b', planItemId: 'plan-b'),
            ],
          ),
          '明细 id 对不上': (
            [outboundPickLine(issueItemId: 'item-x', planItemId: 'plan-a')],
            [outboundDocItem(id: 'item-a', planItemId: 'plan-a')],
          ),
          '计划行换了': (
            [outboundPickLine(issueItemId: 'item-a', planItemId: 'plan-a')],
            [outboundDocItem(id: 'item-a', planItemId: 'plan-other')],
          ),
          '拣货行重复': (
            [
              outboundPickLine(issueItemId: 'item-a', planItemId: 'plan-a'),
              outboundPickLine(issueItemId: 'item-a', planItemId: 'plan-a'),
            ],
            [
              outboundDocItem(id: 'item-a', planItemId: 'plan-a'),
              outboundDocItem(id: 'item-b', planItemId: 'plan-b'),
            ],
          ),
          '没有明细': (<Map<String, dynamic>>[], <Map<String, dynamic>>[]),
        };
    for (final entry in mismatches.entries) {
      test('${entry.key}时视为单据已变, 不按货品猜行', () {
        expect(
          subcontractOutboundLinesOf(
            task(entry.value.$1),
            document(entry.value.$2),
          ),
          isNull,
        );
      });
    }
  });

  test('只能改少: 0 ≤ 数量 ≤ 领料数量, 改多或负数不放行, 0 = 本次不发', () {
    final draft = SubcontractOutboundLineDraft(
      OutboundPickLine.fromJson(
        outboundPickLine(
          issueItemId: 'item-a',
          planItemId: 'plan-a',
          requestedQty: 40,
        ),
      ),
      SubcontractDocItem.fromJson(
        outboundDocItem(id: 'item-a', planItemId: 'plan-a', qty: 40),
      ),
    );
    addTearDown(draft.dispose);
    expect(draft.maxEditableQty, 40);
    expect(draft.validate(), isNull);
    draft.qty.text = '25.5';
    expect(draft.validate(), isNull);
    draft.qty.text = '40.0001';
    expect(draft.validate(), subcontractOutboundQuantityInvalid);
    draft.qty.text = '-1';
    expect(draft.validate(), subcontractOutboundQuantityInvalid);
    draft.qty.text = '';
    expect(draft.validate(), subcontractOutboundQuantityInvalid);
    expect(draft.skipped, isFalse);
    draft.qty.text = '0';
    expect(draft.validate(), isNull, reason: '0 = 这条物料本次不发');
    expect(draft.skipped, isTrue);
    draft.selected = false;
    expect(draft.validate(), isNull, reason: '没勾选的单不参与本次出库');
  });

  test('保存回传只带数量大于 0 的行; 填 0 的行不回传, 全 0 时为空', () {
    SubcontractOutboundLineDraft draft(String id, num qty) =>
        SubcontractOutboundLineDraft(
          OutboundPickLine.fromJson(
            outboundPickLine(
              issueItemId: id,
              planItemId: 'plan-$id',
              requestedQty: 40,
            ),
          ),
          SubcontractDocItem.fromJson(
            outboundDocItem(id: id, planItemId: 'plan-$id', qty: qty),
          ),
        );
    final a = draft('item-a', 40);
    final b = draft('item-b', 0);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    expect(subcontractOutboundPayloadItems([a, b]).map((item) => item['id']), [
      'item-a',
    ]);
    a.qty.text = '0';
    expect(subcontractOutboundPayloadItems([a, b]), isEmpty);
  });
}
