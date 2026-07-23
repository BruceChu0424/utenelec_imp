// 库存查询页（Phase 4）
// 文档：docs/03-页面/库存列表页.md

import 'package:flutter/material.dart' hide Material, MaterialType;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/theme/uten_colors.dart';
import '../models/inventory.dart';
import '../providers/inventory_providers.dart';

enum InventoryFilter { all, low, out }

class InventoryListPage extends ConsumerWidget {
  const InventoryListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(inventoryStatusFilterProvider);
    final listAsync = ref.watch(inventoryListProvider);
    final theme = Theme.of(context);

    final segValue = filter == StockStatus.low
        ? InventoryFilter.low
        : filter == StockStatus.out
            ? InventoryFilter.out
            : InventoryFilter.all;

    return Scaffold(
      appBar: const UtenAppBar(title: '库存查询', showBackButton: true),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              onChanged: (v) =>
                  ref.read(inventorySearchProvider.notifier).state = v,
              decoration: InputDecoration(
                hintText: '搜索物料编码 / 名称',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                isDense: true, filled: true,
                fillColor: theme.colorScheme.surface,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: theme.colorScheme.outline)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: UtenSegmentedFilter<InventoryFilter>(
              selected: segValue,
              onChanged: (v) {
                ref.read(inventoryStatusFilterProvider.notifier).state =
                    switch (v) {
                  InventoryFilter.all => null,
                  InventoryFilter.low => StockStatus.low,
                  InventoryFilter.out => StockStatus.out,
                };
              },
              segments: const [
                UtenSegment(value: InventoryFilter.all, label: '全部'),
                UtenSegment(value: InventoryFilter.low, label: '低位'),
                UtenSegment(value: InventoryFilter.out, label: '缺货'),
              ],
            ),
          ),
          Expanded(
            child: listAsync.when(
              loading: () => const UtenSkeletonList(itemCount: 6),
              error: (e, _) => UtenEmpty.error(message: '加载失败：$e'),
              data: (list) {
                if (list.isEmpty) {
                  return ListView(children: const [
                    SizedBox(height: 80),
                    UtenEmpty(icon: Icons.inventory_2_outlined, message: '暂无库存'),
                  ]);
                }
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: UtenResponsiveGrid(
                    itemCount: list.length,
                    itemBuilder: (context, i, _) => _MaterialCard(m: list[i]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MaterialCard extends StatelessWidget {
  const _MaterialCard({required this.m});
  final Material m;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, type, color) = switch (m.status) {
      StockStatus.sufficient => ('充足', UtenStatusBadgeType.success, UtenColors.success),
      StockStatus.low => ('低位', UtenStatusBadgeType.warning, UtenColors.warning),
      StockStatus.out => ('缺货', UtenStatusBadgeType.danger, UtenColors.error),
    };
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(m.type == MaterialType.raw
                    ? Icons.inventory_2_outlined
                    : Icons.inventory_outlined, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.name,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    Text('${m.code} · ${m.type.label}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              UtenStatusBadge(label: label, type: type, size: UtenStatusBadgeSize.small),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(m.warehouse,
                  style: theme.textTheme.bodySmall),
              Text('${m.quantity} ${m.unit}',
                  style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: m.status == StockStatus.out
                          ? UtenColors.error
                          : theme.colorScheme.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: 4),
          Text('安全库存 ${m.safetyStock} ${m.unit}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
