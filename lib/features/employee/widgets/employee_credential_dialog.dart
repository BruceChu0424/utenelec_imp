// 账号凭据弹窗（共享）：入职成功 / 给存量员工补开登录账号 后，向 HR 一次性展示
// 登录账号（默认手机号）与一次性临时密码，强制确认（不可返回兜藏）。
// 抽自 employee_onboarding_page 的 _showOnboardingCredential，供入职页与员工详情页复用。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../repositories/employee_repository.dart';

/// 展示一次性账号凭据（登录账号 + 临时密码）。barrier 不可消失，必须点「我已安全保存」关闭。
Future<void> showEmployeeCredentialDialog(
  BuildContext context,
  EmployeeOnboardingResult result,
) {
  final l10n = AppLocalizations.of(context);
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.key_rounded),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(child: Text(l10n.employeeOnboardCredentialTitle)),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.employeeOnboardCredentialWarning),
              const SizedBox(height: UtenSpacing.s16),
              Text(
                l10n.employeeFieldCode,
                style: Theme.of(dialogContext).textTheme.labelMedium,
              ),
              SelectableText(result.employee.code),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                l10n.employeeOnboardAccountLabel,
                style: Theme.of(dialogContext).textTheme.labelMedium,
              ),
              SelectableText(result.loginAccount),
              const SizedBox(height: UtenSpacing.s12),
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
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  result.temporaryPassword,
                  textAlign: TextAlign.center,
                  style: Theme.of(dialogContext).textTheme.titleLarge?.copyWith(
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
              await Clipboard.setData(
                ClipboardData(text: result.temporaryPassword),
              );
              if (dialogContext.mounted) {
                dialogContext.appSuccess(
                  l10n.employeeOnboardTemporaryPasswordCopied,
                );
              }
            },
            icon: const Icon(Icons.copy_rounded),
            label: Text(l10n.employeeOnboardCopyTemporaryPassword),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.employeeOnboardCredentialSaved),
          ),
        ],
      ),
    ),
  );
}
