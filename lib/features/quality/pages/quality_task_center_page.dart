// 品质管理部任务中心（hub）—— 品质侧任务统一入口。
//
// 2026-09-01 合并：首张卡「待检处置」同时收 IQC（采购/委外收货）与 FQC（自制
// 产成品）——原「生产成品质检」独立卡取消，FQC 任务成为待检处置页内「自制产成品」
// 分段。角标 = IQC 待检收货单张数 + FQC 待检任务数（红色圆数字徽章，与工作台
// 品质卡同口径）；持有任一查看权限即显示该卡。
// 待检处置已从仓库「预计到货任务中心」移交品质部——品质只登记质量结论；
// 合格切片进入仓库「IQC 合格待入库」，仓库确认实物和库位后才增加库存。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_hub_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_notification_badge.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/production_fqc_pending_count_provider.dart';
import '../../warehouse/providers/procurement_inbound_count_providers.dart';

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
      if (canViewInspection || canViewFqc)
        const _QualityEntry(
          icon: Icons.fact_check_outlined,
          label: '待检处置',
          description: '采购/委外收货 IQC 与自制产成品 FQC；合格后转仓库确认入库。',
          location: RouteName.warehouseInspections,
          badge: _QualityDisposalPendingBadge(showLabel: true),
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

/// 待检处置合并角标：IQC 待检收货单张数 + FQC 待检任务数（红色圆数字徽章）。
///
/// 与工作台「品质任务中心」卡角标同口径：任一来源失败显示可辨识的异常图标、
/// 任一来源仍在加载时不展示半程合计——不把「未知」伪装成真实 0。
/// 逻辑与 dashboard/widgets/quality_inspection_pending_badge.dart 一致
///（quality→dashboard 无依赖边，组件留各自副本）。
class _QualityDisposalPendingBadge extends ConsumerWidget {
  const _QualityDisposalPendingBadge({this.showLabel = false});

  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final iqc = ref.watch(procurementInspectionPendingCountProvider);
    final fqc = ref.watch(productionFqcPendingCountProvider);
    if (iqc.hasError || fqc.hasError) {
      return Tooltip(
        message: '品质待检数量加载失败，请进入待检处置后重试',
        child: Icon(
          Icons.sync_problem_outlined,
          key: const ValueKey('quality-disposal-badge-error'),
          size: 20,
          color: Theme.of(context).colorScheme.error,
          semanticLabel: '品质待检数量加载失败，请进入待检处置后重试',
        ),
      );
    }
    if (iqc.isLoading || fqc.isLoading) {
      return const SizedBox.shrink();
    }
    return UtenNotificationBadge(
      count: (iqc.valueOrNull ?? 0) + (fqc.valueOrNull ?? 0),
      showLabel: showLabel,
    );
  }
}
