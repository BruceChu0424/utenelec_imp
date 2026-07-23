// 通知详情页

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../core/theme/uten_colors.dart';
import '../models/notice.dart';
import '../providers/notice_providers.dart';

class NoticeDetailPage extends ConsumerWidget {
  const NoticeDetailPage({super.key, required this.noticeId});
  final String noticeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(noticeDetailProvider(noticeId));

    return Scaffold(
      appBar: const UtenAppBar(title: '通知详情', showBackButton: true),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => UtenEmpty.error(
          message: '加载失败：$e',
          onAction: () => ref.invalidate(noticeDetailProvider(noticeId)),
        ),
        data: (notice) {
          if (notice == null) return const UtenEmpty(message: '通知不存在');
          return _Content(notice: notice);
        },
      ),
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({required this.notice});
  final Notice notice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 类型徽章
        Row(
          children: [
            UtenStatusBadge(
              label: notice.type.label,
              type: _typeToBadge(notice.type),
              icon: notice.type.icon,
            ),
            if (notice.topPriority) ...[
              const SizedBox(width: 8),
              const UtenStatusBadge(
                label: '置顶',
                type: UtenStatusBadgeType.warning,
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        // 标题
        Text(
          notice.title,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 12),
        // 发布信息
        Row(
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: notice.type.color.withValues(alpha: 0.15),
              child: Icon(
                Icons.account_circle_rounded,
                size: 20,
                color: notice.type.color,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              notice.publisher,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _fmt(notice.publishedAt),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        // 正文
        UtenCard(
          child: SelectableText(
            notice.content,
            style: theme.textTheme.bodyLarge?.copyWith(
              height: 1.7,
            ),
          ),
        ),
        // 附件
        if (notice.attachments.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            '附件',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          for (final f in notice.attachments) ...[
            _buildAttachment(theme, f),
            const SizedBox(height: 8),
          ],
        ],
        const SizedBox(height: 16),
        // 已读信息
        if (notice.readAt != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.check_circle_outline_rounded,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  '已于 ${_fmt(notice.readAt!)} 阅读',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildAttachment(ThemeData theme, String filename) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: UtenColors.teal500.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.insert_drive_file_outlined,
              color: UtenColors.teal600,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              filename,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Icon(
            Icons.download_outlined,
            color: theme.colorScheme.onSurfaceVariant,
            size: 20,
          ),
        ],
      ),
    );
  }

  UtenStatusBadgeType _typeToBadge(NoticeType t) => switch (t) {
        NoticeType.announcement => UtenStatusBadgeType.accent,
        NoticeType.policy => UtenStatusBadgeType.info,
        NoticeType.benefit => UtenStatusBadgeType.success,
        NoticeType.system => UtenStatusBadgeType.neutral,
        NoticeType.urgent => UtenStatusBadgeType.danger,
      };

  String _fmt(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
