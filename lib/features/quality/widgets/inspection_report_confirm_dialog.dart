// 检验报告「提交报告」的总结确认弹窗（2026-09-05）。
//
// 仿计划部「下达采购/委外」的 MaterialSupplySubmitConfirmDialog 文案结构：
// 合计行（品种数 + 合格/不合格合计）→ 分项行（IQC 明细 / FQC 任务）→
// 结论原因（含不合格时必填）→ 可滚动明细清单 → 取消 / 确认提交报告。
// 只做最后一步确认，不承载任何业务校验（校验在页面与服务器）。
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/theme/uten_tokens.dart';

/// 总结弹窗的一行明细（展示用）：货品标签 + 合格量 + 不合格量。
class InspectionReportConfirmLine {
  const InspectionReportConfirmLine({
    required this.label,
    required this.passText,
    required this.failText,
    this.dim,
  });

  final String label;

  /// 合格数量展示文本（空串 = 不适用，如 FQC 全部合格行）。
  final String passText;

  /// 不合格数量展示文本。
  final String failText;

  /// 数量单位后缀（如「个」）；null = 不显示单位。
  final String? dim;
}

/// 返回结论原因文本（可为空串）= 确认提交；null = 取消。
Future<String?> showInspectionReportConfirmDialog(
  BuildContext context, {
  required int lineCount,
  required String passTotalText,
  required String failTotalText,
  required List<InspectionReportConfirmLine> lines,
  int fqcTaskCount = 0,
  bool requireReason = false,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _InspectionReportConfirmDialog(
      lineCount: lineCount,
      passTotalText: passTotalText,
      failTotalText: failTotalText,
      lines: lines,
      fqcTaskCount: fqcTaskCount,
      requireReason: requireReason,
    ),
  );
}

class _InspectionReportConfirmDialog extends StatefulWidget {
  const _InspectionReportConfirmDialog({
    required this.lineCount,
    required this.passTotalText,
    required this.failTotalText,
    required this.lines,
    required this.fqcTaskCount,
    required this.requireReason,
  });

  final int lineCount;
  final String passTotalText;
  final String failTotalText;
  final List<InspectionReportConfirmLine> lines;
  final int fqcTaskCount;
  final bool requireReason;

  @override
  State<_InspectionReportConfirmDialog> createState() =>
      _InspectionReportConfirmDialogState();
}

class _InspectionReportConfirmDialogState
    extends State<_InspectionReportConfirmDialog> {
  final _reason = TextEditingController();
  String? _reasonError;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasFail =
        widget.requireReason ||
        widget.lines.any(
          (line) => (double.tryParse(line.failText.trim()) ?? 0) > 0,
        );
    return AlertDialog(
      title: const Text('确认提交检验报告'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const UtenReviewerResponsibilityNotice(
                actionLabel: '提交检验报告',
                description:
                    '系统将记录检验员、结论数量与时间；合格部分转仓库待入库，'
                    '不合格部分记质量事实，均不直接增加库存。',
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '共 ${widget.lineCount} 行明细'
                '${widget.fqcTaskCount > 0 ? '、${widget.fqcTaskCount} 项自制产成品任务全部合格' : ''}，'
                '合格 ${widget.passTotalText}、不合格 ${widget.failTotalText}。',
                key: const Key('inspection-report-confirm-total'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (hasFail) ...[
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  '本批含不合格数量：提交后不合格部分仅记质量事实与待处理台账，'
                  '不会生成仓库入库任务。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                controller: _reason,
                onChanged: (_) {
                  if (_reasonError != null) setState(() => _reasonError = null);
                },
                maxLines: 3,
                maxLength: 500,
                decoration: UtenInputDecoration(
                  InputDecoration(
                    labelText: hasFail ? '结论原因(必填)' : '结论原因(选填)',
                    error: _reasonError == null
                        ? null
                        : UtenFieldMessage.error(_reasonError!),
                  ),
                  info: hasFail
                      ? '请说明不合格原因，便于后续退货、返工或其它处置。'
                      : '可补充检验依据或需要仓库注意的事项。',
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.lines.length,
                  itemBuilder: (context, index) {
                    final line = widget.lines[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              line.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s8),
                          Text(
                            line.passText.isEmpty
                                ? '全部合格'
                                : '合格 ${line.passText}'
                                      '${line.dim == null ? '' : ' ${line.dim}'}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          if (line.failText.isNotEmpty &&
                              line.failText.trim() != '0') ...[
                            const SizedBox(width: UtenSpacing.s8),
                            Text(
                              '不合格 ${line.failText}'
                              '${line.dim == null ? '' : ' ${line.dim}'}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
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
            final reason = _reason.text.trim();
            if (hasFail && reason.isEmpty) {
              setState(() => _reasonError = '结论原因必填');
              return;
            }
            Navigator.of(context).pop(reason);
          },
          child: const Text('确认提交报告'),
        ),
      ],
    );
  }
}
