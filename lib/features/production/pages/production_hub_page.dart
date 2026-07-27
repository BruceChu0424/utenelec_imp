// 生产管理入口页（hub）—— 两个分组卡片（与 basic_data / purchase / warehouse hub 对齐）：
//  ① 生产管理（操作类 · 单据）：生产计划单 + BOM 成本展开（只读）+ 生产日报表
//  ② 生产报表（分析类）：计划明细 / 计划汇总 / 日报明细 / 日报汇总（4 参数化入口）
//
// 点卡片进对应列表/查询/报表页。卡片网格布局对齐采购 hub（UtenResponsiveGrid）。
//
// 路径目前写死（与 app_router 待注册的 /production/* 对齐；用户后续把路径常量搬到
// route_names.dart 的 RouteName.production* 段，与本页 _Entry.location 同步即可）。
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';

class ProductionHubPage extends StatelessWidget {
  const ProductionHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: '生产管理',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: ListView(
            padding: const EdgeInsets.only(top: UtenSpacing.s12),
            children: [
              _section(context, theme, '生产管理', const [
                _Entry(
                  icon: Icons.assignment_outlined,
                  label: '生产计划单',
                  description: '计划单 · 明细 · 审核',
                  location: '/production/plans',
                ),
                _Entry(
                  icon: Icons.account_tree_outlined,
                  label: 'BOM 成本展开',
                  description: '只读历史数据',
                  location: '/production/plan-cost',
                ),
                _Entry(
                  icon: Icons.edit_calendar_outlined,
                  label: '生产日报表',
                  description: '完工日报 · 留位',
                  location: '/production/daily-reports',
                ),
              ]),
              const SizedBox(height: UtenSpacing.s16),
              _section(context, theme, '生产报表', const [
                _Entry(
                  icon: Icons.list_alt_outlined,
                  label: '计划明细',
                  description: '日期 / 货品 / 状态',
                  location: '/production/reports/plan-detail',
                ),
                _Entry(
                  icon: Icons.bar_chart_outlined,
                  label: '计划汇总',
                  description: '单号 / 制单员 / 审核员',
                  location: '/production/reports/plan-summary',
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

class _Entry {
  const _Entry({
    required this.icon,
    required this.label,
    required this.description,
    required this.location,
  });

  final IconData icon;
  final String label;
  final String description;
  final String location;
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
