// 基础资料入口页（hub）—— 货品资料 / 模具资料 等同级入口。
//
// 工作台「基础资料」卡片进入本页；再点具体资料类型进入各自的分类树+主档页。
// 全员可见（登录即可，不设路由守卫）；卡片统一用 UtenHubCard（与各模块 hub 一致），
// labelStyle 用 titleMedium 保留原较大标题观感，color 按条目绿/青区分。
// 新增资料类型（如颜色资料）时在 _resources 加一条即可。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_hub_card.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/permission_by_path.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';

class BasicDataHubPage extends ConsumerWidget {
  const BasicDataHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final resources =
        <_BasicResource>[
              _BasicResource(
                icon: Icons.inventory_2_outlined,
                label: l10n.basicDataHubGoods,
                description: l10n.basicDataHubGoodsSub,
                location: RouteName.basicinfoGoods,
                color: _C.green,
              ),
              _BasicResource(
                icon: Icons.precision_manufacturing_outlined,
                label: l10n.basicDataHubMould,
                description: l10n.basicDataHubMouldSub,
                location: RouteName.basicinfoMould,
                color: _C.teal,
              ),
              _BasicResource(
                icon: Icons.people_outline,
                label: l10n.basicDataHubClient,
                description: l10n.basicDataHubClientSub,
                location: RouteName.basicinfoClient,
                color: _C.green,
              ),
              _BasicResource(
                icon: Icons.local_shipping_outlined,
                label: l10n.basicDataHubSupplier,
                description: l10n.basicDataHubSupplierSub,
                location: RouteName.basicinfoSupplier,
                color: _C.teal,
              ),
              _BasicResource(
                icon: Icons.palette_outlined,
                label: l10n.basicDataHubColor,
                description: l10n.basicDataHubColorSub,
                location: RouteName.basicinfoColor,
                color: _C.green,
              ),
              _BasicResource(
                icon: Icons.straighten_outlined,
                label: l10n.basicDataHubUnit,
                description: l10n.basicDataHubUnitSub,
                location: RouteName.basicinfoUnit,
                color: _C.teal,
              ),
              _BasicResource(
                icon: Icons.attach_money_rounded,
                label: l10n.basicDataHubCurrency,
                description: l10n.basicDataHubCurrencySub,
                location: RouteName.basicinfoCurrency,
                color: _C.green,
              ),
              _BasicResource(
                icon: Icons.warehouse_outlined,
                label: l10n.basicDataHubWarehouse,
                description: l10n.basicDataHubWarehouseSub,
                location: RouteName.basicinfoWarehouse,
                color: _C.teal,
              ),
              _BasicResource(
                icon: Icons.account_balance_outlined,
                label: l10n.basicDataHubAccount,
                description: l10n.basicDataHubAccountSub,
                location: RouteName.basicinfoAccount,
                color: _C.green,
              ),
              _BasicResource(
                icon: Icons.category_outlined,
                label: l10n.basicDataHubPaymentStyle,
                description: l10n.basicDataHubPaymentStyleSub,
                location: RouteName.basicinfoPaymentStyle,
                color: _C.teal,
              ),
            ]
            .where((resource) {
              final required = requiredAnyPermFor(resource.location);
              return required == null || required.any(permissions.contains);
            })
            .toList(growable: false);
    return Scaffold(
      appBar: UtenAppBar(title: l10n.basicDataHubTitle, showBackButton: true),
      body: SafeArea(
        child: UtenContentContainer(
          child: ListView(
            padding: EdgeInsets.only(
              top: UtenSpacing.s8,
              bottom: context.breakpoint.isCompact
                  ? UtenSpacing.s16
                  : UtenSpacing.s40,
            ),
            children: [
              UtenResponsiveGrid(
                itemCount: resources.length,
                spacing: UtenSpacing.s12,
                columns: const UtenResponsiveColumns(compact: 2, medium: 3),
                itemBuilder: (context, i, _) => UtenHubCard(
                  icon: resources[i].icon,
                  label: resources[i].label,
                  description: resources[i].description,
                  color: resources[i].color,
                  labelStyle: theme.textTheme.titleMedium,
                  onTap: () => goFrom(context, resources[i].location),
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
