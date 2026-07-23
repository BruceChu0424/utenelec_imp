// 空调设备总览页（Phase 4）
// 文档：docs/03-页面/空调总览页.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/theme/uten_colors.dart';
import '../models/hvac_device.dart';
import '../providers/hvac_providers.dart';

class HvacOverviewPage extends ConsumerWidget {
  const HvacOverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final building = ref.watch(hvacBuildingProvider);
    final listAsync = ref.watch(hvacListProvider);
    final buildings = ['全部', '1号厂房', '2号厂房', '办公楼'];

    return Scaffold(
      appBar: const UtenAppBar(title: '空调总览', showBackButton: true),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final b in buildings) ...[
                  if (b != buildings.first) const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text(b),
                    selected: building == b,
                    onSelected: (_) =>
                        ref.read(hvacBuildingProvider.notifier).state = b,
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: listAsync.when(
              loading: () => const UtenSkeletonList(itemCount: 4),
              error: (e, _) => UtenEmpty.error(
                message: '加载失败：$e',
                onAction: () => ref.invalidate(hvacListProvider),
              ),
              data: (list) {
                if (list.isEmpty) {
                  return const UtenEmpty(
                      icon: Icons.hvac_outlined, message: '暂无空调设备');
                }
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: UtenResponsiveGrid(
                    itemCount: list.length,
                    itemBuilder: (context, i, _) => _DeviceCard(
                      device: list[i],
                      onTap: () => context.go('/hvac/${list[i].id}'),
                    ),
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

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.device, required this.onTap});
  final HvacDevice device;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final online = device.online;
    final color = !online
        ? UtenColors.error
        : device.power
            ? UtenColors.teal600
            : UtenColors.slate400;
    return UtenCard(
      onTap: device.online ? onTap : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.hvac_rounded, color: color, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(device.name,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    Text('${device.building} · ${device.floor}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                online ? '${device.currentTemp.toStringAsFixed(0)}°' : '离线',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  device.power ? '目标 ${device.targetTemp.toStringAsFixed(0)}° · ${device.mode.label}' : '已关闭',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
