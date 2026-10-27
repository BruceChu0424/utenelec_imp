// 人事详情页修改密码：确认后生成临时密码，在同一弹窗中一次性展示。
// 使用员工 ID 调账号支持端点；再认证由统一网络拦截器处理。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/account_action_owner.dart';
import '../models/employee_api_models.dart';
import '../repositories/employee_repository.dart';
import 'employee_dialog_error_text.dart';

Future<bool?> showEmployeeResetPasswordDialog(
  BuildContext context, {
  required EmployeeProfile employee,
  bool Function()? isCurrent,
  Listenable? ownerChanges,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _EmployeeResetPasswordDialog(
    employee: employee,
    isCurrent: isCurrent,
    ownerChanges: ownerChanges,
  ),
);

class _EmployeeResetPasswordDialog extends ConsumerStatefulWidget {
  const _EmployeeResetPasswordDialog({
    required this.employee,
    required this.isCurrent,
    required this.ownerChanges,
  });

  final EmployeeProfile employee;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;

  @override
  ConsumerState<_EmployeeResetPasswordDialog> createState() =>
      _EmployeeResetPasswordDialogState();
}

class _EmployeeResetPasswordDialogState
    extends ConsumerState<_EmployeeResetPasswordDialog> {
  bool _submitting = false;
  bool _invalidated = false;
  late final AccountActionOwner _owner;
  ModalRoute<bool>? _route;
  String? _temporaryPassword;
  String? _error;

  @override
  void initState() {
    super.initState();
    _owner = AccountActionOwner(
      ref,
      isCurrent: () => widget.isCurrent?.call() ?? true,
      targetChanges: widget.ownerChanges,
      onInvalidated: _invalidate,
    );
    // 普通 token/profile 刷新保留身份和纪元；退出、切换身份、重新登录或撤权
    // 都永久终止本次凭据展示，即使同一帧又恢复权限也不能接纳旧响应。
  }

  @override
  void dispose() {
    _owner.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of<bool>(context);
    _ensureCurrent();
  }

  bool _ensureCurrent() {
    if (!mounted || _invalidated) return false;
    if (_owner.boundary.identity != null &&
        _owner.boundary.identity!.actorId == null &&
        !_owner.boundary.identity!.readOnly &&
        _owner.isCurrent &&
        _owner.boundary.permissions.contains(Perm.accountSupport)) {
      return true;
    }
    _invalidate();
    return false;
  }

  void _invalidate() {
    if (!mounted || _invalidated) return;
    setState(() {
      _invalidated = true;
      _temporaryPassword = null;
      _error = null;
    });
    // 再认证可能仍覆盖在本弹窗上方，不能 pop 掉当前最上层的其他窗口。
    // 清空内容后移除自己的 route，返回 false，不把未知业务结果当作未执行而重试。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final route = _route;
      if (mounted && route != null && route.isActive) {
        route.navigator?.removeRoute(route, false);
      }
    });
  }

  Future<void> _copyPassword() async {
    if (!_ensureCurrent()) return;
    final password = _temporaryPassword;
    if (password == null) return;
    await Clipboard.setData(ClipboardData(text: password));
    if (!mounted) return;
    if (_ensureCurrent()) {
      context.appSuccess(
        AppLocalizations.of(context).employeeOnboardTemporaryPasswordCopied,
      );
    }
  }

  Future<void> _submit() async {
    if (_submitting || _temporaryPassword != null) return;
    if (!_ensureCurrent()) return;
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
      if (!_ensureCurrent()) return;
      setState(() => _temporaryPassword = password);
    } catch (error) {
      if (!_ensureCurrent()) return;
      setState(() => _error = employeeDialogErrorText(error, '修改密码失败，请稍后重试'));
    } finally {
      if (mounted && !_invalidated) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_invalidated) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final employee = widget.employee;
    final password = _temporaryPassword;
    return PopScope<bool>(
      canPop: !_submitting && password == null,
      child: UtenAlertDialog(
        key: const ValueKey('employee-reset-password-dialog'),
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
                  Text(l10n.employeeManualLockResetHint),
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
                    borderRadius: BorderRadius.circular(UtenRadius.control),
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
                  onPressed: _copyPassword,
                  icon: const Icon(Icons.copy_rounded),
                  label: Text(l10n.employeeOnboardCopyTemporaryPassword),
                ),
                FilledButton(
                  key: const ValueKey('employee-reset-password-saved'),
                  onPressed: () {
                    if (_ensureCurrent()) Navigator.of(context).pop(true);
                  },
                  child: const Text('我已安全保存'),
                ),
              ],
      ),
    );
  }
}
