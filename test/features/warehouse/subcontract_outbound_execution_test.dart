import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations_zh.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/warehouse/models/subcontract_outbound.dart';
import 'package:uten_imp/features/warehouse/models/subcontract_outbound_execution.dart';
import 'package:uten_imp/features/warehouse/widgets/subcontract_outbound_detail_table.dart';

void main() {
  final l10n = AppLocalizationsZh();

  OutboundPlanLine line({
    String flow = 'PREPARED_OUTBOUND',
    double ready = 0,
  }) => OutboundPlanLine.fromJson({
    'planItemId': 'plan-item',
    'orderItemId': 'order-item',
    'goodsId': 'goods',
    'flowMode': flow,
    'preparationStatus': 'READY_OUTBOUND',
    'plannedQty': 10000,
    'preparedQty': 10000,
    'draftReservedQty': 10000,
    'readyOutboundQty': ready,
  });

  test('同一计划跨实际仓拆草稿时不可借用另一草稿的占用数量', () {
    final draft = SubcontractOutboundLineDraft(
      line(),
      'own-issue-item',
      '3000',
      '',
    );
    addTearDown(draft.dispose);
    expect(draft.maxEditableQty, 3000);
    expect(draft.validate(l10n), isNull);
    draft.qty.text = '3000.0001';
    expect(draft.validate(l10n), isNotNull);
  });

  test('未知流不能借用已存草稿数量放行', () {
    final draft = SubcontractOutboundLineDraft(
      line(flow: 'UNKNOWN_NEXT'),
      'issue-item',
      '10000',
      '',
    );
    addTearDown(draft.dispose);
    expect(draft.maxEditableQty, 0);
    expect(draft.validate(l10n), isNotNull);
  });

  test('精确数量和重量校验保留计划 UUID 与货品颜色单位链', () {
    final draft = SubcontractOutboundLineDraft(
      line(),
      'issue-item',
      '10000',
      '2.75',
    );
    addTearDown(draft.dispose);
    expect(draft.validate(l10n), isNull);
    expect(draft.toPayload(), containsPair('planItemId', 'plan-item'));
    expect(draft.toPayload(), containsPair('orderItemId', 'order-item'));
    expect(draft.toPayload(), containsPair('qty', 10000));
    expect(draft.toPayload(), containsPair('weight', 2.75));
    draft.qty.text = 'NaN';
    expect(draft.validate(l10n), isNotNull);
    draft.qty.text = '10000';
    draft.weight.text = 'Infinity';
    expect(draft.validate(l10n), isNotNull);
    draft.selected = false;
    expect(draft.validate(l10n), isNull);
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
    }) => SubcontractDocDetail(
      id: 'draft',
      status: 0,
      warehouseId: warehouse,
      workerId: worker,
      items: [
        SubcontractDocItem(id: 'line', planItemId: 'plan-line', qty: qty),
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
  });
}
