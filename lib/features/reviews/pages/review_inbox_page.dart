// V459 我的待审收件台：跨业务域待审事项的聚合导航页（独立新页，不与他页共用）。
// - section 可见性 = 后端按「部门（主/兼职）× 职责权限码」资格过滤；
// - 计数 = 我的未办结待审通知数（办结撤回自动联动，只计真实待办）；
// - 点「去处理」直达各域任务中心/审核页（域内权威数据与认领状态在那里）。
// 文档：docs/03-页面/待审收件台.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/theme/uten_tokens.dart';
import '../repositories/review_inbox_repository.dart';

class ReviewInboxPage extends ConsumerWidget {
  const ReviewInboxPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final sections = ref.watch(reviewInboxSummaryProvider);
    return Scaffold(
      appBar: const UtenAppBar(title: '我的待审收件台', showBackButton: true),
      body: UtenContentContainer(
        child: RefreshIndicator(
          onRefresh: () => ref.refresh(reviewInboxSummaryProvider.future),
          child: sections.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => ListView(
              children: [
                UtenEmpty.error(
                  message: '待审收件台加载失败：$error',
                  actionLabel: '重试',
                  onAction: () => ref.invalidate(reviewInboxSummaryProvider),
                ),
              ],
            ),
            data: (list) => ListView(
              padding: const EdgeInsets.only(
                top: UtenSpacing.s12,
                bottom: UtenSpacing.s24,
              ),
              children: [
                _IntroCard(theme: theme),
                const SizedBox(height: UtenSpacing.s12),
                if (list.isEmpty)
                  const UtenEmpty(
                    icon: Icons.task_alt_outlined,
                    message: '当前没有指派给你的待审职责域',
                  )
                else
                  for (final section in list)
                    Padding(
                      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                      child: _SectionCard(theme: theme, section: section),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: UtenRadius.lgAll,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.notifications_active_outlined,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Text(
              '汇总你所在职责域（部门主职或兼职 × 职责权限）的待审事项；'
              '新待办会实时弹卡提醒，办结后自动撤回。计数只含真实待办。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.theme, required this.section});

  final ThemeData theme;
  final ReviewInboxSection section;

  @override
  Widget build(BuildContext context) {
    final hasPending = section.pendingCount > 0;
    return UtenCard(
      onTap: section.route.isEmpty ? null : () => context.go(section.route),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s16,
          vertical: UtenSpacing.s12,
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: hasPending
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                section.icon,
                color: hasPending
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    section.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasPending ? '${section.pendingCount} 项待你处理' : '当前无待办',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            // 计数徽章：固定高度、宽度随数字变化（Badge 固定高标准），
            // 只挂真实待办（0 不渲染徽章）。
            if (hasPending)
              Container(
                height: UtenSpacing.s24,
                constraints: const BoxConstraints(minWidth: UtenSpacing.s24),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  section.pendingCount > 99 ? '99+' : '${section.pendingCount}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            const SizedBox(width: UtenSpacing.s4),
            Icon(
              Icons.chevron_right_rounded,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
