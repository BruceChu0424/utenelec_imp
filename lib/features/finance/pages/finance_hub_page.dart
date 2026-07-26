// 钱流管理入口页（hub）—— 两个分组卡片：
//  ① 钱流管理：销售收款/采购付款/一般费用/其它收入/银行存取款/支票管理 入口
//  ② 钱流报表：应收应付台账/对账单/流水账 入口
// 点卡片进对应列表/报表页。布局对齐采购 hub 的卡片风格（入口用 context.go，避免 push 失效）。
// 支票管理 = 账户 account_type=CHECK/FOREIGN_CHECK 的过滤视图（不单独模块），
// 入口指向 /finance/checks（由用户在 app_router 接到 AccountPage(initialAccountTypeFilter:'CHECK')）。
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';

class FinanceHubPage extends StatelessWidget {
  const FinanceHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: '钱流管理',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: ListView(
            padding: const EdgeInsets.only(top: UtenSpacing.s12),
            children: [
              _section(context, theme, '钱流管理', [
                _Entry(
                  icon: Icons.south_west_outlined,
                  label: '销售收款',
                  description: '核销应收 / 直接收款',
                  location: '/finance/receipts',
                ),
                _Entry(
                  icon: Icons.north_east_outlined,
                  label: '采购付款',
                  description: '核销应付 / 直接付款',
                  location: '/finance/payments',
                ),
                _Entry(
                  icon: Icons.outbound_outlined,
                  label: '一般费用',
                  description: '按部门分摊',
                  location: '/finance/expenses',
                ),
                _Entry(
                  icon: Icons.add_circle_outline,
                  label: '其它收入',
                  description: '按部门分摊',
                  location: '/finance/incomes',
                ),
                _Entry(
                  icon: Icons.swap_horiz_rounded,
                  label: '银行存取款',
                  description: '账户间转入',
                  location: '/finance/bank-transfers',
                ),
                _Entry(
                  icon: Icons.receipt_long_outlined,
                  label: '支票管理',
                  description: '支票账户视图',
                  location: '/finance/checks',
                ),
              ]),
              const SizedBox(height: UtenSpacing.s16),
              _section(context, theme, '钱流报表', [
                _Entry(
                  icon: Icons.account_balance_wallet_outlined,
                  label: '应收应付台账',
                  description: 'AR / AP 余额',
                  location: '/finance/ar-ap',
                ),
                _Entry(
                  icon: Icons.receipt_outlined,
                  label: '钱流报表',
                  description: '应收应付 / 单据 / 费用 / 流水',
                  location: '/finance/report',
                ),
                _Entry(
                  icon: Icons.list_alt_outlined,
                  label: '账户流水',
                  description: '账户进出明细',
                  location: '/finance/reconciliations',
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  /// 一个分组：标题 + 卡片网格。
  Widget _section(BuildContext context, ThemeData theme, String title, List<_Entry> entries) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: UtenSpacing.s4, bottom: UtenSpacing.s8),
            child: Text(title,
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          ),
          UtenResponsiveGrid(
            itemCount: entries.length,
            spacing: UtenSpacing.s12,
            columns: const UtenResponsiveColumns(compact: 2, medium: 3),
            itemBuilder: (context, i, _) => _EntryTile(entry: entries[i]),
          ),
        ],
      ),
    );
  }
}

/// 一个入口项（单据类型或报表）。
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
