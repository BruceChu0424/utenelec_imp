// 采购管理入口页（hub）—— 4 单据类型 tile（申请/订货/收货/退货）。
//
// 工作台「采购管理」卡片进入本页，再点具体单据进入列表。全员可见。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/theme/uten_tokens.dart';
import '../config/purchase_doc_config.dart';

class PurchaseHubPage extends StatelessWidget {
  const PurchaseHubPage({super.key});

  static const _items = [
    PurchaseDocConfig.request,
    PurchaseDocConfig.order,
    PurchaseDocConfig.receipt,
    PurchaseDocConfig.returnDoc,
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const UtenAppBar(title: '采购管理', leading: UtenBackButton()),
      body: SafeArea(
        child: UtenContentContainer(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: UtenResponsiveGrid(
              itemCount: _items.length,
              spacing: UtenSpacing.s12,
              columns: const UtenResponsiveColumns(compact: 2, medium: 4),
              itemBuilder: (context, i, _) => _Tile(cfg: _items[i]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.cfg});
  final PurchaseDocConfig cfg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Material(
      type: MaterialType.transparency,
      borderRadius: UtenRadius.lgAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.go('/purchase/${cfg.type.pathSegment}'),
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
                child: Icon(cfg.icon, color: color, size: 22),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(cfg.label,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}
