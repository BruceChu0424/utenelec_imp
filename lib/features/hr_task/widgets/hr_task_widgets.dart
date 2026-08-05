// HR 工作台共享组件：任务类型元数据、任务行（认领徽标 + 快捷操作）、转正办理对话框。
// 文案硬编码中文（与 rd_task 等运维页同惯例）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../employee/repositories/employee_repository.dart';
import '../models/hr_task_summary.dart';
import '../providers/hr_task_summary_provider.dart';
import '../repositories/hr_task_repository.dart';

/// 任务类型：决定子页面标题 / 图标 / 认领 taskType。
enum HrTaskType {
  confirm(
    taskType: 'confirm',
    title: '转正办理',
    icon: Icons.how_to_reg_outlined,
    emptyText: '近期没有待转正的员工',
  ),
  birthday(
    taskType: 'birthday',
    title: '生日关怀',
    icon: Icons.cake_outlined,
    emptyText: '近 30 天没有员工生日',
  ),
  anniversary(
    taskType: 'anniversary',
    title: '入职周年',
    icon: Icons.emoji_events_outlined,
    emptyText: '今天没有入职周年的员工',
  ),
  newhire(
    taskType: 'newhire',
    title: '新近入职',
    icon: Icons.person_add_alt_outlined,
    emptyText: '近 30 天没有新入职员工',
  );

  const HrTaskType({
    required this.taskType,
    required this.title,
    required this.icon,
    required this.emptyText,
  });

  final String taskType;
  final String title;
  final IconData icon;
  final String emptyText;

  static HrTaskType? fromTaskType(String? value) {
    for (final t in values) {
      if (t.taskType == value) return t;
    }
    return null;
  }
}

/// 从 summary 中取出某类型的全部条目（按 逾期→今日→临近 排序）。
List<HrTaskItem> hrTaskItemsOf(HrTaskSummary s, HrTaskType type) {
  return switch (type) {
    HrTaskType.confirm => [
      ...s.confirmOverdue,
      ...s.confirmToday,
      ...s.confirmUpcoming,
    ],
    HrTaskType.birthday => [...s.birthdayToday, ...s.birthdayUpcoming],
    HrTaskType.anniversary => s.anniversaryToday,
    HrTaskType.newhire => s.newHires,
  };
}

/// 条目状态 chip（逾期 / 今日 / N 天后 / 已满 N 年…）。
(String, Color, Color) hrTaskChipOf(
  BuildContext context,
  HrTaskType type,
  HrTaskItem it,
) {
  final cs = Theme.of(context).colorScheme;
  final danger = (cs.errorContainer, cs.onErrorContainer);
  final warning = (cs.tertiaryContainer, cs.onTertiaryContainer);
  final normal = (cs.surfaceContainerHighest, cs.onSurfaceVariant);
  final (label, colors) = switch (type) {
    HrTaskType.confirm =>
      it.date != null &&
              DateTime.tryParse(it.date!)?.isBefore(
                DateTime.now().subtract(const Duration(days: 1)),
              ) ==
          true
          ? ('逾期 ${it.days} 天', danger)
          : it.days == 0
          ? ('今日转正', warning)
          : ('${it.days} 天后', normal),
    HrTaskType.birthday =>
      it.days == 0 || (it.note != null && it.note!.contains('今日'))
          ? ('今日生日', warning)
          : ('${it.days} 天后', normal),
    HrTaskType.anniversary => ('满 ${it.days} 年', warning),
    HrTaskType.newhire =>
      it.days == 0
          ? ('今日入职', warning)
          : it.days <= 7
          ? ('入职 ${it.days} 天', warning)
          : ('入职 ${it.days} 天', normal),
  };
  return (label, colors.$1, colors.$2);
}

/// 任务行：名称 + 工号/部门/岗位 + 日期 + 状态 chip + 认领徽标 + 快捷操作。
class HrTaskTile extends ConsumerWidget {
  const HrTaskTile({
    super.key,
    required this.type,
    required this.item,
    this.compact = false,
  });

  final HrTaskType type;
  final HrTaskItem item;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final perms = ref.watch(currentPermissionsProvider);
    final canEdit = perms.contains(Perm.employeeEdit);
    final (chipLabel, chipBg, chipFg) = hrTaskChipOf(context, type, item);
    final subtitle = [
      item.code,
      ?item.deptName,
      ?item.positionName,
      ?item.date,
      ?item.note,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s8,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: InkWell(
              onTap: () => context.push('/employee/${item.employeeId}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          item.name,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      _Chip(label: chipLabel, bg: chipBg, fg: chipFg),
                      if (item.claimedByName != null) ...[
                        const SizedBox(width: UtenSpacing.s4),
                        _Chip(
                          label: '${item.claimedByName} 处理中',
                          bg: theme.colorScheme.primaryContainer,
                          fg: theme.colorScheme.onPrimaryContainer,
                          icon: Icons.person_pin_outlined,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          _actions(context, ref, canEdit),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context, WidgetRef ref, bool canEdit) {
    final blocked = item.claimedByOther;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 认领 / 释放 / 接管
        if (item.claimedByName == null)
          IconButton(
            tooltip: '认领（标记为我在处理）',
            icon: const Icon(Icons.person_add_alt_1_outlined, size: 20),
            onPressed: () => _run(context, ref, () async {
              await ref
                  .read(hrTaskRepositoryProvider)
                  .claim(type.taskType, item.employeeId);
              return '已认领，其他同事将看到你正在处理';
            }),
          )
        else if (item.claimedByMe)
          IconButton(
            tooltip: '释放（不再由我处理）',
            icon: const Icon(Icons.person_remove_outlined, size: 20),
            onPressed: () => _run(context, ref, () async {
              await ref
                  .read(hrTaskRepositoryProvider)
                  .release(type.taskType, item.employeeId);
              return '已释放';
            }),
          )
        else if (canEdit)
          IconButton(
            tooltip: '接管（转由我处理）',
            icon: const Icon(Icons.swap_horizontal_circle_outlined, size: 20),
            onPressed: () => _run(context, ref, () async {
              await ref
                  .read(hrTaskRepositoryProvider)
                  .takeover(type.taskType, item.employeeId);
              return '已接管，现在由你处理';
            }),
          ),
        // 转正快捷操作（仅转正办理类型 + 有编辑权限）
        if (type == HrTaskType.confirm && canEdit)
          FilledButton.tonalIcon(
            icon: const Icon(Icons.how_to_reg_outlined, size: 18),
            label: const Text('登记转正'),
            onPressed: blocked
                ? null // 他人处理中：禁用，防重复操作
                : () => showHrConfirmDialog(context, ref, item),
          ),
        if (blocked && type == HrTaskType.confirm && !canEdit)
          Tooltip(
            message: '${item.claimedByName} 正在处理该事项',
            child: const Icon(Icons.lock_outline_rounded, size: 18),
          ),
      ],
    );
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<String> Function() action,
  ) async {
    try {
      final msg = await action();
      if (!context.mounted) return;
      context.appSuccess(msg);
    } on ApiException catch (e) {
      if (!context.mounted) return;
      context.appApiError(e);
    } finally {
      // 操作后静默重取（无论成败，确保认领状态与最新一致）
      await ref.read(hrTaskSummaryProvider.notifier).reloadSilently();
    }
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.bg,
    required this.fg,
    this.icon,
  });

  final String label;
  final Color bg;
  final Color fg;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 登记转正对话框：日期（默认今天）→ 试用期员工办理转正；已是正式员工的自动改为补登转正日期。
Future<void> showHrConfirmDialog(
  BuildContext context,
  WidgetRef ref,
  HrTaskItem item,
) async {
  final today = DateTime.now();
  DateTime selected = today;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text('登记转正 · ${item.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('选择实际转正日期（默认为今天）。试用期员工将转为在职；'
                '已是正式员工的将补登转正日期。'),
            const SizedBox(height: UtenSpacing.s12),
            OutlinedButton.icon(
              icon: const Icon(Icons.event_outlined, size: 18),
              label: Text(
                '${selected.year}-${selected.month.toString().padLeft(2, '0')}'
                '-${selected.day.toString().padLeft(2, '0')}',
              ),
              onPressed: () async {
                final picked = await showDatePicker(
                  context: ctx,
                  initialDate: selected,
                  firstDate: DateTime(2000),
                  lastDate: today,
                  locale: const Locale('zh'),
                );
                if (picked != null) setState(() => selected = picked);
              },
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;

  final date =
      '${selected.year}-${selected.month.toString().padLeft(2, '0')}'
      '-${selected.day.toString().padLeft(2, '0')}';
  final repo = ref.read(employeeRepositoryProvider);
  try {
    try {
      await repo.confirm(item.employeeId, confirmedDate: date);
    } on ApiException catch (e) {
      if (e.code == 'CONFLICT') {
        // 非试用期（已是正式员工但未登记转正日期）→ 补登
        await repo.update(item.employeeId, {'confirmedAt': date});
      } else {
        rethrow;
      }
    }
    if (!context.mounted) return;
    context.appSuccess('已登记 ${item.name} 的转正日期 $date');
  } on ApiException catch (e) {
    if (!context.mounted) return;
    context.appApiError(e);
  } finally {
    await ref.read(hrTaskSummaryProvider.notifier).reloadSilently();
  }
}
