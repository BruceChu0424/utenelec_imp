import 'package:flutter/material.dart';

import '../../../components/feedback/uten_center_alert.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/uten_notify.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/notice.dart';

enum ImportantNoticeDialogResult { close, primary, interrupted }

/// 业务重要事件的持久强提醒包装：顶部条负责“到达”，本弹窗负责“必须看见”。
///
/// 不允许遮罩、返回键或计时器关闭；调用方只会收到显式“关闭”或主操作结果。
Future<ImportantNoticeDialogResult> showImportantNoticeDialog(
  BuildContext context, {
  required Notice notice,
  Listenable? interruptSignal,
}) async {
  final result = await UtenNotify.alert(
    context,
    title: notice.title,
    content: _ImportantNoticeContent(notice: notice),
    level: notice.priority == NoticePriority.urgent
        ? UtenAlertLevel.urgent
        : UtenAlertLevel.important,
    cancelLabel: '关闭',
    confirmLabel: _primaryLabel(notice),
    barrierDismissible: false,
    blockSystemBack: true,
    interruptSignal: interruptSignal,
    icon: notice.type.icon,
    maxWidth: 520,
    maxHeight: 640,
  );
  return switch (result) {
    true => ImportantNoticeDialogResult.primary,
    false => ImportantNoticeDialogResult.close,
    null => ImportantNoticeDialogResult.interrupted,
  };
}

String _primaryLabel(Notice notice) => switch (notice.sourceEvent) {
  'SALES_ORDER_FINANCE_REJECTED' => '查看订单并修改',
  _ => notice.actionRoute == null ? '查看通知详情' : '查看并处理',
};

class _ImportantNoticeContent extends StatelessWidget {
  const _ImportantNoticeContent({required this.notice});

  final Notice notice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = notice.priority == NoticePriority.urgent
        ? UtenAlertLevel.urgent.accent
        : UtenAlertLevel.important.accent;
    final reason = _extractReason(notice.content);
    final impact = switch (notice.sourceEvent) {
      'SALES_ORDER_FINANCE_REJECTED' => '订单尚未通过财务确认，排产链路仍被阻断。修改后需要重新审核并提交财务。',
      _ => '请查看业务详情并及时处理；关闭提醒不会把通知标记为已读。',
    };

    return Semantics(
      container: true,
      liveRegion: true,
      label: '${notice.priority.label}业务通知：${notice.title}',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s8,
            children: [
              _MetaItem(
                icon: Icons.account_circle_outlined,
                label: notice.publisher.isEmpty ? '系统' : notice.publisher,
              ),
              _MetaItem(
                icon: Icons.schedule_rounded,
                label:
                    '通知时间 ${ChinaDateTime.formatDateTime(notice.publishedAt)}',
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          Text(
            notice.content,
            textAlign: TextAlign.start,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface,
              height: 1.6,
            ),
          ),
          if (reason != null) ...[
            const SizedBox(height: UtenSpacing.s16),
            _Callout(
              icon: Icons.report_gmailerrorred_rounded,
              title: '原因',
              message: reason,
              accent: accent,
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
          _Callout(
            icon: Icons.account_tree_outlined,
            title: '影响与下一步',
            message: impact,
            accent: accent,
          ),
        ],
      ),
    );
  }
}

class _MetaItem extends StatelessWidget {
  const _MetaItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 17, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: UtenSpacing.s4),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _Callout extends StatelessWidget {
  const _Callout({
    required this.icon,
    required this.title,
    required this.message,
    required this.accent,
  });

  final IconData icon;
  final String title;
  final String message;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: accent, size: 20),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String? _extractReason(String content) {
  for (final marker in const ['驳回原因：', '原因：']) {
    final start = content.indexOf(marker);
    if (start < 0) continue;
    final tail = content.substring(start + marker.length).trim();
    if (tail.isEmpty) return null;
    final end = tail.indexOf('。');
    final reason = (end < 0 ? tail : tail.substring(0, end)).trim();
    if (reason.isNotEmpty) return reason;
  }
  return null;
}
