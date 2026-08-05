// HR 工作台子页面：按类型展示任务列表（转正办理/生日关怀/入职周年/新近入职）。
// 行内快捷操作：登记转正（转正类）、认领/释放/接管（软认领，ADR-021）、点行进员工详情。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
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
