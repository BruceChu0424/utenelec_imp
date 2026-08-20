// 品质管理部任务中心（hub）—— 品质侧任务统一入口。
//
// 首张卡「待检处置」：采购/委外收货单的 IQC 检验任务（角标=待检收货单张数，
// 60s 轮询），点击进待检处置工作台；无 procurement_inspection:view 不显示该卡。
// 待检处置已从仓库「预计到货任务中心」移交品质部——仓库侧只读「待品质部批准」，
// 检验通过后自动入库并回写物料分析进度。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_hub_card.dart';
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
import '../../warehouse/providers/procurement_inbound_count_providers.dart';

class QualityTaskCenterPage extends ConsumerWidget {
  const QualityTaskCenterPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 返回即刷新：处置完待检单回到本页时角标立即重拉（不等下一轮 60s 轮询）。
    ref.onPageResume(RouteName.qualityTaskCenter, () {
      ref.invalidate(procurementInspectionPendingCountProvider);
    });
    final theme = Theme.of(context);
    final canViewInspection =
        ref
            .watch(currentPermissionsProvider)
            .contains(Perm.procurementInspectionView) ||
        ref.watch(isSuperAdminProvider);
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                        left: UtenSpacing.s4,
                        bottom: UtenSpacing.s8,
                      ),
                      child: Text(
                        '检验任务',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    UtenResponsiveGrid(
                      itemCount: canViewInspection ? 1 : 0,
                      spacing: UtenSpacing.s12,
                      columns: const UtenResponsiveColumns(
                        compact: 2,
                        medium: 4,
                      ),
                      itemBuilder: (context, i, _) => UtenHubCard(
                        icon: Icons.fact_check_outlined,
                        label: '待检处置',
                        description: '采购/委外收货到料检验；合格放行后自动入库。',
                        onTap: () =>
                            goFrom(context, RouteName.warehouseInspections),
                        badge: const _InspectionPendingBadge(showLabel: true),
                      ),
                    ),
                    if (!canViewInspection)
                      const Padding(
                        padding: EdgeInsets.all(UtenSpacing.s8),
                        child: Text('您暂无检验任务权限，请联系品质主管开通。'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「待检处置」角标：待检收货单张数（与预计到货页角标同源，60s 轮询）。
class _InspectionPendingBadge extends ConsumerWidget {
  const _InspectionPendingBadge({this.showLabel = false});

  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref
        .watch(procurementInspectionPendingCountProvider)
        .valueOrNull;
    return UtenNotificationBadge(count: count ?? 0, showLabel: showLabel);
  }
}
