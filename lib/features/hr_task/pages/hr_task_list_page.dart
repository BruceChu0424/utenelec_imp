// HR 工作台子页面：按类型展示任务列表（转正办理/生日关怀/入职周年/新近入职）。
// 行内快捷操作：登记转正（转正类）、认领/释放/接管（软认领，ADR-021）、点行进员工详情。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../notice/models/notice.dart';
import '../../notice/providers/notice_providers.dart';
import '../models/hr_task_summary.dart';
import '../providers/hr_task_summary_provider.dart';
import '../widgets/hr_task_widgets.dart';

class HrTaskListPage extends ConsumerWidget {
  const HrTaskListPage({super.key, required this.type});

  final HrTaskType type;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(hrTaskSummaryProvider);

    Widget body = async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => UtenEmpty.error(
        message: '加载失败，请稍后重试',
        actionLabel: '重试',
        onAction: () => ref.read(hrTaskSummaryProvider.notifier).refresh(),
      ),
      data: (s) {
        final items = hrTaskItemsOf(s, type);
        final isCelebration = type == HrTaskType.birthday ||
            type == HrTaskType.anniversary;
        final canPublish = ref.watch(isSuperAdminProvider) ||
            ref
                .watch(currentPermissionsProvider)
                .contains(Perm.noticePublish);
        // 一键祝福只针对「今日」在册且本类型本年未祝福者。
        // 注意：生日列表 hrTaskItemsOf 把 birthdayToday 与未来 30 天的
        // birthdayUpcoming 合并展示了，不能拿合并后的 items 整列发，否则会把
        // 还没到的生日也提前祝福掉。这里只取今日列表（周年列表本身就是今日全量）。
        final todayItems = switch (type) {
          HrTaskType.birthday => s.birthdayToday,
          HrTaskType.anniversary => s.anniversaryToday,
          _ => const <HrTaskItem>[],
        };
        final toBless = isCelebration
            ? todayItems.where((i) => !i.blessed).toList()
            : <HrTaskItem>[];
        return RefreshIndicator(
          onRefresh: () =>
              ref.read(hrTaskSummaryProvider.notifier).refresh(),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              if (type == HrTaskType.confirm)
                _hint(context, '试用期 ${s.probationMonths} 个月口径；'
                    '被认领的事项显示「处理中」，他人不可重复操作。'),
              if (isCelebration && canPublish && toBless.isNotEmpty)
                _celebrationBatchBar(context, ref, type, toBless),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s24),
                  child: UtenEmpty(message: type.emptyText),
                )
              else
                Card(
                  margin: const EdgeInsets.fromLTRB(
                    UtenSpacing.s12,
                    UtenSpacing.s8,
                    UtenSpacing.s12,
                    0,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < items.length; i++) ...[
                        if (i > 0)
                          const Divider(height: 1, indent: 16, endIndent: 16),
                        HrTaskTile(type: type, item: items[i]),
                      ],
                    ],
                  ),
                ),
              if (type == HrTaskType.confirm && s.unconfirmedLegacyCount > 0)
                _hint(
                  context,
                  '另有 ${s.unconfirmedLegacyCount} 名入职满一年的员工未登记转正日期，'
                  '请在员工档案中补录。',
                ),
            ],
          ),
        );
      },
    );
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: type.title,
        showBackButton: true,
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () =>
                ref.read(hrTaskSummaryProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: body,
    );
  }

  /// 庆典一键批量送祝福条（生日/周年子页顶部）：对今日未祝福者一键发布默认模板祝福。
  Widget _celebrationBatchBar(
    BuildContext context,
    WidgetRef ref,
    HrTaskType type,
    List<HrTaskItem> toBless,
  ) {
    final theme = Theme.of(context);
    final noun = type == HrTaskType.birthday ? '生日' : '入职周年';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s12,
        0,
      ),
      child: Card(
        clipBehavior: Clip.antiAlias,
        color: theme.colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: UtenSpacing.s8,
          ),
          child: Row(
            children: [
              Icon(
                type == HrTaskType.birthday
                    ? Icons.cake_rounded
                    : Icons.emoji_events_rounded,
                color: theme.colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  '一键为今日$noun的 ${toBless.length} 人送上祝福',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: () => _batchBless(context, ref, type, toBless),
                icon: const Icon(Icons.send_rounded, size: 18),
                label: const Text('一键全部'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _batchBless(
    BuildContext context,
    WidgetRef ref,
    HrTaskType type,
    List<HrTaskItem> toBless,
  ) async {
    final noticeType = type == HrTaskType.birthday
        ? NoticeType.birthday
        : NoticeType.anniversary;
    try {
      final result = await ref
          .read(noticeRepositoryProvider)
          .publishCelebrationBatch(
            type: noticeType,
            employeeIds: [for (final i in toBless) i.employeeId],
          );
      if (!context.mounted) return;
      context.appSuccess(
        result.skipped > 0
            ? '已为 ${result.published} 人发布祝福（${result.skipped} 人今日已祝福）'
            : '已为 ${result.published} 人发布祝福',
      );
    } on ApiException catch (e) {
      if (!context.mounted) return;
      context.appApiError(e);
    } finally {
      // 重取 summary → 同步工作台/部门徽标（已祝福者不再计入，角标即减）。
      await ref.read(hrTaskSummaryProvider.notifier).reloadSilently();
    }
  }

  Widget _hint(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s16,
        UtenSpacing.s4,
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
