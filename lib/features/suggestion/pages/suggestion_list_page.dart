// 建议箱列表页（含广场 + 我的）
// 响应式：compact 下内容套 UtenContentContainer（medium+ 由 MainShell 统一收敛）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/suggestion.dart';
import '../providers/suggestion_providers.dart';

class SuggestionListPage extends ConsumerWidget {
  const SuggestionListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(suggestionListProvider);
    final scope = ref.watch(suggestionScopeProvider);

    Widget body = Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: () =>
                ref.read(suggestionListProvider.notifier).refresh(),
            child: list.when(
              loading: () => const UtenSkeletonList(itemCount: 6),
              error: (e, _) => UtenEmpty.error(
                message: '加载失败：$e',
                onAction: () => ref.invalidate(suggestionListProvider),
              ),
              data: (suggestions) {
                if (suggestions.isEmpty) {
                  return ListView(
                    children: [
                      const SizedBox(height: UtenSpacing.s48),
                      UtenEmpty(
                        icon: Icons.lightbulb_outline_rounded,
                        message: scope == SuggestionScope.mine
                            ? '您还没有提交过建议'
                            : '暂无建议',
                        description: '点右下角按钮提交一条建议吧',
                      ),
                      const SizedBox(height: UtenSpacing.s24),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: UtenSpacing.s40,
                        ),
                        child: UtenButton(
                          isExpanded: true,
                          icon: Icons.edit_rounded,
                          onPressed: () =>
                              context.go(RouteName.suggestionNew),
                          child: const Text('提交建议'),
                        ),
                      ),
                    ],
                  );
                }
                return SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(
                    top: UtenSpacing.s8,
                    bottom: 80, // 底部悬浮胶囊导航 / FAB 留白
                  ),
                  child: UtenResponsiveGrid(
                    itemCount: suggestions.length,
                    itemBuilder: (context, i, _) => _SuggestionCard(
                      suggestion: suggestions[i],
                      onTap: () => context
                          .push(RoutePath.suggestionDetail(suggestions[i].id)),
                      onLike: () =>
                          toggleSuggestionLike(ref, suggestions[i].id),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
    // compact 下页面自带宽度收敛；medium+ 由 MainShell 的容器统一处理
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: '建议箱',
        showBackButton: true,
        centerWidget: UtenSegmentedFilter<SuggestionScope>(
          selected: scope,
          onChanged: (v) =>
              ref.read(suggestionScopeProvider.notifier).state = v,
          segments: const [
            UtenSegment(value: SuggestionScope.square, label: '建议广场'),
            UtenSegment(value: SuggestionScope.mine, label: '我的建议'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go(RouteName.suggestionNew),
        backgroundColor: UtenColors.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.edit_rounded),
        label: const Text('提建议'),
      ),
      body: body,
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.suggestion,
    required this.onTap,
    required this.onLike,
  });
  final Suggestion suggestion;
  final VoidCallback onTap;
  final VoidCallback onLike;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return UtenCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 头部：类别 + 状态
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s8,
                  vertical: UtenSpacing.s4,
                ),
                decoration: BoxDecoration(
                  color: suggestion.category.color.withValues(alpha: 0.12),
                  borderRadius: UtenRadius.smAll,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(suggestion.category.icon,
                        size: 12, color: suggestion.category.color),
                    const SizedBox(width: UtenSpacing.s4),
                    Text(
                      suggestion.category.label,
                      style: TextStyle(
                        fontSize: 11,
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
                type: _statusBadgeType(suggestion.status),
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          // 标题
          Text(
            suggestion.title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: UtenSpacing.s4),
          // 摘要
          Text(
            suggestion.content,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: UtenSpacing.s12),
          const Divider(),
          const SizedBox(height: UtenSpacing.s12),
          // 底部：提交人 + 点赞
          Row(
            children: [
              Icon(
                Icons.account_circle_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: UtenSpacing.s4),
              Flexible(
                child: Text(
                  suggestion.displayName,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Text(
                _fmt(suggestion.submittedAt),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              if (suggestion.replies.isNotEmpty) ...[
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: UtenSpacing.s4),
                Text(
                  '${suggestion.replies.length}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: UtenSpacing.s12),
              ],
              InkWell(
                onTap: onLike,
                borderRadius: UtenRadius.lgAll,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        suggestion.likedByMe
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 14,
                        color: suggestion.likedByMe
                            ? UtenColors.error
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: UtenSpacing.s4),
                      Text(
                        '${suggestion.likes}',
                        style: TextStyle(
                          fontSize: 12,
                          color: suggestion.likedByMe
                              ? UtenColors.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  UtenStatusBadgeType _statusBadgeType(SuggestionStatus s) => switch (s) {
        SuggestionStatus.submitted => UtenStatusBadgeType.info,
        SuggestionStatus.reviewing => UtenStatusBadgeType.warning,
        SuggestionStatus.resolved => UtenStatusBadgeType.success,
        SuggestionStatus.rejected => UtenStatusBadgeType.danger,
      };

  String _fmt(DateTime d) {
    final now = DateTime.now();
    final diff = now.difference(d);
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${d.month}-${d.day.toString().padLeft(2, '0')}';
  }
}
