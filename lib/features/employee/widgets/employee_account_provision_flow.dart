// 员工账号补开公共流程：员工详情与管理端账号候选选择器共同复用。
//
// 账号写入、一次性凭据展示都由 employee feature 持有；调用方只提供明确
// 选中的员工身份，避免 employee 反向依赖 admin 的页面实现。
//
// 2026-10-05 证件问题不阻塞开号：确认弹窗一打开先读就绪检查
// (GET /org/employees/{id}/account/readiness)。没有手机号 → 红色提醒 + 确认置灰
// (服务端照样兜底拦)；证件号码有问题 → 红/黄提醒，确认照常可点；就绪检查失败 →
// 不额外提醒，照常可确认，以服务端最终结果为准。三个开号入口都走这里，调用参数不变。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/account_action_owner.dart';
import '../../../shared/auth/account_write_receipt.dart';
import '../../../core/network/api_exception.dart';
import '../repositories/employee_repository.dart';
import 'employee_credential_dialog.dart';
import 'employee_dialog_error_text.dart';
import 'employee_identity_issue_notice.dart';

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
  bool Function()? isCurrent,
  Listenable? ownerChanges,
  Future<void> Function()? onAccountMayHaveChanged,
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

  final owner = AccountActionOwner(
    ref,
    isCurrent: isCurrent,
    targetChanges: ownerChanges,
  );
  if (owner.boundary.identity == null ||
      owner.boundary.identity!.actorId != null ||
      owner.boundary.identity!.readOnly) {
    owner.dispose();
    return null;
  }
  var attempted = false;
  bool current() =>
      context.mounted &&
      owner.isCurrent &&
      ref.read(currentPermissionsProvider).contains(Perm.accountSupport);
  try {
    final result = await showDialog<EmployeeOnboardingResult>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _SelectedEmployeeProvisionDialog(
        repository: ref.read(employeeRepositoryProvider),
        employeeId: employeeId,
        employeeName: employeeName,
        employeeCode: employeeCode,
        isCurrent: current,
        ownerChanges: ownerChanges,
        onWriteStarted: () => attempted = true,
      ),
    );
    if (result == null || !current()) {
      if (attempted && current()) {
        await onAccountMayHaveChanged?.call();
      }
      return null;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!context.mounted || !current()) return null;
    await showEmployeeCredentialDialog(
      context,
      result,
      isCurrent: current,
      ownerChanges: ownerChanges,
    );
    return current() ? result : null;
  } finally {
    owner.dispose();
  }
}

class _SelectedEmployeeProvisionDialog extends ConsumerStatefulWidget {
  const _SelectedEmployeeProvisionDialog({
    required this.repository,
    required this.employeeId,
    required this.employeeName,
    required this.employeeCode,
    required this.isCurrent,
    required this.ownerChanges,
    required this.onWriteStarted,
  });

  final EmployeeRepository repository;
  final String employeeId;
  final String employeeName;
  final String? employeeCode;
  final bool Function() isCurrent;
  final Listenable? ownerChanges;
  final VoidCallback onWriteStarted;

  @override
  ConsumerState<_SelectedEmployeeProvisionDialog> createState() =>
      _SelectedEmployeeProvisionDialogState();
}

class _SelectedEmployeeProvisionDialogState
    extends ConsumerState<_SelectedEmployeeProvisionDialog> {
  bool _submitting = false;
  bool _invalidated = false;
  bool _unknownResponse = false;
  late final AccountActionOwner _operator;
  ModalRoute<EmployeeOnboardingResult>? _route;
  String? _error;

  /// 就绪检查进行中：确认按钮转圈，避免在提醒出来之前就点了确认。
  bool _checking = true;

  /// 就绪检查结果；读失败为 null(不提醒，照常可确认)。
  EmployeeAccountReadiness? _readiness;

  @override
  void initState() {
    super.initState();
    _operator = AccountActionOwner(
      ref,
      isCurrent: widget.isCurrent,
      targetChanges: widget.ownerChanges,
      onInvalidated: () {
        _ensureCurrent();
      },
    );
    _loadReadiness();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of<EmployeeOnboardingResult>(context);
    _ensureCurrent();
  }

  bool _ensureCurrent() {
    if (!mounted || _invalidated) return false;
    if (_operator.isCurrent) return true;
    setState(() {
      _invalidated = true;
      _error = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final route = _route;
      if (mounted && route != null && route.isActive) {
        route.navigator?.removeRoute(route);
      }
    });
    return false;
  }

  @override
  void dispose() {
    _operator.dispose();
    super.dispose();
  }

  Future<void> _loadReadiness() async {
    EmployeeAccountReadiness? readiness;
    try {
      readiness = await widget.repository.accountReadiness(widget.employeeId);
    } catch (_) {
      // 就绪检查只是提前提醒：读失败不拦开号，以服务端开号结果为准。
      readiness = null;
    }
    if (!mounted || !_ensureCurrent()) return;
    setState(() {
      _readiness = readiness;
      _checking = false;
    });
  }

  /// 没有手机号就开不了(登录账号就是手机号)。
  bool get _missingPhone => _readiness?.hasPhone == false;

  Future<void> _submit() async {
    if (_submitting ||
        _checking ||
        _missingPhone ||
        _unknownResponse ||
        !_ensureCurrent()) {
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    var succeeded = false;
    try {
      widget.onWriteStarted();
      final result = await widget.repository.provisionAccount(
        widget.employeeId,
      );
      if (!mounted || !_ensureCurrent()) return;
      if (result.employee.id != widget.employeeId ||
          !result.hasAccountCredentials) {
        throw const AccountWriteReceiptException();
      }
      succeeded = true;
      // 先清忙标志再 pop：遮罩的 OverlayEntry 只在宿主 dispose 时才移除, 而本弹窗要走完
      // 退场动画才 dispose; 不清的话外层紧接着推的一次性凭据弹窗会被它盖住、点不动。
      setState(() => _submitting = false);
      Navigator.of(context).pop(result);
    } catch (error) {
      if (!mounted || !_ensureCurrent()) return;
      // 服务端原话(如手机号已被其他账号使用)直接显示，不用笼统的「开通失败」。
      setState(() {
        _unknownResponse =
            error is AccountWriteReceiptException ||
            (error is ApiException &&
                (const {'NETWORK', 'NETWORK_TIMEOUT'}.contains(error.code) ||
                    (error.httpStatus ?? 0) >= 500));
        _error = _unknownResponse
            ? AppLocalizations.of(context).employeeAccountReceiptIncomplete
            : employeeDialogErrorText(
                error,
                AppLocalizations.of(context).accountProvisionFailed,
              );
      });
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
    final idIssue = _readiness?.idNumberIssue;
    final busy = _submitting || _checking;
    return PopScope<void>(
      canPop: !_submitting,
      child: UtenAlertDialog(
        key: const ValueKey('provision-selected-employee-dialog'),
        title: UtenDialogHeading(
          title: Text(l10n.accountProvisionConfirmTitle),
          icon: Icons.person_add_alt_1_rounded,
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 开户网络段的全屏加载遮罩（root Overlay 传送门，不占布局；
              // 成功后在 pop 之前就清掉标志，保证一次性凭据弹窗不被它盖住）。
              if (_submitting)
                UtenBusyOverlay(
                  title: l10n.accountProvisionConfirmTitle,
                  description: '正在创建登录账号，请勿重复提交或关闭弹窗。',
                ),
              Text('$identity\n${l10n.employeeProvisionConfirm}'),
              if (_missingPhone) ...[
                const SizedBox(height: UtenSpacing.s12),
                UtenInlineNotice(
                  key: const ValueKey('provision-selected-employee-no-phone'),
                  level: UtenInlineNoticeLevel.error,
                  message: l10n.accountProvisionMissingPhone,
                ),
              ],
              if (idIssue != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                EmployeeIdentityIssueNotice(
                  issue: idIssue,
                  where: EmployeeIdentityNoticeContext.provision,
                ),
              ],
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
            onPressed: busy || _missingPhone || _unknownResponse
                ? null
                : _submit,
            icon: busy
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
