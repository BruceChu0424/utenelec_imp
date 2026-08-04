// 销售管理入口页（hub）—— 两个分组卡片：
//  ① 销售管理：5 单据卡片（报价/订货/出货/其它出货/退货）
//  ② 销售报表：报表卡片（明细/汇总/待交货）
// 点卡片进对应列表/报表页。卡片按权限显隐（无 view 权限不渲染对应入口）；
// 销售管理卡 / 销售报表卡 若整组无可显项则整卡隐藏。
//
// 卡片统一用 UtenHubCard（徽章恒在右上角；销售入口暂无角标）。
// 权限来自 currentPermissionsProvider；路由用 SalesRoutePath 字面量。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_hub_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../config/sales_doc_config.dart';
import '../widgets/sales_progress_badge.dart';

class SalesHubPage extends ConsumerWidget {
  const SalesHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final perms = ref.watch(currentPermissionsProvider);

    final docEntries = <_Entry>[
      _Entry(
        icon: Icons.timeline_outlined,
        label: '订单进度查询',
        description: '生产进度 · 分批发货 · 完工提醒',
        location: RouteName.salesOrderProgress,
        listPerm: Perm.salesOrderView,
        badge: const SalesProgressBadge(),
      ),
      _Entry.fromCfg(SalesDocConfig.quote),
      _Entry.fromCfg(SalesDocConfig.order),
      _Entry.fromCfg(SalesDocConfig.shipment),
      _Entry.fromCfg(SalesDocConfig.otherShipment),
      _Entry.fromCfg(SalesDocConfig.returnDoc),
    ].where((e) => perms.contains(e.listPerm)).toList();

    final reportEntries = <_Entry>[
      _Entry(
        icon: Icons.list_alt_outlined,
        label: '销售明细报表',
        description: '订货 / 出货 / 退货 / 其它出货',
        location: SalesRoutePath.reportDetail,
        listPerm: SalesPerm.reportView,
      ),
      _Entry(
        icon: Icons.bar_chart_outlined,
        label: '销售汇总报表',
        description: '订货 / 出货 / 退货 / 其它出货',
        location: SalesRoutePath.reportSummary,
        listPerm: SalesPerm.reportView,
      ),
    ].where((e) => perms.contains(e.listPerm)).toList();

    // V178 稀缺仲裁：主管查看货品预留占用、释放低优先级现货预留（让单）。仅持让单权限者可见。
    final scarcityEntries = <_Entry>[
      _Entry(
        icon: Icons.swap_horizontal_circle_outlined,
        label: '稀缺库存让单',
        description: '查看货品预留 · 释放低优先级占用',
        location: RouteName.salesScarcity,
        listPerm: Perm.salesOrderReallocate,
      ),
    ].where((e) => perms.contains(e.listPerm)).toList();

    return Scaffold(
      appBar: UtenAppBar(
        title: '销售管理',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: ListView(
            padding: EdgeInsets.only(
              top: UtenSpacing.s12,
              // 外壳 compact 已预留胶囊高度；medium+/桌面 Rail 不预留，取更大值。
              bottom: context.breakpoint.isCompact
                  ? UtenSpacing.s16
                  : UtenSpacing.s40,
            ),
            children: [
              if (docEntries.isNotEmpty)
                _section(context, theme, '销售管理', docEntries),
              if (docEntries.isNotEmpty && reportEntries.isNotEmpty)
                const SizedBox(height: UtenSpacing.s16),
              if (reportEntries.isNotEmpty)
                _section(context, theme, '销售报表', reportEntries),
              if (reportEntries.isNotEmpty && scarcityEntries.isNotEmpty)
                const SizedBox(height: UtenSpacing.s16),
              if (scarcityEntries.isNotEmpty)
                _section(context, theme, '稀缺仲裁', scarcityEntries),
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
    required this.listPerm,
    this.badge,
  });

  _Entry.fromCfg(SalesDocConfig cfg)
    : icon = cfg.icon,
      label = cfg.label,
      description = cfg.shortLabel,
      location = cfg.skipListOnCreate
          ? SalesRoutePath.docNew(cfg.type.pathSegment)
          : SalesRoutePath.list(cfg.type.pathSegment),
      listPerm = cfg.listPerm,
      badge = null;

  final IconData icon;
  final String label;
  final String description;
  final String location;
  final String listPerm;

  /// 右上角徽章（如订单进度完工提醒；null=无）。
  final Widget? badge;
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});
  final _Entry entry;

  @override
  Widget build(BuildContext context) {
    return UtenHubCard(
      icon: entry.icon,
      label: entry.label,
      description: entry.description,
      onTap: () => goFrom(context, entry.location),
      badge: entry.badge,
    );
  }
}
