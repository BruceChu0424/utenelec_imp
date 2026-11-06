// ADR-098 委外回厂短交判定弹窗：分批到货继续等（预计到齐日必填）/ 接受损耗结案。
//
// 两个弹窗只收集判定内容，不发请求；调用方拿到结果后再走仓库接口，失败提示留在页面。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
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
}) async {
  final today = ChinaDateTime.today();
  DateTime? expected = row.expectedCompleteBy == null
      ? null
      : ChinaDateTime.tryParse(row.expectedCompleteBy);
  if (expected != null) expected = ChinaDateTime.dateOnly(expected);
  if (expected != null && expected.isBefore(today)) {
    expected = null;
  }
  final note = TextEditingController(text: row.decisionNote ?? '');
  try {
    return await UtenDialog.showAndWaitForExit<
      SubcontractShortDeliveryDecision
    >(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => UtenAlertDialog(
          scrollable: false,
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
                    firstDate: today,
                    onChanged: (value) => setState(
                      () => expected = ChinaDateTime.dateOnly(value),
                    ),
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
  } finally {
    note.dispose();
  }
}

/// 「接受损耗·结案」：列出真实后果；未达到最少应到数量时说明必填。
Future<SubcontractShortDeliveryDecision?>
showSubcontractShortDeliveryAcceptDialog(
  BuildContext context, {
  required SubcontractShortDeliveryCase row,
}) async {
  final note = TextEditingController();
  final noteRequired = row.isBelowFloor;
  final unit = row.unitName;
  try {
    return await UtenDialog.showAndWaitForExit<
      SubcontractShortDeliveryDecision
    >(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final canConfirm = !noteRequired || note.text.trim().isNotEmpty;
          return UtenAlertDialog(
            scrollable: false,
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
                      '本案件剩余 ${formatSubcontractQty(row.shortfallQtyValue, unit)} 不再等待到货；请核对结案后果：',
                      style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    const _Bullet('短交对应材料按原冻结规则生成损耗与责任记录，具体财务处理按实际案件审核。'),
                    const _Bullet('保留订货原量与实收事实；未满足客户需求的部分仍保留分析缺口，可以另行补单。'),
                    const _Bullet('记录短交数量与比例，是否承担责任按案件判定；供料损耗上限不自动免除成品交付义务。'),
                    const SizedBox(height: UtenSpacing.s12),
                    UtenInput(
                      key: const Key('short-delivery-accept-note'),
                      label: noteRequired ? '说明(必填)' : '说明(选填)',
                      hint: noteRequired
                          ? '未达到最少应到数量，请说明接受短交的原因'
                          : '例如：委外商确认损耗',
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
                        note: note.text.trim().isEmpty
                            ? null
                            : note.text.trim(),
                      ))
                    : null,
                onDisabledTap: () =>
                    ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
                      const SnackBar(content: Text('未达到最少应到数量的结案必须填写说明')),
                    ),
                child: const Text('确认接受损耗并结案'),
              ),
            ],
          );
        },
      ),
    );
  } finally {
    note.dispose();
  }
}

class _CaseSummary extends StatelessWidget {
  const _CaseSummary({required this.row});

  final SubcontractShortDeliveryCase row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unit = row.unitName;
    final floor = row.floorQtyValue;
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
            '订 ${formatSubcontractQty(row.orderedQtyValue, unit)}'
            '，允许损耗 ${formatSubcontractPct(row.allowedLossPctValue)}'
            '${floor == null ? '' : '(最少应到 ${formatSubcontractQty(floor, unit)})'}',
          ),
          Text(
            '累计回厂 ${formatSubcontractQty(row.deliveredQtyValue, unit)}'
            '，少 ${formatSubcontractQty(row.shortfallQtyValue, unit)}'
            '(${formatSubcontractPct(row.shortfallPctValue)})'
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
