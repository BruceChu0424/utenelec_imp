// 仓库任务中心顶栏的「仓库范围」选择(ADR-115)：我的仓库 / 全部仓库 / 某个仓。
//
// 选择按账号记忆；范围变化时任务中心骨架推进 refreshTick，各分段列表连同分段计数一起重拉。
// 口径说明见 shared/warehouse/warehouse_task_scope.dart。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/uten_tokens.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';

class WarehouseScopeSelector extends ConsumerWidget {
  const WarehouseScopeSelector({super.key});

  static String labelOf(WarehouseTaskScope scope) => switch (scope.mode) {
    WarehouseTaskScopeMode.all => '全部仓库',
    WarehouseTaskScopeMode.mine => '我的仓库',
    WarehouseTaskScopeMode.warehouse => scope.warehouseName ?? '指定仓库',
  };

  /// 「我的仓库」一项的说明：负责哪些仓 / 为什么等于全部。
  static String mineHint(MyWarehouseScope? mine) {
    if (mine == null) return '正在读取我负责的仓库…';
    if (!mine.keepersConfigured) {
      return '还没有在「仓库资料」里登记任何仓库负责人，目前等于全部仓库';
    }
    final names = mine.keeperWarehouses.map((w) => w.name).join('、');
    return mine.isKeeper
        ? '我负责：$names；另含尚未指定负责人的仓库与尚未定仓的任务'
        : '我不是任何仓库的负责人：只显示尚未指定负责人的仓库与尚未定仓的任务';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scope = ref.watch(warehouseTaskScopeProvider);
    final mine = ref.watch(myWarehouseScopeProvider).valueOrNull;
    final options =
        ref.watch(warehouseScopeOptionsProvider).valueOrNull ?? const [];
    final byId = {for (final option in options) option.id: option};
    int depthOf(WarehouseScopeOption option) {
      var depth = 0;
      var parent = option.parentId;
      final seen = <String>{};
      while (parent != null && byId.containsKey(parent) && seen.add(parent)) {
        depth++;
        parent = byId[parent]!.parentId;
      }
      return depth;
    }

    PopupMenuItem<WarehouseTaskScope> item(
      WarehouseTaskScope value,
      String title, {
      String? subtitle,
      int indent = 0,
      Key? key,
    }) {
      final selected = value == scope;
      return PopupMenuItem<WarehouseTaskScope>(
        key: key,
        value: value,
        child: Padding(
          padding: EdgeInsets.only(left: UtenSpacing.s12 * indent),
          child: Row(
            children: [
              Icon(
                selected ? Icons.check_rounded : null,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: selected
                          ? TextStyle(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            )
                          : null,
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Tooltip(
      message: '仓库范围：${labelOf(scope)}。只影响本页列表显示哪些仓的单据，不改变权限',
      child: PopupMenuButton<WarehouseTaskScope>(
        key: const Key('warehouse-scope-selector'),
        tooltip: '',
        position: PopupMenuPosition.under,
        constraints: const BoxConstraints(minWidth: 260, maxWidth: 360),
        onSelected: (value) =>
            ref.read(warehouseTaskScopePrefProvider.notifier).select(value),
        itemBuilder: (context) => [
          item(
            const WarehouseTaskScope.mine(),
            '我的仓库',
            subtitle: mineHint(mine),
            key: const Key('warehouse-scope-mine'),
          ),
          item(
            const WarehouseTaskScope.all(),
            '全部仓库',
            subtitle: '显示所有仓库的单据',
            key: const Key('warehouse-scope-all'),
          ),
          if (options.isNotEmpty) const PopupMenuDivider(),
          for (final option in options)
            item(
              WarehouseTaskScope.warehouse(option.id, name: option.name),
              option.name,
              indent: depthOf(option),
              key: Key('warehouse-scope-${option.id}'),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s8,
            vertical: UtenSpacing.s4,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.warehouse_outlined,
                size: 18,
                color: scope.isAll
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  labelOf(scope),
                  key: const Key('warehouse-scope-label'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scope.isAll ? null : theme.colorScheme.primary,
                  ),
                ),
              ),
              const Icon(Icons.arrow_drop_down_rounded, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
