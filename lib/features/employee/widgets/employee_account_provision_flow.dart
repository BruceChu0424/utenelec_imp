// 员工账号补开公共流程：员工详情与管理端账号候选选择器共同复用。
//
// 账号写入、一次性凭据展示都由 employee feature 持有；调用方只提供明确
// 选中的员工身份，避免 employee 反向依赖 admin 的页面实现。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../repositories/employee_repository.dart';
import 'employee_credential_dialog.dart';

/// 为已经明确选中的未开户员工执行完整开户流程。
///
/// 只有当前操作者明确拥有 `account:support` 才会触发仓储调用；领导身份不会
/// 隐式获得该能力。确认弹窗在请求期间保持打开并禁用操作，收到成功回执后先
/// 强制展示一次性凭据，调用方只能在凭据确认保存后继续刷新或导航。
Future<EmployeeOnboardingResult?> showProvisionSelectedEmployeeAccountFlow(
  BuildContext context, {
  required WidgetRef ref,
  required String employeeId,
  required String employeeName,
  String? employeeCode,
  required bool hasAccount,
}) async {
  final l10n = AppLocalizations.of(context);
  if (!ref.read(currentPermissionsProvider).contains(Perm.accountSupport)) {
    context.appError(l10n.accountProvisionPermissionDenied);
    return null;
  }
  if (hasAccount) {
    context.appError(l10n.accountProvisionAlreadyExists);
    return null;
  }

  final result = await showDialog<EmployeeOnboardingResult>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _SelectedEmployeeProvisionDialog(
      repository: ref.read(employeeRepositoryProvider),
      employeeId: employeeId,
      employeeName: employeeName,
      employeeCode: employeeCode,
    ),
  );
  if (result == null || !context.mounted) return null;
  await showEmployeeCredentialDialog(context, result);
  return context.mounted ? result : null;
}

class _SelectedEmployeeProvisionDialog extends StatefulWidget {
  const _SelectedEmployeeProvisionDialog({
    required this.repository,
    required this.employeeId,
    required this.employeeName,
    required this.employeeCode,
  });

  final EmployeeRepository repository;
  final String employeeId;
  final String employeeName;
  final String? employeeCode;

  @override
  State<_SelectedEmployeeProvisionDialog> createState() =>
      _SelectedEmployeeProvisionDialogState();
}

class _SelectedEmployeeProvisionDialogState
    extends State<_SelectedEmployeeProvisionDialog> {
  bool _submitting = false;
  String? _error;

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    var succeeded = false;
    try {
      final result = await widget.repository.provisionAccount(
        widget.employeeId,
      );
      if (!mounted) return;
      succeeded = true;
      Navigator.of(context).pop(result);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message.isNotEmpty
            ? error.message
            : AppLocalizations.of(context).accountProvisionFailed;
      });
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _error = AppLocalizations.of(context).accountProvisionFailed,
      );
    } finally {
      if (mounted && !succeeded) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final code = widget.employeeCode?.trim() ?? '';
    final identity = code.isEmpty
        ? widget.employeeName
        : '${widget.employeeName}($code)';
    return PopScope<void>(
      canPop: !_submitting,
      child: AlertDialog(
        key: const ValueKey('provision-selected-employee-dialog'),
        title: Row(
          children: [
            const Icon(Icons.person_add_alt_1_rounded),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(child: Text(l10n.accountProvisionConfirmTitle)),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('$identity\n${l10n.employeeProvisionConfirm}'),
              if (_error != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
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
            key: const ValueKey('provision-selected-employee-cancel'),
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            child: Text(l10n.commonCancel),
          ),
          FilledButton.icon(
            key: const ValueKey('provision-selected-employee-confirm'),
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.person_add_outlined),
            label: Text(
              _submitting
                  ? l10n.accountProvisionInProgress
                  : l10n.employeeActionProvision,
            ),
          ),
        ],
      ),
    );
  }
}
