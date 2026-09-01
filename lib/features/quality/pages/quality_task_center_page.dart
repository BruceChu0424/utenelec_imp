// 品质管理部任务中心（hub）—— 品质侧任务统一入口。
//
// 首张卡「待检处置」：采购/委外收货单的 IQC 检验任务（角标=待检收货单张数，
// 60s 轮询），点击进待检处置工作台；无 procurement_inspection:view 不显示该卡。
// 待检处置已从仓库「预计到货任务中心」移交品质部——品质只登记质量结论；
// 合格切片进入仓库「IQC 合格待入库」，仓库确认实物和库位后才增加库存。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_hub_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../warehouse/providers/procurement_inbound_count_providers.dart';
import '../../warehouse/widgets/procurement_inspection_pending_badge.dart';
import '../../../shared/providers/production_fqc_pending_count_provider.dart';
import '../widgets/production_fqc_pending_badge.dart';

class QualityTaskCenterPage extends ConsumerWidget {
  const QualityTaskCenterPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 返回即刷新：处置完待检单回到本页时角标立即重拉（不等下一轮 60s 轮询）。
    ref.onPageResume(RouteName.qualityTaskCenter, () {
      ref.invalidate(procurementInspectionPendingCountProvider);
      ref.invalidate(productionFqcPendingCountProvider);
    });
    final theme = Theme.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    final canViewInspection =
        superAdmin || permissions.contains(Perm.procurementInspectionView);
    final canViewFqc =
        superAdmin ||
        permissions.contains(Perm.productionQualityInspectionView);
    final taskEntries = <_QualityEntry>[
      if (canViewInspection)
        const _QualityEntry(
          icon: Icons.fact_check_outlined,
          label: '待检处置',
          description: '采购/委外收货 IQC；合格后转仓库确认入库，不直接增加库存。',
          location: RouteName.warehouseInspections,
          badge: ProcurementInspectionPendingBadge(showLabel: true),
        ),
      if (canViewFqc)
        const _QualityEntry(
          icon: Icons.rule_folder_outlined,
          label: '生产成品质检',
          description: '仓库完成送检登记后判定合格、部分合格或不合格。',
          location: RouteName.productionFqcInspections,
          badge: ProductionFqcPendingBadge(showLabel: true),
        ),
    ];
    final recordEntries = <_QualityEntry>[
      if (canViewInspection || canViewFqc)
        const _QualityEntry(
          icon: Icons.science_outlined,
          label: '检测记录',
          description: '只读查询 IQC/FQC 检验结果与历史决定。',
          location: RouteName.qualityInspectionRecords,
        ),
    ];
    return Scaffold(
      appBar: UtenAppBar(
        title: '品质任务中心',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: ListView(
            padding: EdgeInsets.only(
              top: UtenSpacing.s12,
              bottom: context.breakpoint.isCompact
                  ? UtenSpacing.s16
                  : UtenSpacing.s40,
            ),
            children: [
              if (taskEntries.isNotEmpty)
                _section(context, theme, '任务中心', taskEntries),
              if (taskEntries.isNotEmpty && recordEntries.isNotEmpty)
                const SizedBox(height: UtenSpacing.s16),
              if (recordEntries.isNotEmpty)
                _section(
                  context,
                  theme,
                  '查询与记录',
                  recordEntries,
                  description:
                      '检测记录页仅供只读查询；质量决定及后续撤销历史会完整保留，'
                      '不能在记录页修改或删除。',
                ),
              if (taskEntries.isEmpty && recordEntries.isEmpty)
                const UtenEmpty(
                  icon: Icons.lock_outline_rounded,
                  message: '暂无已授权的品质页面',
                  description: '请联系品质主管开通 IQC 或生产成品质检查看权限。',
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(
    BuildContext context,
    ThemeData theme,
    String title,
    List<_QualityEntry> entries, {
    String? description,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: UtenSpacing.s4,
              bottom: UtenSpacing.s8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (description != null) ...[
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          UtenResponsiveGrid(
            itemCount: entries.length,
            spacing: UtenSpacing.s12,
            columns: const UtenResponsiveColumns(compact: 2, medium: 4),
            itemBuilder: (context, i, _) {
              final entry = entries[i];
              return UtenHubCard(
                icon: entry.icon,
                label: entry.label,
                description: entry.description,
                onTap: () => goFrom(context, entry.location),
                badge: entry.badge,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _QualityEntry {
  const _QualityEntry({
    required this.icon,
    required this.label,
    required this.description,
    required this.location,
    this.badge,
  });

  final IconData icon;
  final String label;
  final String description;
  final String location;
  final Widget? badge;
}
