// HR 工作台共享组件：任务类型元数据、任务行（认领徽标 + 快捷操作）、转正办理对话框。
// 文案硬编码中文（与 rd_task 等运维页同惯例）。
// 2026-10-05 新增「证件核对」(identity)：证件号码缺失 / 校验未通过 / 尚未校验的在职员工，
// 只给能修改证件的人看(服务端已按权限过滤)，行操作「修改证件信息」；
// 具体原因在副标题下单独一行红字完整显示(key hr-task-identity-reason)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../employee/widgets/employee_identity_correction_dialog.dart';
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
  ),
  identity(
    taskType: 'identity',
    title: '证件核对',
    icon: Icons.fact_check_outlined,
    emptyText: '没有需要核对的证件信息',
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

  /// 有没有时间线(天数 / 逾期·今日·即将)：证件核对没有，表格不显示这两列。
  bool get hasTimeline => this != identity;

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
    HrTaskType.identity => s.identityReview,
  };
}

/// 能否在证件核对任务上「修改证件信息」：没被别人认领处理中即可。
///
/// 证件核对列表只下发给能修改证件的人(服务端按超管或 employee:pii:edit 过滤，
/// 其他人收到空列表)，页面本身也由路由守卫按 employee:pii:edit 把关，
/// 所以看得到条目就能改，这里不再本地拼权限。
bool hrTaskCanCorrectIdentity(HrTaskType type, HrTaskItem item) =>
    type == HrTaskType.identity && !item.claimedByOther;

/// 打开「修改证件信息」弹窗；保存成功后提示并静默重取(任务随之消失，徽标同步)。
Future<void> showHrIdentityCorrection(
  BuildContext context,
  WidgetRef ref,
  HrTaskItem item,
) async {
  final saved = await showEmployeeIdentityCorrectionDialog(
    context,
    ref: ref,
    employeeId: item.employeeId,
    employeeName: item.name,
  );
  if (!saved) return;
  if (context.mounted) context.appSuccess('${item.name} 的证件信息已更新');
  await ref.read(hrTaskSummaryProvider.notifier).reloadSilently();
}

/// 该条目是否为「今日」庆典——决定单行「送祝福」按钮是否显示。
/// 祝福只针对今日在册（与一键批量同口径）：生日列表把今日与未来 30 天合并展示，
/// 但只有今日（birthdayToday）者才显示送祝福按钮，未来临近者不显示；
/// 周年列表本就只有今日（anniversaryToday），恒为今日。
/// 注意：不能用 item.days==0 判断——今日生日的 days 存的是年龄（非 0），
/// 后端仅以 note=="今日生日" 与否区分，故这里直接用服务端已分好的列表为准。
bool hrTaskIsToday(HrTaskSummary s, HrTaskType type, HrTaskItem item) {
  return switch (type) {
    HrTaskType.birthday => s.birthdayToday.any(
      (i) => i.employeeId == item.employeeId,
    ),
    HrTaskType.anniversary => true,
    _ => false,
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
    // 「轮到人事办」一律红。具体原因(note，服务端原话)可能很长，在副标题下
    // 单独一行红字完整显示，徽标只放短标签，避免窄屏横向溢出。
    HrTaskType.identity => ('证件待核对', danger),
  };
  return (label, colors.$1, colors.$2);
}

/// 任务行可用宽度低于此值(手机竖屏)时，快捷操作按钮另起一行靠右，
/// 不与姓名/徽标并排(并排时 375 宽手机上左侧只剩约 80 宽，徽标溢出)。
const double _kHrTaskTileStackBelow = 440;

/// 任务行：名称 + 工号/部门/岗位 + 日期 + 状态 chip + 认领徽标 + 快捷操作。
class HrTaskTile extends ConsumerWidget {
  const HrTaskTile({
    super.key,
    required this.type,
    required this.item,
    this.compact = false,
    this.isToday = true,
  });

  final HrTaskType type;
  final HrTaskItem item;
  final bool compact;

  /// 是否「今日」庆典条目：仅今日才显示单行「送祝福」按钮（与一键批量同口径，
  /// 未来临近生日不显示）。默认 true 兼容不涉及祝福的场景；庆典列表须显式传入。
  final bool isToday;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final perms = ref.watch(currentPermissionsProvider);
    final canTakeover = perms.contains(Perm.employeeTaskTakeover);
    final canConfirm = perms.contains(Perm.employeeConfirm);
    final (chipLabel, chipBg, chipFg) = hrTaskChipOf(context, type, item);
    // 证件核对的具体原因(服务端原话)单独成行、红字、不截断：它就是人事要据此
    // 去改的依据，拼进灰色副标题会在窄屏被省略号截掉。其他类型的 note 照旧进副标题。
    final identityReason = type == HrTaskType.identity
        ? item.note?.trim()
        : null;
    final subtitle = [
      item.code,
      ?item.deptName,
      ?item.positionName,
      ?item.date,
      if (type != HrTaskType.identity) ?item.note,
    ].join(' · ');

    final reasonLine = identityReason == null || identityReason.isEmpty
        ? null
        : Text(
            identityReason,
            key: const ValueKey('hr-task-identity-reason'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
              fontWeight: FontWeight.w600,
            ),
            softWrap: true,
          );
    final info = _info(
      context,
      theme: theme,
      chipLabel: chipLabel,
      chipBg: chipBg,
      chipFg: chipFg,
      subtitle: subtitle,
    );
    final actions = _actions(context, ref, canTakeover, canConfirm, perms);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s8,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 手机竖屏：右侧按钮(认领 + 修改证件信息/登记转正)要占 200 多宽，
          // 并排会把姓名和徽标挤成一条窄缝甚至溢出，改为按钮另起一行靠右。
          if (constraints.maxWidth < _kHrTaskTileStackBelow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                info,
                if (reasonLine != null) ...[
                  const SizedBox(height: UtenSpacing.s4),
                  reasonLine,
                ],
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: info),
                  const SizedBox(width: UtenSpacing.s8),
                  actions,
                ],
              ),
              // 原因占整行宽，不与右侧按钮抢宽度。
              if (reasonLine != null) ...[
                const SizedBox(height: UtenSpacing.s4),
                reasonLine,
              ],
            ],
          );
        },
      ),
    );
  }

  /// 左侧信息块：姓名 + 状态徽标 + 认领徽标 + 灰色副标题(点按进档案)。
  Widget _info(
    BuildContext context, {
    required ThemeData theme,
    required String chipLabel,
    required Color chipBg,
    required Color chipFg,
    required String subtitle,
  }) {
    return InkWell(
      onTap: () => context.push('/employee/${item.employeeId}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 姓名 + 状态徽标 + 认领徽标：窄屏放不下时徽标换到下一行，不横向溢出。
          Wrap(
            spacing: UtenSpacing.s4,
            runSpacing: UtenSpacing.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: UtenSpacing.s4),
                child: Text(
                  item.name,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _Chip(label: chipLabel, bg: chipBg, fg: chipFg),
              if (item.claimedByName != null)
                _Chip(
                  label: '${item.claimedByName} 处理中',
                  bg: theme.colorScheme.primaryContainer,
                  fg: theme.colorScheme.onPrimaryContainer,
                  icon: Icons.person_pin_outlined,
                ),
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
    );
  }

  Widget _actions(
    BuildContext context,
    WidgetRef ref,
    bool canTakeover,
    bool canConfirm,
    Set<String> perms,
  ) {
    final theme = Theme.of(context);
    final blocked = item.claimedByOther;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 认领 / 释放 / 接管
        if (item.claimedByName == null)
          IconButton(
            tooltip: '认领(标记为我在处理)',
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
            tooltip: '释放(不再由我处理)',
            icon: const Icon(Icons.person_remove_outlined, size: 20),
            onPressed: () => _run(context, ref, () async {
              await ref
                  .read(hrTaskRepositoryProvider)
                  .release(type.taskType, item.employeeId);
              return '已释放';
            }),
          )
        else if (canTakeover)
          IconButton(
            tooltip: '接管(转由我处理)',
            icon: const Icon(Icons.swap_horizontal_circle_outlined, size: 20),
            onPressed: () => _run(context, ref, () async {
              await ref
                  .read(hrTaskRepositoryProvider)
                  .takeover(type.taskType, item.employeeId);
              return '已接管，现在由你处理';
            }),
          ),
        // 转正快捷操作（仅转正办理类型 + 有编辑权限）
        if (type == HrTaskType.confirm && canConfirm)
          FilledButton.tonalIcon(
            icon: const Icon(Icons.how_to_reg_outlined, size: 18),
            label: const Text('登记转正'),
            onPressed: blocked
                ? null // 他人处理中：禁用，防重复操作
                : () => showHrConfirmDialog(context, ref, item),
          ),
        // 证件核对：修改证件信息(employee:pii:edit；他人处理中不显示)
        if (hrTaskCanCorrectIdentity(type, item))
          FilledButton.tonalIcon(
            icon: const Icon(Icons.edit_note_rounded, size: 18),
            label: const Text('修改证件信息'),
            onPressed: () => showHrIdentityCorrection(context, ref, item),
          ),
        // 庆典祝福（仅今日 + 生日/周年 + 有发布权限）：未祝福可单行送祝福，已祝福标记。
        // 未来临近生日不显示送祝福（与一键批量同口径——祝福只针对今日在册）。
        if ((type == HrTaskType.birthday || type == HrTaskType.anniversary) &&
            isToday &&
            perms.contains(Perm.noticePublish)) ...[
          if (item.blessed)
            _Chip(
              label: '已祝福',
              bg: theme.colorScheme.surfaceContainerHighest,
              fg: theme.colorScheme.onSurfaceVariant,
              icon: Icons.check_circle_outline,
            )
          else
            FilledButton.tonalIcon(
              icon: Icon(type.icon, size: 18),
              label: const Text('送祝福'),
              onPressed: () => context.push(
                '${RouteName.noticePublish}?type='
                '${type == HrTaskType.birthday ? 'birthday' : 'anniversary'}'
                '&subject=${item.employeeId}',
              ),
            ),
        ],
        if (blocked && type == HrTaskType.confirm && !canConfirm)
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
            const Text(
              '选择实际转正日期(默认为今天)。试用期员工将转为在职；'
              '已是正式员工的将补登转正日期。',
            ),
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
    // 后端 confirm 覆盖试用期转正与在职未登记补登；409 文案后端直出，
    // 不回退 PUT 档案（会被「修改转正日期请使用转正功能」闸门拦死）。
    await repo.confirm(item.employeeId, confirmedDate: date);
    if (!context.mounted) return;
    context.appSuccess('已登记 ${item.name} 的转正日期 $date');
  } on ApiException catch (e) {
    if (!context.mounted) return;
    context.appApiError(e);
  } finally {
    await ref.read(hrTaskSummaryProvider.notifier).reloadSilently();
  }
}
