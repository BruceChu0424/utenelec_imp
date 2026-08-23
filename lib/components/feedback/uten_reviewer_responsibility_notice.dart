import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uten_tokens.dart';
import '../../shared/providers/session_provider.dart';

/// 审核动作前的责任提示。
///
/// 默认从当前登录会话读取员工姓名与工号；服务端仍以安全上下文中的 employeeId
/// 作为实际审核人与审计权威，页面不会把审核员身份写进请求体。
class UtenReviewerResponsibilityNotice extends ConsumerWidget {
  const UtenReviewerResponsibilityNotice({
    super.key,
    this.actionLabel = '审核',
    this.description,
    this.compact = false,
  });

  final String actionLabel;
  final String? description;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionProvider).user;
    final name = user?.name.trim() ?? '';
    final code = user?.code.trim() ?? '';
    final currentActor = name.isNotEmpty && code.isNotEmpty
        ? '$name（$code）'
        : name.isNotEmpty
        ? name
        : code.isNotEmpty
        ? code
        : '当前登录员工';
    final detail = description ?? '确认后，系统将以此登录员工记录$actionLabel责任。';
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Semantics(
      container: true,
      label: '审核员 $currentActor。$detail',
      child: Container(
        key: const Key('reviewer-responsibility-notice'),
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: compact ? UtenSpacing.s8 : UtenSpacing.s12,
        ),
        decoration: BoxDecoration(
          color: colors.errorContainer.withValues(alpha: 0.45),
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: colors.error.withValues(alpha: 0.55)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.gpp_maybe_outlined,
              size: compact ? UtenSpacing.s20 : UtenSpacing.s24,
              color: colors.error,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '审核员：$currentActor',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colors.error,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (!compact) ...[
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onErrorContainer,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 统一审核确认框：责任人红色提示始终位于业务影响说明上方。
Future<bool> showUtenReviewerConfirmDialog(
  BuildContext context, {
  required String message,
  String title = '确认审核',
  String confirmLabel = '确认审核',
  String actionLabel = '审核',
  String? responsibilityDescription,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UtenReviewerResponsibilityNotice(
              actionLabel: actionLabel,
              description: responsibilityDescription,
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(message),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed == true;
}
