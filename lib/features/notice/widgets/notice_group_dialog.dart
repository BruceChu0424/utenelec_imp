// 通知分组详情弹窗：点开叠放组后展示该业务对象的全部相关通知。
//
// 形态与通知详情弹窗一致：手机高位底部弹层、平板/桌面居中对话框。
// 组内排序 = 未读在前（各按发布时间倒序）；点单条 → 打开通知详情弹窗
// （叠在其上，关闭后回到本弹窗）；「全部已读」把组内未读一次清零。
// 弹窗持有本地已读集合：单条置读后立即生效，不必等列表刷新。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/responsive/breakpoint.dart';
import '../../../core/responsive/dialog_size.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/notice.dart';
import '../models/notice_group.dart';
import '../providers/notice_providers.dart';
import 'notice_detail_dialog.dart';

/// 打开通知分组弹窗。[originContext] 须来自路由栈内（通知列表页），
/// 供内层通知详情弹窗捕获 GoRouter（弹窗自身的 context 取不到）。
Future<void> showNoticeGroupDialog(
  BuildContext originContext, {
  required NoticeGroup group,
}) {
  if (originContext.breakpoint.isCompact) {
    return showModalBottomSheet<void>(
      context: originContext,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.82,
        child: _NoticeGroupPanel(group: group, originContext: originContext),
      ),
    );
  }
  return showDialog<void>(
    context: originContext,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: utenDialogInsetPadding(originContext),
      child: SizedBox(
        width: utenDialogWidth(originContext, 520),
        height: (MediaQuery.sizeOf(originContext).height * 0.6).clamp(
          420.0,
          640.0,
        ),
        child: _NoticeGroupPanel(group: group, originContext: originContext),
      ),
    ),
  );
}

class _NoticeGroupPanel extends StatefulWidget {
  const _NoticeGroupPanel({required this.group, required this.originContext});

  final NoticeGroup group;
  final BuildContext originContext;

  @override
  State<_NoticeGroupPanel> createState() => _NoticeGroupPanelState();
}

class _NoticeGroupPanelState extends State<_NoticeGroupPanel> {
  /// 本端已置读的通知 id（不等列表刷新，行级即时去红点）。
  final Set<String> _readIds = {};

  bool _markingAll = false;

  bool _isUnread(Notice n) => !n.isRead && !_readIds.contains(n.id);

  int get _unreadCount => widget.group.notices.where(_isUnread).length;

  Future<void> _openNotice(Notice notice) async {
    if (_isUnread(notice)) {
      setState(() => _readIds.add(notice.id));
      final container = ProviderScope.containerOf(
        widget.originContext,
        listen: false,
      );
      // 详情弹窗叠在本弹窗之上：originContext 在路由栈内且因本弹窗仍挂载。
      await markNoticeReadContainer(container, notice.id);
    }
    // 列表页被系统回收等极端情况下不再叠详情弹窗。
    if (!mounted || !widget.originContext.mounted) return;
    await showNoticeDetailDialog(widget.originContext, noticeId: notice.id);
  }

  Future<void> _markAllRead() async {
    final targets = widget.group.notices.where(_isUnread).toList();
    if (targets.isEmpty || _markingAll) return;
    setState(() => _markingAll = true);
    final container = ProviderScope.containerOf(
      widget.originContext,
      listen: false,
    );
    for (final notice in targets) {
      _readIds.add(notice.id);
      await markNoticeReadContainer(container, notice.id);
    }
    if (mounted) setState(() => _markingAll = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unread = _unreadCount;
    final notices = [...widget.group.notices]
      ..sort(
        (a, b) => _isUnread(a) == _isUnread(b)
            ? b.publishedAt.compareTo(a.publishedAt)
            : (_isUnread(a) ? -1 : 1),
      );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            UtenSpacing.s20,
            UtenSpacing.s12,
            UtenSpacing.s8,
            UtenSpacing.s4,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '相关通知',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s2),
                    Text(
                      '共 ${notices.length} 条'
                      '${unread > 0 ? ' · 未读 $unread 条' : ' · 全部已读'}'
                      '，未读排在前面',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (unread > 0)
                TextButton.icon(
                  onPressed: _markingAll ? null : _markAllRead,
                  icon: _markingAll
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.done_all_rounded, size: 18),
                  label: const Text('全部已读'),
                ),
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close_rounded),
                tooltip: '关闭',
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
            itemCount: notices.length,
            itemBuilder: (_, i) {
              final notice = notices[i];
              return _GroupNoticeRow(
                notice: notice,
                unread: _isUnread(notice),
                onTap: () => _openNotice(notice),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _GroupNoticeRow extends StatelessWidget {
  const _GroupNoticeRow({
    required this.notice,
    required this.unread,
    required this.onTap,
  });

  final Notice notice;
  final bool unread;
  final VoidCallback onTap;

  String _fmt(DateTime d) {
    final now = ChinaDateTime.now();
    final diff = now.difference(d);
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 已办结整体灰显，与列表卡片口径一致（保留审计价值，弱化视觉权重）。
    return Opacity(
      opacity: notice.isResolved ? 0.55 : 1.0,
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s20,
          vertical: UtenSpacing.s2,
        ),
        leading: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: notice.type.color.withValues(alpha: 0.12),
            borderRadius: UtenRadius.mdAll,
          ),
          child: Icon(notice.type.icon, size: 18, color: notice.type.color),
        ),
        title: Text(
          notice.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
        subtitle: Text(
          '${notice.publisher} · ${_fmt(notice.publishedAt)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: notice.isResolved
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '已办结',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            : (unread
                  ? const Icon(Icons.circle, size: 8, color: UtenColors.error)
                  : null),
      ),
    );
  }
}
