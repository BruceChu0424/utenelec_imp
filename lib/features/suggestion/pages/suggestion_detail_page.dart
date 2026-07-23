// 建议详情页

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../core/theme/uten_colors.dart';
import '../models/suggestion.dart';
import '../providers/suggestion_providers.dart';

class SuggestionDetailPage extends ConsumerWidget {
  const SuggestionDetailPage({super.key, required this.suggestionId});
  final String suggestionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(suggestionDetailProvider(suggestionId));

    return Scaffold(
      appBar: const UtenAppBar(showBackButton: true),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => UtenEmpty.error(
          message: '加载失败：$e',
          onAction: () => ref.invalidate(suggestionDetailProvider(suggestionId)),
        ),
        data: (s) {
          if (s == null) return const UtenEmpty(message: '建议不存在');
          return _Content(suggestion: s);
        },
      ),
    );
  }
}

class _Content extends ConsumerWidget {
  const _Content({required this.suggestion});
  final Suggestion suggestion;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 类别 + 状态
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: suggestion.category.color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          suggestion.category.icon,
                          size: 14,
                          color: suggestion.category.color,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          suggestion.category.label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: suggestion.category.color,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  UtenStatusBadge(
                    label: suggestion.status.label,
                    type: _statusBadge(suggestion.status),
                    size: UtenStatusBadgeSize.small,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // 标题
              Text(
                suggestion.title,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              // 提交人
              Row(
                children: [
                  Icon(
                    Icons.account_circle_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    suggestion.displayName,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _fmt(suggestion.submittedAt),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // 正文
              UtenCard(
                child: SelectableText(
                  suggestion.content,
                  style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
                ),
              ),

              // 回复
              if (suggestion.replies.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  '官方回复 (${suggestion.replies.length})',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                for (final reply in suggestion.replies) ...[
                  _ReplyCard(reply: reply),
                  const SizedBox(height: 10),
                ],
              ],

              const SizedBox(height: 16),
              // 点赞行
              Center(
                child: Material(
                  type: MaterialType.transparency,
                  borderRadius: BorderRadius.circular(24),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () =>
                        toggleSuggestionLike(ref, suggestion.id),
                    borderRadius: BorderRadius.circular(24),
                    child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: suggestion.likedByMe
                          ? UtenColors.error.withValues(alpha: 0.1)
                          : theme.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: suggestion.likedByMe
                            ? UtenColors.error
                            : theme.colorScheme.outlineVariant,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          suggestion.likedByMe
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          size: 18,
                          color: suggestion.likedByMe
                              ? UtenColors.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${suggestion.likes} 人赞同',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: suggestion.likedByMe
                                ? UtenColors.error
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            ],
          ),
        ),
      ],
    );
  }

  UtenStatusBadgeType _statusBadge(SuggestionStatus s) => switch (s) {
        SuggestionStatus.submitted => UtenStatusBadgeType.info,
        SuggestionStatus.reviewing => UtenStatusBadgeType.warning,
        SuggestionStatus.resolved => UtenStatusBadgeType.success,
        SuggestionStatus.rejected => UtenStatusBadgeType.danger,
      };

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class _ReplyCard extends StatelessWidget {
  const _ReplyCard({required this.reply});
  final SuggestionReply reply;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: UtenColors.teal500.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: const Border(
          left: BorderSide(color: UtenColors.teal500, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: UtenColors.teal600.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.verified_rounded,
                  size: 16,
                  color: UtenColors.teal600,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      reply.replier,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      _fmt(reply.repliedAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            reply.content,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
          ),
        ],
      ),
    );
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
