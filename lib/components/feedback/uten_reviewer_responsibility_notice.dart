import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uten_tokens.dart';
import '../../shared/providers/session_provider.dart';
import '../inputs/uten_field_hint_icon.dart';
import 'uten_confirmation_summary.dart';
import 'uten_dialog.dart';

/// 审核动作前的责任提示。
///
/// 默认从当前登录会话读取员工姓名与工号；服务端仍以安全上下文中的 employeeId
/// 作为实际审核人与审计权威，页面不会把审核员身份写进请求体。
class UtenReviewerResponsibilityNotice extends ConsumerWidget {
  const UtenReviewerResponsibilityNotice({
    super.key,
    this.actionLabel = '审核',
    this.reviewerLabel = '审核员',
    this.description,
    this.compact = false,
    this.inline = false,
  });

  final String actionLabel;
  final String reviewerLabel;
  final String? description;
  final bool compact;

  /// Both modes share the same identity and accessible inline disclosure.
  /// This mode omits the bordered notice surface for use beside a title.
  final bool inline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionProvider).user;
    final name = user?.name.trim() ?? '';
    final code = user?.code.trim() ?? '';
    final currentActor = name.isNotEmpty && code.isNotEmpty
        ? '$name($code)'
        : name.isNotEmpty
        ? name
        : code.isNotEmpty
        ? code
        : '当前登录员工';
    final detail = description ?? '确认后，系统将以此登录员工记录$actionLabel责任。';
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    Widget identity() => Row(
      key: const Key('reviewer-responsibility-notice'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (inline) const SizedBox(width: UtenSpacing.s8),
        Icon(
          Icons.gpp_maybe_outlined,
          size: inline || compact ? UtenSpacing.s20 : UtenSpacing.s24,
          color: colors.error,
        ),
        const SizedBox(width: UtenSpacing.s4),
        Flexible(
          child: Text(
            '$reviewerLabel：$currentActor',
            style: theme.textTheme.labelLarge?.copyWith(
              color: colors.error,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        UtenFieldHintIcon(info: detail, dense: true),
      ],
    );

    return Semantics(
      container: true,
      label: '$reviewerLabel $currentActor。$detail',
      child: inline
          ? identity()
          : Container(
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
              child: identity(),
            ),
    );
  }
}

/// 统一审核确认框：责任人红色提示始终位于业务影响说明上方。
Future<bool> showUtenReviewerConfirmDialog(
  BuildContext context, {
  String? message,
  UtenConfirmationSummary? summary,
  String title = '确认审核',
  String confirmLabel = '确认审核',
  String actionLabel = '审核',
  String? responsibilityDescription,
}) async {
  assert(message != null || summary != null);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => UtenAlertDialog(
      maxWidth: 480,
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
            ?summary,
            if (message != null && message.isNotEmpty) ...[
              if (summary != null) const SizedBox(height: UtenSpacing.s8),
              Text(message),
            ],
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
