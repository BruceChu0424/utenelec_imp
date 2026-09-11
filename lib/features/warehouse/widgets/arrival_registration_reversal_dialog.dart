// 产成品送检登记撤回原因弹窗（V548）：单张/批量登记页共用。
//
// 只收原因文本（2–500 字，trim 后提交）；能否撤回由服务端按「每条 FQC 仍待检、无决定/
// 放行/恢复授权」判定，本弹窗不做业务判断，也不猜测撤回后的库存或品质事实。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/theme/uten_tokens.dart';

Future<String?> showArrivalRegistrationReversalDialog(
  BuildContext context, {
  required String title,
  required String summary,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _ArrivalRegistrationReversalDialog(title: title, summary: summary),
  );
}

class _ArrivalRegistrationReversalDialog extends StatefulWidget {
  const _ArrivalRegistrationReversalDialog({
    required this.title,
    required this.summary,
  });

  final String title;
  final String summary;

  @override
  State<_ArrivalRegistrationReversalDialog> createState() =>
      _ArrivalRegistrationReversalDialogState();
}

class _ArrivalRegistrationReversalDialogState
    extends State<_ArrivalRegistrationReversalDialog> {
  final _reason = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _reason.text.trim();
    if (reason.length < 2) {
      setState(() => _error = '请填写至少 2 个字的撤回原因');
      return;
    }
    if (reason.length > 500) {
      setState(() => _error = '撤回原因不能超过 500 个字符');
      return;
    }
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.summary, style: theme.textTheme.bodyMedium),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              '撤回后本批次的品质待检任务取消，报工行重新回到仓库待登记送检；'
              '登记、库位快照与检查单明细保留为历史，不写库存、不改报工数量。'
              '品质已登记决定、已放行或已进入恢复链的批次不能撤回。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              key: const Key('production-finished-arrival-reverse-reason'),
              controller: _reason,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              maxLength: 500,
              inputFormatters: [LengthLimitingTextInputFormatter(500)],
              decoration: const UtenInputDecoration(
                InputDecoration(
                  labelText: '撤回原因',
                  hintText: '必填，如：仓库选错、实物未到、需重新分仓',
                  counterText: '',
                ),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s4),
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  key: const Key('production-finished-arrival-reverse-error'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          key: const Key('production-finished-arrival-reverse-confirm'),
          onPressed: _submit,
          icon: const Icon(Icons.undo_rounded),
          label: const Text('确认撤回登记'),
        ),
      ],
    );
  }
}
