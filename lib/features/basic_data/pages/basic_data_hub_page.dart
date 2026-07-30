// 基础资料入口页（hub）—— 货品资料 / 模具资料 等同级入口。
//
// 工作台「基础资料」卡片进入本页；再点具体资料类型进入各自的分类树+主档页。
// 全员可见（登录即可，不设路由守卫）；卡片风格对齐工作台 _ModuleTile。
// 新增资料类型（如颜色资料）时在 _resources 加一条即可。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/permission_by_path.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';

class BasicDataHubPage extends ConsumerWidget {
  const BasicDataHubPage({super.key});

  static const List<_BasicResource> _resources = [
    _BasicResource(
      icon: Icons.inventory_2_outlined,
      label: '货品资料',
      description: '物料分类树与货品主档',
      location: RouteName.basicinfoGoods,
      color: _C.green,
    ),
    _BasicResource(
      icon: Icons.precision_manufacturing_outlined,
      label: '模具资料',
      description: '模具系列分类与模具主档',
      location: RouteName.basicinfoMould,
      color: _C.teal,
    ),
    _BasicResource(
      icon: Icons.people_outline,
      label: '客户资料',
      description: '客户分类与客户主档',
      location: RouteName.basicinfoClient,
      color: _C.green,
    ),
    _BasicResource(
      icon: Icons.local_shipping_outlined,
      label: '供应商资料',
      description: '供应商分类与供应商主档',
      location: RouteName.basicinfoSupplier,
      color: _C.teal,
    ),
    _BasicResource(
      icon: Icons.palette_outlined,
      label: '颜色资料',
      description: '颜色主档（编号/名称/状态）',
      location: RouteName.basicinfoColor,
      color: _C.green,
    ),
    _BasicResource(
      icon: Icons.straighten_outlined,
      label: '基本单位',
      description: '计量单位主档（编号/名称/状态）',
      location: RouteName.basicinfoUnit,
      color: _C.teal,
    ),
    _BasicResource(
      icon: Icons.attach_money_rounded,
      label: '币种资料',
      description: '币种主档（编号/名称/参考汇率/状态）',
      location: RouteName.basicinfoCurrency,
      color: _C.green,
    ),
    _BasicResource(
      icon: Icons.warehouse_outlined,
      label: '仓库资料',
      description: '仓库主档（编号/名称/位置/核算）',
      location: RouteName.basicinfoWarehouse,
      color: _C.teal,
    ),
    _BasicResource(
      icon: Icons.account_balance_outlined,
      label: '账户资料',
      description: '账户主档（编号/类型/币种/期初/余额）',
      location: RouteName.basicinfoAccount,
      color: _C.green,
    ),
    _BasicResource(
      icon: Icons.category_outlined,
      label: '收付款类别',
      description: '6 大类（资产负债权益费用收入方法）',
      location: RouteName.basicinfoPaymentStyle,
      color: _C.teal,
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(currentPermissionsProvider);
    final resources = _resources
        .where((resource) {
          final required = requiredAnyPermFor(resource.location);
          return required == null || required.any(permissions.contains);
        })
        .toList(growable: false);
    return Scaffold(
      appBar: const UtenAppBar(
        title: '基础资料', // TODO(l10n): 补 arb
        showBackButton: true,
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: UtenResponsiveGrid(
              itemCount: resources.length,
              spacing: UtenSpacing.s12,
              columns: const UtenResponsiveColumns(compact: 2, medium: 3),
              itemBuilder: (context, i, _) => _ResourceTile(item: resources[i]),
            ),
          ),
        ),
      ),
    );
  }
}

class _ResourceTile extends StatelessWidget {
  const _ResourceTile({required this.item});
  final _BasicResource item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      borderRadius: UtenRadius.lgAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => goFrom(context, item.location),
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
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: item.color.withValues(alpha: 0.1),
                  borderRadius: UtenRadius.mdAll,
                ),
                child: Icon(item.icon, color: item.color, size: 22),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                item.label,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                item.description,
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

class _BasicResource {
  const _BasicResource({
    required this.icon,
    required this.label,
    required this.description,
    required this.location,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String description;
  final String location;
  final Color color;
}

/// 品牌色取值（与 UtenColors 对齐，hub 卡片直接用 Material 色，避免引入更多依赖）。
class _C {
  static const Color green = UtenColors.teal700;
  static const Color teal = UtenColors.teal500;
}
