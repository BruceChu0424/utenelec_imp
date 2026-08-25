import 'package:flutter/material.dart';

import '../../components/data_display/uten_status_badge.dart';
import '../../components/feedback/uten_empty.dart';
import '../../core/theme/uten_tokens.dart';
import 'data_handover_models.dart';

class DataHandoverPreviewCard extends StatelessWidget {
  const DataHandoverPreviewCard({super.key, required this.preview});

  final DataHandoverPreview preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!preview.hasData && preview.items.isEmpty) {
      return const UtenEmpty(
        icon: Icons.task_alt_rounded,
        message: '没有需要交接的数据',
        description: '历史操作记录仍按原员工保留，本次可直接继续办理。',
      );
    }
    final groups = <String, List<DataHandoverPreviewItem>>{};
    for (final item in preview.items) {
      groups.putIfAbsent(item.scope, () => []).add(item);
    }
    final actionCounts = <DataHandoverAction, int>{
      for (final action in DataHandoverAction.values)
        action: preview.actionCount(action),
    };
    final inheritedScopeCount = preview.scopeTargetEmployeeIds.entries
        .where((entry) => entry.value != preview.targetEmployeeId)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(UtenSpacing.s12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: UtenRadius.mdAll,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '影响 ${preview.total} 项次（按分类合计，可能包含同一业务记录的不同处理动作）。'
                '只转移当前责任；历史制单、审批和审计记录不改写。',
                style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
              ),
              const SizedBox(height: UtenSpacing.s8),
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  _actionCountBadge(
                    '转移 ${actionCounts[DataHandoverAction.transfer]}',
                    UtenStatusBadgeType.info,
                  ),
                  _actionCountBadge(
                    '历史查阅 ${actionCounts[DataHandoverAction.historyAccess]}',
                    UtenStatusBadgeType.neutral,
                  ),
                  _actionCountBadge(
                    '释放 ${actionCounts[DataHandoverAction.release]}',
                    UtenStatusBadgeType.success,
                  ),
                  _actionCountBadge(
                    '阻塞 ${actionCounts[DataHandoverAction.blocking]}',
                    UtenStatusBadgeType.danger,
                  ),
                ],
              ),
            ],
          ),
        ),
        if (inheritedScopeCount > 0) ...[
          const SizedBox(height: UtenSpacing.s8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: UtenRadius.mdAll,
            ),
            child: Text(
              '已有 $inheritedScopeCount 个业务范围完成过分模块交接，'
              '既有接手关系将保留；本次选择的默认接手人只承接尚未交接的范围。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                height: 1.5,
              ),
            ),
          ),
        ],
        if (preview.hasBlockers) ...[
          const SizedBox(height: UtenSpacing.s8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: UtenRadius.mdAll,
            ),
            child: Text(
              '存在阻塞项：请按红色项目提示回到对应业务页面处理，再刷新盘点。'
              '系统不会跳过阻塞项，也不会提前停用账号。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
                height: 1.5,
              ),
            ),
          ),
        ],
        for (final entry in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.only(
              top: UtenSpacing.s12,
              bottom: UtenSpacing.s4,
            ),
            child: Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  dataHandoverScopeLabel(entry.key),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (preview.scopeTargetEmployeeNames.containsKey(entry.key))
                  UtenStatusBadge(
                    label:
                        preview.scopeTargetEmployeeIds[entry.key] ==
                            preview.targetEmployeeId
                        ? '默认接手剩余范围 · ${preview.scopeTargetEmployeeNames[entry.key]}'
                        : '沿用既有交接 · ${preview.scopeTargetEmployeeNames[entry.key]}',
                    type: UtenStatusBadgeType.neutral,
                    size: UtenStatusBadgeSize.small,
                  ),
              ],
            ),
          ),
          for (final item in entry.value) _item(context, item),
        ],
      ],
    );
  }

  Widget _actionCountBadge(String label, UtenStatusBadgeType type) =>
      UtenStatusBadge(
        label: label,
        type: type,
        size: UtenStatusBadgeSize.small,
      );

  Widget _item(BuildContext context, DataHandoverPreviewItem item) {
    final theme = Theme.of(context);
    final blocking = item.isBlocking;
    final type = switch (item.action) {
      DataHandoverAction.transfer => UtenStatusBadgeType.info,
      DataHandoverAction.historyAccess => UtenStatusBadgeType.neutral,
      DataHandoverAction.release => UtenStatusBadgeType.success,
      DataHandoverAction.blocking => UtenStatusBadgeType.danger,
    };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        border: Border.all(
          color: blocking
              ? theme.colorScheme.error
              : theme.colorScheme.outlineVariant,
        ),
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            blocking ? Icons.error_outline_rounded : Icons.inventory_2_outlined,
            color: blocking
                ? theme.colorScheme.error
                : theme.colorScheme.primary,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: blocking ? theme.colorScheme.error : null,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('${item.count} 项'),
                    UtenStatusBadge(
                      label: item.action.label,
                      type: type,
                      size: UtenStatusBadgeSize.small,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
