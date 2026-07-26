// 销售管理入口页（hub）—— 两个分组卡片：
//  ① 销售管理：5 单据卡片（报价/订货/出货/其它出货/退货）
//  ② 销售报表：报表卡片（明细/汇总/待交货）
// 点卡片进对应列表/报表页。卡片按权限显隐（无 view 权限不渲染对应入口）；
// 销售管理卡 / 销售报表卡 若整组无可显项则整卡隐藏。
//
// 布局对齐基础资料 hub 与采购 hub 的卡片风格；权限来自 currentPermissionsProvider。
// 路由用 SalesRoutePath 字面量（route_names.dart 由上层统一加 sales_*）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../config/sales_doc_config.dart';

class SalesHubPage extends ConsumerWidget {
  const SalesHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final perms = ref.watch(currentPermissionsProvider);

    final docEntries = <_Entry>[
      _Entry.fromCfg(SalesDocConfig.quote),
      _Entry.fromCfg(SalesDocConfig.order),
      _Entry.fromCfg(SalesDocConfig.shipment),
      _Entry.fromCfg(SalesDocConfig.otherShipment),
      _Entry.fromCfg(SalesDocConfig.returnDoc),
    ].where((e) => perms.contains(e.listPerm)).toList();

    final reportEntries = <_Entry>[
      _Entry(
        icon: Icons.bar_chart_outlined,
        label: '销售报表',
        description: '明细 / 汇总 / 待交货',
        location: SalesRoutePath.report,
        listPerm: SalesPerm.reportView,
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
            padding: const EdgeInsets.only(top: UtenSpacing.s12),
            children: [
              if (docEntries.isNotEmpty)
                _section(context, theme, '销售管理', docEntries),
              if (docEntries.isNotEmpty && reportEntries.isNotEmpty)
                const SizedBox(height: UtenSpacing.s16),
              if (reportEntries.isNotEmpty)
                _section(context, theme, '销售报表', reportEntries),
            ],
          ),
        ),
      ),
    );
  }

  /// 一个分组：标题 + 卡片网格。
  Widget _section(
      BuildContext context, ThemeData theme, String title, List<_Entry> entries) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding:
                const EdgeInsets.only(left: UtenSpacing.s4, bottom: UtenSpacing.s8),
            child: Text(title,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
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
  });

  _Entry.fromCfg(SalesDocConfig cfg)
      : icon = cfg.icon,
        label = cfg.label,
        description = cfg.shortLabel,
        location = SalesRoutePath.list(cfg.type.pathSegment),
        listPerm = cfg.listPerm;

  final IconData icon;
  final String label;
  final String description;
  final String location;
  final String listPerm;
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
              vertical: UtenSpacing.s20, horizontal: UtenSpacing.s16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: UtenRadius.lgAll,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
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
              const SizedBox(height: UtenSpacing.s12),
              Text(entry.label,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(entry.description,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}
