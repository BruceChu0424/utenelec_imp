// 通知详情页
// 详情页全断点套 UtenContentContainer.narrow（maxWidth 1120）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
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

    // 详情页全断点窄版收敛（1120），避免宽屏正文被拉得过长
    return UtenContentContainer.narrow(
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
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
              const SizedBox(width: UtenSpacing.s8),
              const UtenStatusBadge(
                label: '置顶',
                type: UtenStatusBadgeType.warning,
              ),
            ],
          ],
        ),
        const SizedBox(height: UtenSpacing.s16),
        // 标题
        Text(
          notice.title,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
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
            const SizedBox(width: UtenSpacing.s8),
            Text(
              notice.publisher,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(width: UtenSpacing.s12),
            Text(
              _fmt(notice.publishedAt),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s24),
        // 正文
        UtenCard(
          child: SelectableText(
            notice.content,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
          ),
        ),
        // 附件
        if (notice.attachments.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s24),
          const UtenSectionHeader(title: '附件', icon: Icons.attach_file_rounded),
          const SizedBox(height: UtenSpacing.s8),
          for (final f in notice.attachments) ...[
            _buildAttachment(theme, f),
            const SizedBox(height: UtenSpacing.s8),
          ],
        ],
        const SizedBox(height: UtenSpacing.s16),
        // 已读信息
        if (notice.readAt != null)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s12,
              vertical: UtenSpacing.s8,
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: UtenRadius.mdAll,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.check_circle_outline_rounded,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: UtenSpacing.s8),
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
      ),
    );
  }

  Widget _buildAttachment(ThemeData theme, String filename) {
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: UtenColors.teal500.withValues(alpha: 0.12),
              borderRadius: UtenRadius.mdAll,
            ),
            child: const Icon(
              Icons.insert_drive_file_outlined,
              color: UtenColors.teal600,
              size: 18,
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
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
