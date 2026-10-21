// 仓库任务中心顶栏的仓库范围(ADR-149)。
//
// 谁能看哪些仓由服务端判定(my-scope)，这里只按结论显示:
//   · 主管：主题色描边选择器(当前范围)，点开右侧滑窗(先主仓后子仓)，首行「全部仓库」；
//   · 负责多个仓的子仓负责人：同上，首行「我负责的全部仓库」，只列自己负责的仓；
//   · 单仓负责人和其他人：同一个入口，只能在服务端给出的可见仓内缩小筛选。
// 选择按账号记忆；范围变化时任务中心骨架推进 refreshTick，各分段列表连同分段计数一起重拉。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../../../shared/widgets/warehouse_selection.dart';

class WarehouseScopeSelector extends ConsumerWidget {
  const WarehouseScopeSelector({super.key});

  /// 当前范围的显示名：默认范围按角色区分「全部仓库 / 我负责的全部仓库」。
  static String labelOf(
    AppLocalizations l10n,
    MyWarehouseScope mine,
    WarehouseTaskScope scope,
  ) {
    if (!scope.isAll) {
      final name =
          scope.warehouseName ??
          mine.option(scope.warehouseId!)?.name ??
          l10n.warehouseScopeAllWarehouses;
      return mine.selectable.any(
            (option) => option.parentId == scope.warehouseId,
          )
          ? l10n.warehouseScopeIncludingChildren(name)
          : name;
    }
    return mine.isSupervisor
        ? l10n.warehouseScopeAllWarehouses
        : mine.isKeeper
        ? l10n.warehouseScopeAllMine
        : l10n.warehouseScopeAllVisible;
  }

  /// 可选范围按层级(先主仓后子仓)交给全站仓库滑窗；选择器只认服务端给的可选清单。
  static List<WarehouseDictEntry> hierarchyOf(MyWarehouseScope mine) {
    final ids = {for (final option in mine.selectable) option.id};
    return [
      for (final option in mine.selectable)
        WarehouseDictEntry(
          id: option.id,
          name: option.name,
          code: option.code,
          parentId: ids.contains(option.parentId) ? option.parentId : null,
          status: '使用',
        ),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 顶栏组件被多张页面复用, 少数既有测试不挂本地化代理: 取不到时按中文显示。
    final l10n =
        Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        lookupAppLocalizations(const Locale('zh'));
    final theme = Theme.of(context);
    final scopeState = ref.watch(myWarehouseScopeProvider);
    if (scopeState.hasError) {
      return TextButton.icon(
        key: const Key('warehouse-scope-retry'),
        onPressed: () => ref.invalidate(myWarehouseScopeProvider),
        icon: const Icon(Icons.refresh, size: 18),
        label: Text(l10n.warehouseScopeLoadFailedRetry),
      );
    }
    final mine = confirmedMyWarehouseScope(scopeState);
    if (mine == null) return const SizedBox.shrink();
    if (!mine.showsSelector) return const SizedBox.shrink();
    final scope = ref.watch(warehouseTaskScopeProvider);
    final label = labelOf(l10n, mine, scope);
    return Tooltip(
      message: mine.isSupervisor
          ? l10n.warehouseScopeSupervisorTooltip
          : mine.isKeeper
          ? l10n.warehouseScopeKeeperTooltip
          : l10n.warehouseScopeVisibleTooltip,
      child: InkWell(
        key: const Key('warehouse-scope-selector'),
        borderRadius: BorderRadius.circular(UtenRadius.control),
        onTap: () async {
          final picked = await showUtenWarehousePickerPanel(
            context,
            hierarchy: hierarchyOf(mine),
            use: WarehouseUse.query,
            title: l10n.warehouseScopePickerTitle,
            includeAll: true,
            allLabel: labelOf(l10n, mine, const WarehouseTaskScope.all()),
            initialWarehouseId: scope.warehouseId,
            subtitleOf: (entry) =>
                mine.selectable.any((option) => option.parentId == entry.id)
                ? l10n.warehouseScopeIncludesVisibleChildren
                : null,
          );
          if (picked == null || !context.mounted) return;
          final current = confirmedMyWarehouseScope(
            ref.read(myWarehouseScopeProvider),
          );
          if (current == null ||
              (!picked.isAll && !current.canSelect(picked.id))) {
            return;
          }
          ref
              .read(warehouseTaskScopePrefProvider.notifier)
              .select(
                picked.isAll
                    ? const WarehouseTaskScope.all()
                    : WarehouseTaskScope.warehouse(
                        picked.id,
                        name: current.option(picked.id)?.name,
                      ),
              );
        },
        child: Ink(
          key: const Key('warehouse-scope-selector-border'),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.primary),
            borderRadius: UtenRadius.controlAll,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: UtenControlMetrics.minimumHitExtent(
                context,
                desktop: UtenControlMetrics.compactHeight,
              ),
            ),
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
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(
                      label,
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
        ),
      ),
    );
  }
}
