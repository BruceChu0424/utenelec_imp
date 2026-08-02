// 委外管理入口页（hub）—— 两个分组卡片：
//  ① 委外管理：8 单据卡片（询价/申请/订货/进仓/发料/退货/材料退/损耗）。
//     其中询价/申请老库 0 行（结构建立），灰显并标"未启用"。
//  ② 委外报表：报表卡片（月度汇总 ×8 docType + 出入状况表 + 明细走列表页）。
// 点卡片进对应列表/报表页。布局对齐采购/基础资料 hub 的卡片风格。
//
// 入口归综合营销部（DEPT_SALES）；view 权限全员，edit 归综合营销部（V53 seed）。
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../warehouse/pages/procurement_return_task_pages.dart';
import '../../warehouse/widgets/procurement_inbound_badges.dart';
import '../config/subcontract_doc_config.dart';
import '../config/subcontract_report_config.dart';

class SubcontractHubPage extends StatelessWidget {
  const SubcontractHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: '委外管理',
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
                  icon: Icons.precision_manufacturing_outlined,
                  label: '委外任务中心',
                  description: '查看计划申请，按委外商分解为订货单',
                  location: RouteName.operationsSubcontractWorkbench,
                ),
                _Entry(
                  icon: Icons.assignment_return_outlined,
                  label: '待退回供应商',
                  description: '处理本人下单且财务未批准入库的数量',
                  location: procurementReturnTasksLocation(
                    ProcurementInboundOrderType.subcontract,
                  ),
                  badge: const ProcurementArrivalReturnBadge(
                    orderType: ProcurementInboundOrderType.subcontract,
                  ),
                ),
              ]),
              const SizedBox(height: UtenSpacing.s16),
              _section(context, theme, '委外管理', [
                _Entry.fromCfg(SubcontractDocConfig.inquiry),
                _Entry.fromCfg(SubcontractDocConfig.application),
                _Entry.fromCfg(SubcontractDocConfig.order),
                _Entry.fromCfg(SubcontractDocConfig.receipt),
                _Entry.fromCfg(SubcontractDocConfig.materialIssue),
                _Entry.fromCfg(SubcontractDocConfig.returnDoc),
                _Entry.fromCfg(SubcontractDocConfig.materialReturn),
                _Entry.fromCfg(SubcontractDocConfig.waste),
              ]),
              const SizedBox(height: UtenSpacing.s16),
              _section(context, theme, '委外报表', [
                for (final k in SubcontractReportKind.values)
                  _Entry(
                    icon: k.icon,
                    label: k.label,
                    description: k.shortLabel,
                    location: k.route,
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
            // 8 单据：桌面 4 列 ×2 行；窄屏 2 列。
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
    this.enabled = true,
    this.badge,
  });

  _Entry.fromCfg(SubcontractDocConfig cfg)
    : this(
        icon: cfg.icon,
        label: cfg.label,
        description: cfg.shortLabel,
        location: cfg.skipListOnCreate
            ? SubcontractRoute.newList(cfg.type.pathSegment)
            : SubcontractRoute.list(cfg.type.pathSegment),
        enabled: cfg.enabled,
      );

  final IconData icon;
  final String label;
  final String description;
  final String location;
  final bool enabled;
  final Widget? badge;
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});
  final _Entry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = entry.enabled
        ? theme.colorScheme.primary
        : theme.colorScheme.outline;
    return Material(
      type: MaterialType.transparency,
      borderRadius: UtenRadius.lgAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: entry.enabled
            ? () => goFrom(context, entry.location)
            : () => context.appInfo('该单据类型暂未启用（老库无数据）'),
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
                  if (!entry.enabled) ...[
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: 0.4,
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '未启用',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                entry.label,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: entry.enabled
                      ? null
                      : theme.colorScheme.onSurfaceVariant,
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
