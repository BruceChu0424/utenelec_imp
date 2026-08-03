// 采购管理入口页（hub）—— 两个分组卡片：
//  ① 采购管理：4 单据卡片（申请/订货/收货/退货）
//  ② 采购报表：报表卡片（明细/汇总/待交货）
// 点卡片进对应列表/报表页。布局对齐基础资料 hub 的卡片风格。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../warehouse/pages/procurement_return_task_pages.dart';
import '../../warehouse/providers/procurement_inbound_count_providers.dart';
import '../../warehouse/widgets/procurement_inbound_badges.dart';
import '../config/purchase_doc_config.dart';
import '../config/purchase_report_config.dart';
import '../widgets/purchase_task_badge.dart';

class PurchaseHubPage extends ConsumerWidget {
  const PurchaseHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 返回即刷新：回到本 hub 时重拉「待退回供应商」任务数。
    // 「采购任务中心」角标（PurchaseTaskBadge）是全局轮询 Provider，
    // 由外壳 MainShellPage 的全局角标刷新覆盖，这里无需重复。
    ref.onPageResume(RouteName.purchase, () {
      ref.invalidate(
        procurementArrivalReturnCountProvider(
          ProcurementInboundOrderType.purchase,
        ),
      );
    });
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: '采购管理',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: ListView(
            padding: const EdgeInsets.only(top: UtenSpacing.s12),
            children: [
              _section(context, theme, '任务中心', [
                _Entry(
                  icon: Icons.pending_actions_rounded,
                  label: '采购任务中心',
                  description: '查看计划申请，按供应商分解为订货单',
                  location: RouteName.operationsPurchaseWorkbench,
                  badge: const PurchaseTaskBadge(),
                ),
                _Entry(
                  icon: Icons.assignment_return_outlined,
                  label: '待退回供应商',
                  description: '处理本人下单且财务未批准入库的数量',
                  location: procurementReturnTasksLocation(
                    ProcurementInboundOrderType.purchase,
                  ),
                  badge: const ProcurementArrivalReturnBadge(
                    orderType: ProcurementInboundOrderType.purchase,
                  ),
                ),
              ]),
              const SizedBox(height: UtenSpacing.s16),
              _section(context, theme, '采购管理', [
                _Entry.fromCfg(PurchaseDocConfig.request),
                _Entry.fromCfg(PurchaseDocConfig.order),
                _Entry.fromCfg(PurchaseDocConfig.receipt),
                _Entry.fromCfg(PurchaseDocConfig.returnDoc),
              ]),
              const SizedBox(height: UtenSpacing.s16),
              _section(context, theme, '采购报表', [
                for (final k in PurchaseReportKind.values)
                  _Entry(
                    icon: k.icon,
                    label: k.label,
                    description: k.shortLabel,
                    location: '/purchase/report/${k.name}',
                  ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  /// 一个分组：标题 + 卡片网格。
  Widget _section(
    BuildContext context,
    ThemeData theme,
    String title,
    List<_Entry> entries,
  ) {
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
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          UtenResponsiveGrid(
            itemCount: entries.length,
            spacing: UtenSpacing.s12,
            columns: const UtenResponsiveColumns(compact: 2, medium: 4),
            itemBuilder: (context, i, _) => _EntryTile(entry: entries[i]),
          ),
        ],
      ),
    );
  }
}

/// 一个入口项（单据类型或报表）。
class _Entry {
  _Entry({
    required this.icon,
    required this.label,
    required this.description,
    required this.location,
    this.badge,
  });

  _Entry.fromCfg(PurchaseDocConfig cfg)
    : icon = cfg.icon,
      label = cfg.label,
      description = cfg.shortLabel,
      location = cfg.skipListOnCreate
          ? RoutePath.purchaseDocNew(cfg.type.pathSegment)
          : '/purchase/${cfg.type.pathSegment}',
      badge = null;

  final IconData icon;
  final String label;
  final String description;
  final String location;
  final Widget? badge;
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});
  final _Entry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Material(
      type: MaterialType.transparency,
      borderRadius: UtenRadius.lgAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => goFrom(context, entry.location),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            vertical: UtenSpacing.s20,
            horizontal: UtenSpacing.s16,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: UtenRadius.lgAll,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: UtenRadius.mdAll,
                    ),
                    child: Icon(entry.icon, color: color, size: 22),
                  ),
                  if (entry.badge != null) ...[
                    const Spacer(),
                    entry.badge!,
                  ],
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                entry.label,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                entry.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
