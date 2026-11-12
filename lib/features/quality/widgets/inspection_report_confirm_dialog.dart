// 检验报告「提交报告」的总结确认弹窗（2026-09-05）。
//
// 明细在办理页核对。确认只展示合计、提交后果和结论原因。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_confirmation_summary.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/theme/uten_tokens.dart';

/// 返回结论原因文本（可为空串）= 确认提交；null = 取消。
Future<String?> showInspectionReportConfirmDialog(
  BuildContext context, {
  required int lineCount,
  required String passTotalText,
  required String failTotalText,
  required bool requireReason,
  int fqcTaskCount = 0,
  bool atomicReport = false,
  String initialReason = '',
  ValueChanged<String>? onReasonChanged,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _InspectionReportConfirmDialog(
      lineCount: lineCount,
      passTotalText: passTotalText,
      failTotalText: failTotalText,
      fqcTaskCount: fqcTaskCount,
      requireReason: requireReason,
      atomicReport: atomicReport,
      initialReason: initialReason,
      onReasonChanged: onReasonChanged,
    ),
  );
}

class _InspectionReportConfirmDialog extends StatefulWidget {
  const _InspectionReportConfirmDialog({
    required this.lineCount,
    required this.passTotalText,
    required this.failTotalText,
    required this.fqcTaskCount,
    required this.requireReason,
    required this.atomicReport,
    required this.initialReason,
    this.onReasonChanged,
  });

  final int lineCount;
  final String passTotalText;
  final String failTotalText;
  final int fqcTaskCount;
  final bool requireReason;
  final bool atomicReport;
  final String initialReason;
  final ValueChanged<String>? onReasonChanged;

  @override
  State<_InspectionReportConfirmDialog> createState() =>
      _InspectionReportConfirmDialogState();
}

class _InspectionReportConfirmDialogState
    extends State<_InspectionReportConfirmDialog> {
  final _reason = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reason.text = widget.initialReason;
    _reason.addListener(() => widget.onReasonChanged?.call(_reason.text));
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasFail = widget.requireReason;
    return UtenAlertDialog(
      title: const Text('确认提交检验报告'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const UtenReviewerResponsibilityNotice(
              actionLabel: '提交检验报告',
              description: '系统将记录检验员、结论数量与时间。',
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenConfirmationSummary(
              key: const Key('inspection-report-confirm-total'),
              facts: [
                if (widget.lineCount > 0) ...[
                  UtenConfirmationFact(
                    label: '共',
                    value: '${widget.lineCount} 行明细',
                  ),
                  UtenConfirmationFact(
                    label: '合格',
                    value: widget.passTotalText,
                  ),
                  UtenConfirmationFact(
                    label: '不合格',
                    value: widget.failTotalText,
                  ),
                ],
                if (widget.fqcTaskCount > 0)
                  UtenConfirmationFact(
                    label: '自制产成品任务',
                    value: '${widget.fqcTaskCount} 项全部合格',
                  ),
              ],
              consequences: [
                '已上架的合格部分自动点收入库，其余合格部分交仓库入库。',
                if (hasFail) '不合格部分登记质量事实和待处理台账，不生成入库任务。',
              ],
            ),
            if (widget.atomicReport) ...[
              const SizedBox(height: UtenSpacing.s8),
              const UtenConfirmationSummary(
                key: Key('inspection-report-atomic-notice'),
                consequences: ['所选行一起提交。任一行失败，新决定全部回滚。已登记的原决定沿用已有结果。'],
              ),
            ],
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              controller: _reason,
              maxLines: 3,
              maxLength: 500,
              decoration: UtenInputDecoration(
                const InputDecoration(labelText: '结论原因（选填）'),
                info: hasFail
                    ? '请说明不合格原因，便于后续退货、返工或其它处置。'
                    : '可补充检验依据或需要仓库注意的事项。',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('inspection-report-confirm-cancel'),
          onPressed: () => Navigator.of(context).pop<String>(),
          child: const Text('取消'),
        ),
        UtenButton(
          key: const Key('inspection-report-confirm-submit'),
          onPressed: () {
            // 结论原因统一选填：空原因照常提交（空串=确认）。
            Navigator.of(context).pop(_reason.text.trim());
          },
          child: const Text('确认提交报告'),
        ),
      ],
    );
  }
}
