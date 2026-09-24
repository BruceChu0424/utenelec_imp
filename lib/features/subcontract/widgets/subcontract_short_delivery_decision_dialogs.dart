// ADR-098 委外回厂短交判定弹窗：分批到货继续等（预计到齐日必填）/ 接受损耗结案。
//
// 两个弹窗只收集判定内容，不发请求；调用方拿到结果后再走仓库接口，失败提示留在页面。
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/models/subcontract_short_delivery.dart';

/// 判定结果：decision = WAIT_MORE / ACCEPT_LOSS。
typedef SubcontractShortDeliveryDecision = ({
  String decision,
  DateTime? expectedCompleteBy,
  String? note,
});

/// 「分批到货·继续等」：预计到齐日必填且不早于今天，说明选填。
Future<SubcontractShortDeliveryDecision?>
showSubcontractShortDeliveryWaitDialog(
  BuildContext context, {
  required SubcontractShortDeliveryCase row,
}) {
  final today = DateTime.now();
  DateTime? expected = row.expectedCompleteBy == null
      ? null
      : ChinaDateTime.tryParse(row.expectedCompleteBy);
  if (expected != null &&
      expected.isBefore(DateTime(today.year, today.month, today.day))) {
    expected = null;
  }
  final note = TextEditingController(text: row.decisionNote ?? '');
  return showDialog<SubcontractShortDeliveryDecision>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('分批到货，继续等'),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 460,
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.6,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _CaseSummary(row: row),
                const SizedBox(height: UtenSpacing.s12),
                const Text('仓库会继续等后面的批次；到了预计到齐日还没到齐，系统会再提醒你。'),
                const SizedBox(height: UtenSpacing.s12),
                UtenDateField(
                  key: const Key('short-delivery-expected-date'),
                  label: '预计到齐日期',
                  value: expected,
                  required: true,
                  firstDate: DateTime(today.year, today.month, today.day),
                  onChanged: (value) => setState(() => expected = value),
                ),
                const SizedBox(height: UtenSpacing.s12),
                UtenInput(
                  key: const Key('short-delivery-wait-note'),
                  label: '说明(选填)',
                  hint: '例如：委外商答复剩余数量下周送',
                  controller: note,
                  maxLines: 2,
                ),
              ],
            ),
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          UtenButton(
            type: UtenButtonType.ghost,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          UtenButton(
            key: const Key('short-delivery-wait-confirm'),
            onPressed: expected == null
                ? null
                : () => Navigator.pop(ctx, (
                    decision: 'WAIT_MORE',
                    expectedCompleteBy: expected,
                    note: note.text.trim().isEmpty ? null : note.text.trim(),
                  )),
            onDisabledTap: () => ScaffoldMessenger.maybeOf(
              ctx,
            )?.showSnackBar(const SnackBar(content: Text('请先填写预计到齐日期'))),
            child: const Text('确认继续等'),
          ),
        ],
      ),
    ),
  );
}

/// 「接受损耗·结案」：列出三件后果；低于允许下限时说明必填。
Future<SubcontractShortDeliveryDecision?>
showSubcontractShortDeliveryAcceptDialog(
  BuildContext context, {
  required SubcontractShortDeliveryCase row,
}) {
  final note = TextEditingController();
  final noteRequired = row.isBelowFloor;
  final unit = row.unitName;
  return showDialog<SubcontractShortDeliveryDecision>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final canConfirm = !noteRequired || note.text.trim().isNotEmpty;
        return AlertDialog(
          title: const Text('接受损耗，结案'),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 460,
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.6,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CaseSummary(row: row),
                  const SizedBox(height: UtenSpacing.s12),
                  Text(
                    '结案后剩余 ${formatSubcontractQty(row.shortfallQty, unit)} 不再等待到货，系统会自动做三件事：',
                    style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  const _Bullet(
                    '按发料时冻结的用量，把短交对应的材料登记成委外损耗单；'
                    '超出允许损耗的部分转财务判定责任。',
                  ),
                  const _Bullet('保留订货数量和来源申请占用，实收如实记录，剩余按损耗核销并结清，不重新下单。'),
                  const _Bullet(
                    '记录损耗量和损耗率，计入委外商汇总；此次结清不产生改量复核。'
                    '允许损耗范围内正常结清，不通知财务。',
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  UtenInput(
                    key: const Key('short-delivery-accept-note'),
                    label: noteRequired ? '说明(必填)' : '说明(选填)',
                    hint: noteRequired ? '低于允许损耗下限，请写明原因' : '例如：委外商确认损耗',
                    controller: note,
                    required: noteRequired,
                    maxLines: 3,
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              ),
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            UtenButton(
              type: UtenButtonType.ghost,
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            UtenButton(
              key: const Key('short-delivery-accept-confirm'),
              type: UtenButtonType.danger,
              onPressed: canConfirm
                  ? () => Navigator.pop(ctx, (
                      decision: 'ACCEPT_LOSS',
                      expectedCompleteBy: null,
                      note: note.text.trim().isEmpty ? null : note.text.trim(),
                    ))
                  : null,
              onDisabledTap: () => ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
                const SnackBar(content: Text('低于允许损耗下限的结案必须填写说明')),
              ),
              child: const Text('确认接受损耗并结案'),
            ),
          ],
        );
      },
    ),
  );
}

class _CaseSummary extends StatelessWidget {
  const _CaseSummary({required this.row});

  final SubcontractShortDeliveryCase row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unit = row.unitName;
    final floor = row.floorQty;
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: UtenRadius.controlAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '订货单 ${row.orderBillNo} · ${row.goodsLabel}',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            '订 ${formatSubcontractQty(row.orderedQty, unit)}'
            '，允许损耗 ${formatSubcontractPct(row.allowedLossPct)}'
            '${floor == null ? '' : '(最少应到 ${formatSubcontractQty(floor, unit)})'}',
          ),
          Text(
            '累计回厂 ${formatSubcontractQty(row.deliveredQty, unit)}'
            '，少 ${formatSubcontractQty(row.shortfallQty, unit)}'
            '(${formatSubcontractPct(row.shortfallPct)})'
            '${row.isSevere ? '，属严重短交' : ''}',
            style: row.isBelowFloor
                ? TextStyle(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('• '),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
