// 出入库记录页（Phase 4）
// 文档：docs/03-页面/出入库记录页.md

import 'package:flutter/material.dart';
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

enum MovementFilter { all, inbound, outbound, transfer }

class InventoryMovementPage extends ConsumerWidget {
  const InventoryMovementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typeFilter = ref.watch(movementTypeFilterProvider);
    final listAsync = ref.watch(inventoryMovementListProvider);

    final seg = typeFilter == MovementType.inbound
        ? MovementFilter.inbound
        : typeFilter == MovementType.outbound
            ? MovementFilter.outbound
            : typeFilter == MovementType.transfer
                ? MovementFilter.transfer
                : MovementFilter.all;

    return Scaffold(
      appBar: const UtenAppBar(title: '出入库记录', showBackButton: true),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: UtenSegmentedFilter<MovementFilter>(
              selected: seg,
              onChanged: (v) {
                ref.read(movementTypeFilterProvider.notifier).state =
                    switch (v) {
                  MovementFilter.all => null,
                  MovementFilter.inbound => MovementType.inbound,
                  MovementFilter.outbound => MovementType.outbound,
                  MovementFilter.transfer => MovementType.transfer,
                };
              },
              segments: const [
                UtenSegment(value: MovementFilter.all, label: '全部'),
                UtenSegment(value: MovementFilter.inbound, label: '入库'),
                UtenSegment(value: MovementFilter.outbound, label: '出库'),
                UtenSegment(value: MovementFilter.transfer, label: '调拨'),
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
                    UtenEmpty(icon: Icons.swap_vert_rounded, message: '暂无出入库记录'),
                  ]);
                }
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: UtenResponsiveGrid(
                    itemCount: list.length,
                    itemBuilder: (context, i, _) => _MovementCard(m: list[i]),
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

class _MovementCard extends StatelessWidget {
  const _MovementCard({required this.m});
  final InventoryMovement m;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (badgeType, color) = switch (m.type) {
      MovementType.inbound =>
        (UtenStatusBadgeType.success, UtenColors.success),
      MovementType.outbound => (UtenStatusBadgeType.info, UtenColors.info),
      MovementType.transfer =>
        (UtenStatusBadgeType.neutral, UtenColors.slate500),
    };
    final sign = m.type == MovementType.outbound ? '-' : '+';
    return UtenCard(
      child: Row(
        children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              m.type == MovementType.inbound
                  ? Icons.south_west_rounded
                  : m.type == MovementType.outbound
                      ? Icons.north_east_rounded
                      : Icons.swap_horiz_rounded,
              color: color,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    UtenStatusBadge(
                        label: m.type.label, type: badgeType, size: UtenStatusBadgeSize.small),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(m.materialName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text('${m.warehouse} · ${m.operatorName} · ${m.ref ?? '—'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('$sign${m.quantity}',
                  style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: color,
                      fontFeatures: const [FontFeature.tabularFigures()])),
              Text('${m.date.month}/${m.date.day} ${m.date.hour.toString().padLeft(2, '0')}:${m.date.minute.toString().padLeft(2, '0')}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }
}
