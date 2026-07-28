// 通知列表页（卡片网格版）
// 响应式：compact 下内容套 UtenContentContainer（medium+ 由 MainShell 统一收敛）。
// 文档：docs/03-页面/通知列表页.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_paged_grid.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../components/buttons/click_guard.dart';
import '../models/notice.dart';
import '../providers/notice_arrival.dart';
import '../providers/notice_providers.dart';

class NoticeListPage extends ConsumerWidget {
  const NoticeListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(noticeListProvider);
    final filter = ref.watch(noticeFilterProvider);

    Widget body = Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s12,
            bottom: UtenSpacing.s8,
          ),
          child: UtenSegmentedFilter<NoticeFilter>(
            selected: filter,
            onChanged: (v) =>
                ref.read(noticeFilterProvider.notifier).state = v,
            segments: const [
              UtenSegment(value: NoticeFilter.all, label: '全部'),
              UtenSegment(value: NoticeFilter.unread, label: '未读'),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(
            right: UtenSpacing.s8,
            bottom: UtenSpacing.s4,
          ),
          child: Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 全链路演示：模拟收到一条新工作通知（任务/上游/审批轮换），
                // 入库 → 列表/角标刷新 → 按重要度弹出到达提醒。
                // 接真后端后由推送/WebSocket 触发 dispatchNoticeArrival。
                UtenActionButton(
                  type: UtenActionButtonType.secondary,
                  size: UtenActionButtonSize.small,
                  icon: Icons.sensors_rounded,
                  label: const Text('模拟新通知'),
                  onAction: () async {
                    final notice = await ref
                        .read(noticeRepositoryProvider)
                        .simulateIncoming();
                    ref.invalidate(noticeListProvider);
                    ref.invalidate(unreadNoticeCountProvider);
                    if (context.mounted) {
                      dispatchNoticeArrival(context, notice);
                    }
                  },
                ),
                const SizedBox(width: UtenSpacing.s8),
                UtenActionButton(
                  type: UtenActionButtonType.ghost,
                  size: UtenActionButtonSize.small,
                  label: const Text('全部已读'),
                  onAction: () async {
                    await markAllNoticeRead(ref);
                    if (context.mounted) {
                      context.appSuccess('全部已读');
                    }
                  },
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.read(noticeListProvider.notifier).refresh(),
            child: list.when(
              loading: () => const UtenSkeletonList(itemCount: 6),
              error: (e, _) => UtenEmpty.error(
                message: '加载失败：$e',
                onAction: () => ref.invalidate(noticeListProvider),
              ),
              data: (notices) {
                if (notices.isEmpty) {
                  return ListView(
                    children: const [
                      SizedBox(height: UtenSpacing.s48),
                      UtenEmpty(
                        icon: Icons.notifications_none_rounded,
                        message: '暂无通知',
                      ),
                    ],
                  );
                }
                return UtenPagedGrid(
                  // 通知是公司广播型累积数据（无时间窗/上限），客户端按页切片：
                  // Wrap 恒只构建当页 ~20 张卡片，避免一次性铺全部致卡顿。
                  // 数据真正海量（接真后端）时改服务端 page/size 真分页。
                  items: notices,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(
                    top: UtenSpacing.s16,
                    bottom: 96, // 底部悬浮胶囊导航留白
                  ),
                  itemBuilder: (context, i, _) => _NoticeCard(
                    notice: notices[i],
                    onTap: () {
                      if (!notices[i].isRead) {
                        markNoticeRead(ref, notices[i].id);
                      }
                      context.push(RoutePath.noticeDetail(notices[i].id));
                    },
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

    return Scaffold(body: body);
  }
}

/// 通知卡片（竖版）
class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.notice, required this.onTap});
  final Notice notice;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final priority = notice.priority;

    return UtenCard(
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 重要度强调条：重要=橙 / 紧急=红（一般无）
            if (priority.showBadge)
              Container(
                width: 4,
                decoration: BoxDecoration(
                  color: priority.color,
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(14),
                  ),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(UtenSpacing.s20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 第一行：类型徽章 + 工作标识 + 重要度 / 置顶 / 未读
                    Row(
                      children: [
                        _TypeBadge(notice: notice),
                        // 工作类通知（任务/审批/流程）附加「工作」标识——
                        // 这是工作平台，工作消息与公告广播要一眼可辨
                        if (notice.type.isWork) ...[
                          const SizedBox(width: UtenSpacing.s8),
                          const _WorkTag(),
                        ],
                        const Spacer(),
                        if (priority.showBadge)
                          Padding(
                            padding:
                                const EdgeInsets.only(right: UtenSpacing.s4),
                            child: _PriorityChip(priority: priority),
                          ),
                        if (notice.topPriority)
                          const Padding(
                            padding:
                                EdgeInsets.only(right: UtenSpacing.s4),
                            child: Icon(
                              Icons.push_pin_rounded,
                              size: 14,
                              color: UtenColors.warning,
                            ),
                          ),
                        if (!notice.isRead)
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: UtenColors.error,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    // 标题
                    Text(
                      notice.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    // 摘要
                    Text(
                      notice.content,
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
                    // 底部：发布人 + 时间
                    Row(
                      children: [
                        Icon(
                          notice.type.isWork
                              ? Icons.work_outline_rounded
                              : Icons.account_circle_rounded,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: UtenSpacing.s4),
                        Flexible(
                          child: Text(
                            notice.publisher,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: UtenSpacing.s8),
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
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(DateTime d) {
    final now = DateTime.now();
    final diff = now.difference(d);
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

/// 类型徽章（公告/制度/福利/系统/紧急/任务/审批/流程）
class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.notice});
  final Notice notice;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: notice.type.color.withValues(alpha: 0.12),
        borderRadius: UtenRadius.smAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(notice.type.icon, size: 12, color: notice.type.color),
          const SizedBox(width: UtenSpacing.s4),
          Text(
            notice.type.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: notice.type.color,
            ),
          ),
        ],
      ),
    );
  }
}

/// 工作标识：工作类通知（任务/审批/流程）专属，与公告广播一眼可辨
class _WorkTag extends StatelessWidget {
  const _WorkTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        borderRadius: UtenRadius.smAll,
        border: Border.all(
          color: UtenColors.teal600.withValues(alpha: 0.45),
        ),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.work_outline_rounded, size: 12, color: UtenColors.teal700),
          SizedBox(width: UtenSpacing.s4),
          Text(
            '工作',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: UtenColors.teal700,
            ),
          ),
        ],
      ),
    );
  }
}

/// 重要度徽章：重要=橙 / 紧急=红
class _PriorityChip extends StatelessWidget {
  const _PriorityChip({required this.priority});
  final NoticePriority priority;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: priority.color.withValues(alpha: 0.12),
        borderRadius: UtenRadius.smAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            priority == NoticePriority.urgent
                ? Icons.priority_high_rounded
                : Icons.error_rounded,
            size: 12,
            color: priority.color,
          ),
          const SizedBox(width: 2),
          Text(
            priority.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: priority.color,
            ),
          ),
        ],
      ),
    );
  }
}
