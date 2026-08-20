// 快递式全链路进度时间线（通用组件）。
//
// 视觉范式对齐快递物流追踪：最新进展永远在最上面并高亮（实心圆点 + 描边卡片 +
// 「最新」徽章），其下按时间倒序排列历史节点，底部是灰色虚位的未来阶段（PENDING）。
// 每个节点 = 阶段标题 + 责任人（如下单人：张三）+ 发生时间 + 补充说明 + 可选单据跳转。
//
// 数据约定见 shared/models/progress_timeline_event.dart：服务端已排好展示顺序，
// 本组件按数组顺序直接渲染。颜色/字号全部走主题 token，深浅色模式自适应。
import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../../shared/models/progress_timeline_event.dart';

/// 快递式进度时间线。
///
/// [events] 按展示顺序传入（最新在最上）；[onOpenDoc] 非空时，带单据锚点的
/// 节点单号渲染为可点链接（权限/路由判断由调用方处理）。
class UtenProgressTimeline extends StatelessWidget {
  const UtenProgressTimeline({
    super.key,
    required this.events,
    this.onOpenDoc,
    this.emptyText = '暂无进度记录',
  });

  final List<ProgressTimelineEvent> events;
  final void Function(ProgressTimelineEvent event)? onOpenDoc;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (events.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        child: Center(
          child: Text(
            emptyText,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < events.length; i++)
          _TimelineTile(
            event: events[i],
            isLatest: i == 0,
            isLast: i == events.length - 1,
            onOpenDoc: onOpenDoc,
          ),
      ],
    );
  }

  /// ISO 时间 → 本地「yyyy-MM-dd HH:mm」；解析失败原样返回。
  static String formatTime(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final t = parsed.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

class _TimelineTile extends StatelessWidget {
  const _TimelineTile({
    required this.event,
    required this.isLatest,
    required this.isLast,
    this.onOpenDoc,
  });

  final ProgressTimelineEvent event;
  final bool isLatest;
  final bool isLast;
  final void Function(ProgressTimelineEvent event)? onOpenDoc;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (dotColor, icon) = switch (event.state) {
      'DONE' => (UtenColors.deepGreen, Icons.check_rounded),
      'CURRENT' => (theme.colorScheme.tertiary, Icons.autorenew_rounded),
      'REJECTED' => (theme.colorScheme.error, Icons.close_rounded),
      _ => (theme.colorScheme.outlineVariant, Icons.circle_outlined),
    };
    final muted = event.isPending ? theme.colorScheme.onSurfaceVariant : null;
    final time = UtenProgressTimeline.formatTime(event.occurredAt);

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    event.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: muted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (event.operatorLabel != null)
                    _operatorChip(theme, muted: event.isPending),
                  if (isLatest) _latestBadge(theme),
                ],
              ),
            ),
            if (time.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: UtenSpacing.s8, top: 2),
                child: Text(
                  time,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
        if (event.detail != null && event.detail!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s4),
            child: Text(
              event.detail!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: event.isRejected
                    ? theme.colorScheme.error
                    : muted ?? theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (event.docNo != null && event.docNo!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s4),
            child: InkWell(
              onTap: onOpenDoc == null ? null : () => onOpenDoc!(event),
              child: Text(
                '单号 ${event.docNo}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: onOpenDoc == null
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.primary,
                  decoration: onOpenDoc == null
                      ? null
                      : TextDecoration.underline,
                ),
              ),
            ),
          ),
      ],
    );

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 左轨：状态圆点 + 连接线。
          SizedBox(
            width: 32,
            child: Column(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: event.isPending ? Colors.transparent : dotColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: dotColor, width: 2),
                  ),
                  child: Icon(
                    icon,
                    size: 14,
                    color: event.isPending
                        ? theme.colorScheme.onSurfaceVariant
                        : Colors.white,
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: event.isDone || event.isCurrent
                          ? UtenColors.deepGreen.withValues(alpha: 0.4)
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : UtenSpacing.s16),
              child: isLatest
                  ? Container(
                      padding: const EdgeInsets.all(UtenSpacing.s12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.06,
                        ),
                        borderRadius: BorderRadius.circular(UtenRadius.md),
                        border: Border.all(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.35,
                          ),
                        ),
                      ),
                      child: content,
                    )
                  : Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: content,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// 责任人徽章：「下单人：张三」。历史缺人显示「—」。
  Widget _operatorChip(ThemeData theme, {required bool muted}) {
    final color = muted
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${event.operatorLabel}：${event.operatorName ?? '—'}',
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _latestBadge(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '最新',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
