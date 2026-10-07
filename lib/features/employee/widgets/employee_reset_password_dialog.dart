// 人事详情页修改密码：确认后生成临时密码，在同一弹窗中一次性展示。
// 使用员工 ID 调账号支持端点；再认证由统一网络拦截器处理。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../models/employee_api_models.dart';
import '../repositories/employee_repository.dart';
import 'employee_dialog_error_text.dart';

Future<bool?> showEmployeeResetPasswordDialog(
  BuildContext context, {
  required EmployeeProfile employee,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _EmployeeResetPasswordDialog(employee: employee),
);

class _EmployeeResetPasswordDialog extends ConsumerStatefulWidget {
  const _EmployeeResetPasswordDialog({required this.employee});

  final EmployeeProfile employee;

  @override
  ConsumerState<_EmployeeResetPasswordDialog> createState() =>
      _EmployeeResetPasswordDialogState();
}

class _EmployeeResetPasswordDialogState
    extends ConsumerState<_EmployeeResetPasswordDialog> {
  bool _submitting = false;
  String? _temporaryPassword;
  String? _error;

  Future<void> _submit() async {
    if (_submitting || _temporaryPassword != null) return;
    if (!ref.read(currentPermissionsProvider).contains(Perm.accountSupport)) {
      setState(() => _error = '没有账号支持权限，无法修改员工密码');
      return;
    }
    if (widget.employee.status == 'resigned' ||
        !const ['active', 'locked'].contains(widget.employee.accountStatus)) {
      setState(() => _error = '该员工账号当前不能修改密码，请刷新员工资料');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final password = await ref
          .read(employeeRepositoryProvider)
          .resetPassword(widget.employee.id);
      if (!mounted) return;
      setState(() => _temporaryPassword = password);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = employeeDialogErrorText(error, '修改密码失败，请稍后重试'));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final employee = widget.employee;
    final password = _temporaryPassword;
    return PopScope<bool>(
      canPop: !_submitting && password == null,
      child: AlertDialog(
        key: const ValueKey('employee-reset-password-dialog'),
        scrollable: true,
        title: Text(password == null ? '修改密码' : '一次性临时密码'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${employee.fullName ?? '未命名员工'}（${employee.code}）'),
              const SizedBox(height: UtenSpacing.s12),
              if (password == null) ...[
                const Text(
                  '系统将生成新的临时密码，原密码立即失效，所有已登录设备会退出。'
                  '员工使用临时密码登录后，必须设置自己的新密码。',
                ),
                if (employee.accountStatus == 'locked') ...[
                  const SizedBox(height: UtenSpacing.s12),
                  const Text('修改后该账号会解除锁定。'),
                ],
                const SizedBox(height: UtenSpacing.s12),
                const Text('确认后需要验证你本人的登录密码。'),
              ] else ...[
                const Text(
                  '请将以下临时密码交给员工。密码只显示这一次，关闭后无法再次查看。'
                  '临时密码限时有效（默认 72 小时，以系统设置为准），首次登录必须修改。',
                ),
                const SizedBox(height: UtenSpacing.s16),
                Container(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SelectableText(
                    password,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: password == null
            ? [
                TextButton(
                  key: const ValueKey('employee-reset-password-cancel'),
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: Text(l10n.commonCancel),
                ),
                FilledButton.icon(
                  key: const ValueKey('employee-reset-password-confirm'),
                  onPressed: _submitting ? null : _submit,
                  icon: _submitting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.key_outlined, size: 18),
                  label: Text(_submitting ? '正在生成…' : '生成临时密码'),
                ),
              ]
            : [
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: password));
                    if (context.mounted) {
                      context.appSuccess(
                        l10n.employeeOnboardTemporaryPasswordCopied,
                      );
                    }
                  },
                  icon: const Icon(Icons.copy_rounded),
                  label: Text(l10n.employeeOnboardCopyTemporaryPassword),
                ),
                FilledButton(
                  key: const ValueKey('employee-reset-password-saved'),
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('我已安全保存'),
                ),
              ],
      ),
    );
  }
}
