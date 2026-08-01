// 通知列表页（卡片瀑布流版，支持多选删除）
// 响应式：compact 下内容套 UtenContentContainer（medium+ 由 MainShell 统一收敛）。
// 文档：docs/03-页面/通知列表页.md
//
// 多选删除：右上角「管理」进入选择模式（或长按卡片直接进入），
// 勾选多张卡片后底部操作条「删除」——从自己列表移除（他人不受影响）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_paged_grid.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../components/buttons/click_guard.dart';
import '../models/notice.dart';
import '../providers/notice_providers.dart';
import '../widgets/notice_detail_dialog.dart';

class NoticeListPage extends ConsumerStatefulWidget {
  const NoticeListPage({super.key});

  @override
  ConsumerState<NoticeListPage> createState() => _NoticeListPageState();
}

class _NoticeListPageState extends ConsumerState<NoticeListPage> {
  /// 是否处于多选管理模式
  bool _selecting = false;

  /// 已勾选的通知 id
  final Set<String> _selected = {};

  void _enterSelection([String? initialId]) {
    setState(() {
      _selecting = true;
      _selected.clear();
      if (initialId != null) _selected.add(initialId);
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.add(id)) _selected.remove(id);
    });
  }

  /// 批量删除：二次确认 → 调后端 → 刷新列表/角标
  Future<void> _deleteSelected() async {
    final count = _selected.length;
    if (count == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除通知'),
        content: Text('确定删除选中的 $count 条通知吗？删除后将从你的通知列表移除。'),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: UtenColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final deleted = await deleteNotices(ref, _selected.toList());
    if (!mounted) return;
    _exitSelection();
    context.appSuccess('已删除 $deleted 条通知');
  }

  @override
  Widget build(BuildContext context) {
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
            onChanged: (v) => ref.read(noticeFilterProvider.notifier).state = v,
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
                if (_selecting) ...[
                  UtenActionButton(
                    type: UtenActionButtonType.ghost,
                    size: UtenActionButtonSize.small,
                    label: const Text('全选'),
                    onAction: () async {
                      final notices = list.valueOrNull ?? const <Notice>[];
                      setState(() {
                        _selected
                          ..clear()
                          ..addAll(notices.map((n) => n.id));
                      });
                    },
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  UtenActionButton(
                    type: UtenActionButtonType.ghost,
                    size: UtenActionButtonSize.small,
                    label: const Text('退出管理'),
                    onAction: () async => _exitSelection(),
                  ),
                ] else ...[
                  UtenActionButton(
                    type: UtenActionButtonType.secondary,
                    size: UtenActionButtonSize.small,
                    icon: Icons.checklist_rounded,
                    label: const Text('管理'),
                    onAction: () async => _enterSelection(),
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
                  // 恒只构建当页 ~20 张卡片，避免一次性铺全部致卡顿。
                  // 数据真正海量时改服务端 page/size 真分页。
                  items: notices,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.only(
                    top: UtenSpacing.s16,
                    // 底部留白：悬浮胶囊导航 +（选择模式时）多选操作条
                    bottom: _selecting ? 160 : 96,
                  ),
                  itemBuilder: (context, i, _) {
                    final notice = notices[i];
                    final checked = _selected.contains(notice.id);
                    return _NoticeCard(
                      notice: notice,
                      selecting: _selecting,
                      checked: checked,
                      onLongPress: () {
                        if (!_selecting) _enterSelection(notice.id);
                      },
                      onTap: () async {
                        if (_selecting) {
                          _toggle(notice.id);
                          return;
                        }
                        if (!notice.isRead) {
                          markNoticeRead(ref, notice.id);
                        }
                        await showNoticeDetailDialog(
                          context,
                          noticeId: notice.id,
                        );
                        // 详情弹窗关闭后刷新列表：用户可能在详情里标记完成/已读，
                        // 列表与未读角标需同步，避免停留在旧状态。
                        ref.invalidate(noticeListProvider);
                      },
                    );
                  },
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
      body: body,
      // 多选操作条：选中数 + 删除按钮（选择模式才显示）
      bottomNavigationBar: _selecting
          ? SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s20,
                  vertical: UtenSpacing.s12,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      '已选 ${_selected.length} 条',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    // 未选中时视觉禁用（UtenActionButton 无 disabled 参数，
                    // 用 Opacity + IgnorePointer 包一层）
                    Opacity(
                      opacity: _selected.isEmpty ? 0.5 : 1,
                      child: IgnorePointer(
                        ignoring: _selected.isEmpty,
                        child: UtenActionButton(
                          icon: Icons.delete_outline_rounded,
                          label: const Text('删除'),
                          loadingLabel: const Text('删除中…'),
                          onAction: _deleteSelected,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}

/// 通知卡片（竖版；选择模式下显示勾选框）
class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.notice,
    required this.onTap,
    this.selecting = false,
    this.checked = false,
    this.onLongPress,
  });

  final Notice notice;
  final VoidCallback onTap;

  /// 是否处于多选管理模式（点击 = 切换勾选）
  final bool selecting;

  /// 当前是否已勾选
  final bool checked;

  /// 长按进入选择模式
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final priority = notice.priority;

    return Stack(
      children: [
        UtenCard(
          onTap: onTap,
          onLongPress: onLongPress,
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
                            if (notice.kind == NoticeKind.todo) ...[
                              const SizedBox(width: UtenSpacing.s8),
                              _TodoTag(completed: notice.taskCompleted),
                            ] else if (notice.type.isWork) ...[
                              const SizedBox(width: UtenSpacing.s8),
                              const _WorkTag(),
                            ],
                            const Spacer(),
                            if (priority.showBadge)
                              Padding(
                                padding: const EdgeInsets.only(
                                  right: UtenSpacing.s4,
                                ),
                                child: _PriorityChip(priority: priority),
                              ),
                            if (notice.topPriority)
                              const Padding(
                                padding: EdgeInsets.only(right: UtenSpacing.s4),
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
        ),
        // 选择模式：右上角勾选框 + 选中高亮描边
        if (selecting)
          Positioned(
            top: 10,
            right: 10,
            child: IgnorePointer(
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: checked
                      ? UtenColors.teal600
                      : theme.colorScheme.surface,
                  border: Border.all(
                    color: checked
                        ? UtenColors.teal600
                        : theme.colorScheme.outlineVariant,
                    width: 2,
                  ),
                ),
                child: checked
                    ? const Icon(
                        Icons.check_rounded,
                        size: 14,
                        color: Colors.white,
                      )
                    : null,
              ),
            ),
          ),
      ],
    );
  }

  String _fmt(DateTime d) {
    final now = ChinaDateTime.now();
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

class _TodoTag extends StatelessWidget {
  const _TodoTag({required this.completed});

  final bool completed;

  @override
  Widget build(BuildContext context) {
    final color = completed ? UtenColors.success : UtenColors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            completed ? Icons.task_alt_rounded : Icons.pending_actions_rounded,
            size: 12,
            color: color,
          ),
          const SizedBox(width: UtenSpacing.s4),
          Text(
            completed ? '已完成' : '待办',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
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
        border: Border.all(color: UtenColors.teal600.withValues(alpha: 0.45)),
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
