// 统一「批量驳回原因」对话框（2026-09-10 从报销审批列表页私有 _BatchRejectDialog 升位）。
// 文档：docs/02-组件库/UtenBatchRejectDialog.md
//
// 用途：审批队列多选后「批量驳回(N)」——一次填写原因、逐单应用到所选全部单据。
// 内置 UtenReviewerResponsibilityNotice（驳回是正式审核事实，责任提示位于原因
// 输入框之上）；原因必填，空提交只显示字段错误、不关闭对话框。
//
// controller 由对话框自持、随路由卸载释放——关闭退出动画仍在重建 TextField，
// 外层提前 dispose 会触发 "used after being disposed" 断言。
import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../inputs/uten_field_message.dart';
import '../inputs/uten_input_decoration.dart';
import 'uten_reviewer_responsibility_notice.dart';

/// 弹出批量驳回原因对话框；返回非空原因文本，取消返回 null。
///
/// [count] 所选单据数（标题与说明文案用）；[actionLabel] 责任提示中的动作名
///（如「报销审批驳回」）；[subjectLabel] 单据名词（如「报销单」「修改申请」）。
Future<String?> showUtenBatchRejectDialog(
  BuildContext context, {
  required int count,
  required String actionLabel,
  String subjectLabel = '单据',
  String? title,
  String? description,
  String confirmLabel = '确认驳回',
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => UtenBatchRejectDialog(
      count: count,
      actionLabel: actionLabel,
      subjectLabel: subjectLabel,
      title: title,
      description: description,
      confirmLabel: confirmLabel,
    ),
  );
}

/// 批量驳回原因对话框本体（通常经 [showUtenBatchRejectDialog] 弹出）。
class UtenBatchRejectDialog extends StatefulWidget {
  const UtenBatchRejectDialog({
    super.key,
    required this.count,
    required this.actionLabel,
    this.subjectLabel = '单据',
    this.title,
    this.description,
    this.confirmLabel = '确认驳回',
  });

  /// 所选单据数。
  final int count;

  /// 责任提示中的动作名（UtenReviewerResponsibilityNotice.actionLabel）。
  final String actionLabel;

  /// 单据名词（默认「单据」）。
  final String subjectLabel;

  /// 标题（默认「批量驳回(N)」）。
  final String? title;

  /// 说明（默认「驳回原因将同步给 N 位申请人，请说明具体问题。」）。
  final String? description;

  /// 确认按钮文案。
  final String confirmLabel;

  @override
  State<UtenBatchRejectDialog> createState() => _UtenBatchRejectDialogState();
}

class _UtenBatchRejectDialogState extends State<UtenBatchRejectDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _validationError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _validationError = '请填写驳回原因');
      return;
    }
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.count;
    return AlertDialog(
      title: Text(widget.title ?? '批量驳回($count)'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UtenReviewerResponsibilityNotice(
              actionLabel: widget.actionLabel,
              description:
                  '确认后，系统将以此登录员工记录所选 $count 张${widget.subjectLabel}的驳回责任。',
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(widget.description ?? '驳回原因将同步给 $count 位申请人，请说明具体问题。'),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              key: const Key('uten-batch-reject-reason'),
              controller: _controller,
              autofocus: true,
              maxLines: 3,
              onChanged: (_) {
                if (_validationError != null) {
                  setState(() => _validationError = null);
                }
              },
              decoration: UtenInputDecoration(
                InputDecoration(
                  labelText: '驳回原因',
                  hintText: '必填，将应用到所选全部${widget.subjectLabel}',
                  error: utenFieldError(_validationError),
                ),
              ),
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('uten-batch-reject-confirm'),
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
