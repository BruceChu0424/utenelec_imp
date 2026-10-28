// 账号凭据弹窗（共享）：入职成功 / 给存量员工补开登录账号 后，向 HR 一次性展示
// 登录账号（默认手机号）与一次性临时密码，强制确认（不可返回兜藏）。
// 抽自 employee_onboarding_page 的 _showOnboardingCredential，供入职页与员工详情页复用。
// 返回的员工资料带证件问题(idNumberIssue)时，在临时密码上方加红/黄提醒：开号不受影响，
// 但初始密码可能和员工本人证件后六位对不上，要以弹窗显示的为准(入职时证件一定合规，不会出现)。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/account_action_owner.dart';
import '../repositories/employee_repository.dart';
import '../models/employee_id_number_issue.dart';
import 'employee_identity_issue_notice.dart';

/// 展示一次性账号凭据（登录账号 + 临时密码）。barrier 不可消失，必须点「我已安全保存」关闭。
Future<void> showEmployeeCredentialDialog(
  BuildContext context,
  EmployeeOnboardingResult result, {
  bool Function()? isCurrent,
  Listenable? ownerChanges,
}) {
  final password = result.temporaryPassword;
  final account = result.loginAccount;
  if (password == null || account == null || !result.hasAccountCredentials) {
    return Future.error(
      FormatException(
        AppLocalizations.of(context).employeeAccountReceiptIncomplete,
      ),
    );
  }
  return showAccountCredentialDialog(
    context,
    temporaryPassword: password,
    loginAccount: account,
    employeeName: result.employee.fullName,
    employeeCode: result.employee.code,
    idNumberIssue: result.employee.idNumberIssue,
    isCurrent: isCurrent,
    ownerChanges: ownerChanges,
  );
}

/// 账号支持共用一次性凭据展示；调用方提供真实凭据与持有者边界，不构造员工档案。
Future<void> showAccountCredentialDialog(
  BuildContext context, {
  required String temporaryPassword,
  required String loginAccount,
  String? title,
  String? employeeName,
  String? employeeCode,
  EmployeeIdNumberIssue? idNumberIssue,
  bool Function()? isCurrent,
  Listenable? ownerChanges,
}) {
  final l10n = AppLocalizations.of(context);
  final idIssue = idNumberIssue;
  final guardKey = GlobalKey<_CredentialOwnerGuardState>();
  bool current() {
    try {
      return guardKey.currentState?.ensureCurrent() ??
          (isCurrent?.call() ?? true);
    } catch (_) {
      return false;
    }
  }

  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _CredentialOwnerGuard(
      key: guardKey,
      isCurrent: isCurrent,
      ownerChanges: ownerChanges,
      child: PopScope(
        canPop: false,
        child: UtenAlertDialog(
          title: UtenDialogHeading(
            title: Text(
              title ?? l10n.employeeOnboardCredentialTitle,
              key: const ValueKey('account-credential-title'),
            ),
            icon: Icons.key_rounded,
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.employeeOnboardCredentialWarning),
                const SizedBox(height: UtenSpacing.s16),
                if (employeeName?.trim().isNotEmpty == true) ...[
                  Text(
                    employeeName!,
                    style: Theme.of(dialogContext).textTheme.titleSmall,
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                ],
                if (employeeCode?.trim().isNotEmpty == true) ...[
                  Text(
                    l10n.employeeFieldCode,
                    style: Theme.of(dialogContext).textTheme.labelMedium,
                  ),
                  SelectableText(employeeCode!),
                  const SizedBox(height: UtenSpacing.s12),
                ],
                Text(
                  l10n.employeeOnboardAccountLabel,
                  style: Theme.of(dialogContext).textTheme.labelMedium,
                ),
                SelectableText(loginAccount),
                const SizedBox(height: UtenSpacing.s12),
                if (idIssue != null) ...[
                  EmployeeIdentityIssueNotice(
                    issue: idIssue,
                    where: EmployeeIdentityNoticeContext.credential,
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                ],
                Text(
                  l10n.employeeOnboardTemporaryPasswordLabel,
                  style: Theme.of(dialogContext).textTheme.labelMedium,
                ),
                const SizedBox(height: UtenSpacing.s4),
                Container(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      dialogContext,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(UtenRadius.control),
                  ),
                  child: SelectableText(
                    temporaryPassword,
                    textAlign: TextAlign.center,
                    style: Theme.of(dialogContext).textTheme.titleLarge
                        ?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                  ),
                ),
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton.icon(
              onPressed: () async {
                if (!current()) return;
                await Clipboard.setData(ClipboardData(text: temporaryPassword));
                if (dialogContext.mounted && current()) {
                  dialogContext.appSuccess(
                    l10n.employeeOnboardTemporaryPasswordCopied,
                  );
                }
              },
              icon: const Icon(Icons.copy_rounded),
              label: Text(l10n.employeeOnboardCopyTemporaryPassword),
            ),
            FilledButton(
              onPressed: () {
                if (!current()) return;
                final route = ModalRoute.of(dialogContext);
                if (route?.isCurrent == true) {
                  Navigator.pop(dialogContext);
                } else if (route?.isActive == true) {
                  route!.navigator?.removeRoute(route);
                }
              },
              child: Text(l10n.employeeOnboardCredentialSaved),
            ),
          ],
        ),
      ),
    ),
  );
}

class _CredentialOwnerGuard extends ConsumerStatefulWidget {
  const _CredentialOwnerGuard({
    super.key,
    required this.isCurrent,
    required this.ownerChanges,
    required this.child,
  });
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;
  final Widget child;

  @override
  ConsumerState<_CredentialOwnerGuard> createState() =>
      _CredentialOwnerGuardState();
}

class _CredentialOwnerGuardState extends ConsumerState<_CredentialOwnerGuard> {
  late final AccountActionOwner _owner;
  ModalRoute<void>? _route;
  bool _invalidated = false;

  @override
  void initState() {
    super.initState();
    _owner = AccountActionOwner(
      ref,
      isCurrent: () => widget.isCurrent?.call() ?? true,
      targetChanges: widget.ownerChanges,
      onInvalidated: () => _invalidate(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of<void>(context);
  }

  @override
  void didUpdateWidget(covariant _CredentialOwnerGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ownerChanges != widget.ownerChanges) {
      _owner.watchTargetChanges(widget.ownerChanges);
    }
    ensureCurrent();
  }

  bool _valid() => !_invalidated && _owner.isCurrent;

  bool ensureCurrent() {
    if (!mounted || _invalidated) return false;
    if (_valid()) return true;
    _invalidate();
    return false;
  }

  void _invalidate({bool rebuilding = false}) {
    if (!mounted || _invalidated) return;
    _invalidated = true;
    if (!rebuilding) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final route = _route;
      if (route != null && route.isActive) route.navigator?.removeRoute(route);
    });
  }

  @override
  void dispose() {
    _owner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_valid()) {
      _invalidate(rebuilding: true);
      return const SizedBox.shrink();
    }
    return widget.child;
  }
}
