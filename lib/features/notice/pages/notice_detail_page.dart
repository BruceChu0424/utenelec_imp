// 通知详情页
// 详情页全断点套 UtenContentContainer.narrow（maxWidth 1120）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../dashboard/providers/dashboard_overview_provider.dart';
import '../models/notice.dart';
import '../providers/notice_providers.dart';

class NoticeDetailPage extends ConsumerWidget {
  const NoticeDetailPage({
    super.key,
    required this.noticeId,
    this.onBack,
    this.onActionNavigate,
  });

  final String noticeId;

  /// 返回键行为。为空时走 [UtenBackButton] 默认逻辑（go_router pop + 工作台兜底），
  /// 适用于独立路由 `/notice/:id`。当本页被 [showNoticeDetailDialog] 以 Dialog /
  /// BottomSheet 内嵌时，弹窗是 Navigator 的 Dialog/Sheet 路由，不在 go_router 栈内，
  /// go_router 的 pop/go 关不掉弹窗（表现为「点返回没反应」），需由弹窗传入
  /// `Navigator.pop` 来关闭自身。
  final VoidCallback? onBack;

  /// 「查看详情」跳转回调：弹窗内嵌态由 showNoticeDetailDialog 在弹窗外捕获
  /// router 后传入（先关弹窗再跳）；独立路由态为 null，本页用 GoRouter.of 跳。
  /// 抽成回调避免本页反向 import 路由配置（app_router）形成循环依赖。
  final void Function(String target)? onActionNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(noticeDetailProvider(noticeId));

    return Scaffold(
      appBar: UtenAppBar(
        title: '通知详情',
        leading: onBack == null ? null : UtenBackButton(onPressed: onBack),
        showBackButton: onBack == null,
      ),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => UtenEmpty.error(
          message: '加载失败：$e',
          onAction: () => ref.invalidate(noticeDetailProvider(noticeId)),
        ),
        data: (notice) {
          if (notice == null) return const UtenEmpty(message: '通知不存在');
          return _Content(
            notice: notice,
            onBack: onBack,
            onActionNavigate: onActionNavigate,
          );
        },
      ),
    );
  }
}

class _Content extends ConsumerWidget {
  const _Content({
    required this.notice,
    this.onBack,
    this.onActionNavigate,
  });
  final Notice notice;

  /// 弹窗内嵌时为关弹窗回调（Navigator.pop）；独立路由 `/notice/:id` 态为 null。
  /// 「查看详情」跳转前据此先关弹窗——否则 go_router 的 go 只换底层页面、
  /// 弹窗仍盖着，视觉上「点查看详情没反应」（同类坑见文档 §九、memory
  /// go-router-nested-navigator-dialog-pop）。
  final VoidCallback? onBack;

  /// 弹窗外捕获 router 的跳转回调（弹窗态）；null=独立路由态用 GoRouter.of。
  final void Function(String target)? onActionNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              if (notice.type.isWork) ...[
                const SizedBox(width: UtenSpacing.s8),
                const UtenStatusBadge(
                  label: '工作',
                  type: UtenStatusBadgeType.accent,
                  icon: Icons.work_outline_rounded,
                ),
              ],
              if (notice.kind == NoticeKind.todo) ...[
                const SizedBox(width: UtenSpacing.s8),
                UtenStatusBadge(
                  label: notice.taskCompleted ? '待办已完成' : '待办',
                  type: notice.taskCompleted
                      ? UtenStatusBadgeType.success
                      : UtenStatusBadgeType.warning,
                  icon: notice.taskCompleted
                      ? Icons.task_alt_rounded
                      : Icons.pending_actions_rounded,
                ),
              ],
              if (notice.priority.showBadge) ...[
                const SizedBox(width: UtenSpacing.s8),
                UtenStatusBadge(
                  label: notice.priority.label,
                  type: notice.priority == NoticePriority.urgent
                      ? UtenStatusBadgeType.danger
                      : UtenStatusBadgeType.warning,
                  icon: notice.priority == NoticePriority.urgent
                      ? Icons.priority_high_rounded
                      : Icons.error_rounded,
                ),
              ],
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
          Wrap(
            spacing: UtenSpacing.s16,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
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
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.schedule_rounded,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: UtenSpacing.s4),
                  Text(
                    _fmt(notice.publishedAt),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (notice.audienceSummary.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s8),
            Row(
              children: [
                Icon(
                  Icons.groups_2_outlined,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    notice.audienceCount == null
                        ? notice.audienceSummary
                        : '${notice.audienceSummary} · ${notice.audienceCount} 人',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (notice.kind == NoticeKind.todo && notice.dueAt != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            Row(
              children: [
                Icon(
                  Icons.event_outlined,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  '截止时间：${_fmt(notice.dueAt!)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
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
            const UtenSectionHeader(
              title: '附件',
              icon: Icons.attach_file_rounded,
            ),
            const SizedBox(height: UtenSpacing.s8),
            for (final f in notice.attachments) ...[
              _buildAttachment(theme, f),
              const SizedBox(height: UtenSpacing.s8),
            ],
          ],
          if (notice.kind == NoticeKind.todo || notice.actionRoute != null) ...[
            const SizedBox(height: UtenSpacing.s24),
            Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s8,
              children: [
                if (notice.kind == NoticeKind.todo && !notice.taskCompleted)
                  FilledButton.icon(
                    onPressed: () async {
                      try {
                        await completeNoticeTodo(ref, notice.id);
                        ref.invalidate(dashboardOverviewProvider);
                        if (context.mounted) {
                          context.appSuccess('待办已完成');
                        }
                      } catch (error) {
                        if (context.mounted) context.appApiError(error);
                      }
                    },
                    icon: const Icon(Icons.task_alt_rounded),
                    label: const Text('标记完成'),
                  ),
                // 非 TODO 但带 actionRoute 的系统通知（排产/发货等，问题 #12）：
                // 只给「查看详情」跳转，不给「标记完成」——完成态是 TODO 语义专属。
                if (notice.actionRoute != null)
                  OutlinedButton.icon(
                    onPressed: () => _goAction(context),
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: Text(
                      notice.kind == NoticeKind.todo ? '前往办理页面' : '查看详情',
                    ),
                  ),
              ],
            ),
            if (notice.taskCompletedAt != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '已于 ${_fmt(notice.taskCompletedAt!)} 完成',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
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

  /// 「查看详情」跳转：弹窗态走 onActionNavigate（由 dialog 在弹窗外捕获
  /// router 后关弹窗再跳，避免本页 import 路由配置形成循环依赖、也避开弹窗内
  /// GoRouterState.of 取不到的问题）；独立路由态用 GoRouter.of(context) 直接跳。
  /// returnTo 统一回通知列表（/notice），目标页返回键回通知列表。
  void _goAction(BuildContext context) {
    final route = notice.actionRoute!;
    final uri = Uri.parse(route);
    final params = Map<String, String>.from(uri.queryParameters)
      ..['returnTo'] = RouteName.notice;
    final target = uri.replace(queryParameters: params).toString();
    if (onActionNavigate != null) {
      onActionNavigate!(target);
    } else {
      GoRouter.of(context).go(target);
    }
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
    NoticeType.task => UtenStatusBadgeType.info,
    NoticeType.approval => UtenStatusBadgeType.accent,
    NoticeType.workflow => UtenStatusBadgeType.success,
  };

  String _fmt(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
