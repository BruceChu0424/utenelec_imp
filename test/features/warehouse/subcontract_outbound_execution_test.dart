import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/warehouse/models/subcontract_outbound.dart';
import 'package:uten_imp/features/warehouse/models/subcontract_outbound_execution.dart';
import 'package:uten_imp/features/warehouse/widgets/subcontract_outbound_detail_table.dart';

import 'subcontract_outbound_test_support.dart';

void main() {
  OutboundPickLine line({num requested = 10000}) => OutboundPickLine.fromJson(
    outboundPickLine(
      issueItemId: 'issue-item',
      planItemId: 'plan-item',
      goodsId: 'goods',
      requestedQty: requested,
    ),
  );

  SubcontractDocItem item({num qty = 10000, num? weight}) =>
      SubcontractDocItem.fromJson(
        outboundDocItem(
          id: 'issue-item',
          planItemId: 'plan-item',
          orderItemId: 'order-item',
          goodsId: 'goods',
          qty: qty,
          weight: weight,
        ),
      );

  test('本次最多就是委外提交的领料数量, 不借用其它单据或库存的量', () {
    final draft = SubcontractOutboundLineDraft(
      line(requested: 3000),
      item(qty: 3000),
    );
    addTearDown(draft.dispose);
    expect(draft.maxEditableQty, 3000);
    expect(draft.validate(), isNull);
    draft.qty.text = '3000.0001';
    expect(draft.validate(), isNotNull);
  });

  test('精确数量校验保留计划 UUID 与货品颜色单位链, 原单实称重量带回', () {
    final draft = SubcontractOutboundLineDraft(line(), item(weight: 2.75));
    addTearDown(draft.dispose);
    expect(draft.validate(), isNull);
    expect(draft.toPayload(), containsPair('id', 'issue-item'));
    expect(draft.toPayload(), containsPair('planItemId', 'plan-item'));
    expect(draft.toPayload(), containsPair('orderItemId', 'order-item'));
    expect(draft.toPayload(), containsPair('qty', 10000));
    // 原单已记的实称重量随草稿带回可编辑格, 不改就原样保存 (ADR-135 §3.8)。
    expect(draft.toPayload(), containsPair('weight', 2.75));
    expect(draft.toPayload(), containsPair('qtyFromWeight', false));
    draft.qty.text = 'NaN';
    expect(draft.validate(), isNotNull);
    draft.selected = false;
    expect(draft.validate(), isNull);
  });

  test('实称重量格接受单位后缀并换成千克, 看不懂的输入挡在保存前', () {
    final draft = SubcontractOutboundLineDraft(line(), item());
    addTearDown(draft.dispose);
    expect(draft.toPayload(), isNot(contains('weight')), reason: '没称不带重量');
    draft.weight.weight.text.text = '850g';
    expect(draft.toPayload(), containsPair('weight', 0.85));
    draft.weight.weight.text.text = '一袋';
    expect(draft.validate(), subcontractOutboundWeightInvalid);
    draft.weight.weight.text.text = '';
    expect(draft.validate(), isNull);
  });

  test('已保存的「数量按称重推算」行回显黄框并原样再保存标记', () {
    final item = SubcontractDocItem.fromJson({
      'id': 'issue-item',
      'planItemId': 'plan-item',
      'qty': 5373,
      'weight': 10.75,
      'qtyFromWeight': true,
    });
    expect(item.qtyFromWeight, isTrue);
    expect(SubcontractDocItem.fromJson({'id': 'x'}).qtyFromWeight, isFalse);
    final draft = SubcontractOutboundLineDraft(line(), item);
    addTearDown(draft.dispose);
    expect(draft.qty.autofilled, isTrue);
    expect(draft.weight.weight.qtyEstimateNote, '保存时按称重折算的数量');
    expect(draft.toPayload(), containsPair('weight', 10.75));
    expect(draft.toPayload(), containsPair('qtyFromWeight', true));
  });

  test('批处理后续提交仅可选择尚未执行项，成功和回执未定不重放', () {
    expect(
      subcontractOutboundMaySubmit(SubcontractOutboundExecutionState.pending),
      isTrue,
    );
    for (final state in SubcontractOutboundExecutionState.values.where(
      (state) => state != SubcontractOutboundExecutionState.pending,
    )) {
      expect(subcontractOutboundMaySubmit(state), isFalse, reason: state.name);
    }
  });

  test('审核前快照发现仓库经办人或出库量被他人修改', () {
    SubcontractDocDetail doc({
      String warehouse = 'leaf-a',
      String worker = 'employee-a',
      double qty = 10,
      double? weight,
      bool qtyFromWeight = false,
    }) => SubcontractDocDetail(
      id: 'draft',
      status: 0,
      warehouseId: warehouse,
      workerId: worker,
      items: [
        SubcontractDocItem(
          id: 'line',
          planItemId: 'plan-line',
          qty: qty,
          weight: weight,
          qtyFromWeight: qtyFromWeight,
        ),
      ],
    );
    final original = subcontractOutboundDraftFingerprint(doc());
    expect(subcontractOutboundDraftFingerprint(doc()), original);
    expect(
      subcontractOutboundDraftFingerprint(doc(warehouse: 'leaf-b')),
      isNot(original),
    );
    expect(
      subcontractOutboundDraftFingerprint(doc(worker: 'employee-b')),
      isNot(original),
    );
    expect(subcontractOutboundDraftFingerprint(doc(qty: 9)), isNot(original));
    // 他人改了实称重量或「按称重推算数量」标记也算单据变了 (ADR-135 §3.8)。
    final weighed = subcontractOutboundDraftFingerprint(doc(weight: 2.5));
    expect(weighed, isNot(original));
    expect(
      subcontractOutboundDraftFingerprint(
        doc(weight: 2.5, qtyFromWeight: true),
      ),
      isNot(weighed),
    );
  });
}
