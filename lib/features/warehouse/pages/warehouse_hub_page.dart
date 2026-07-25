// 仓库管理入口页（hub）—— 8 单据类型 tile（调拨/其它出入库/领退料/产成品进出仓/盘点）。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/stock_doc.dart';

class WarehouseHubPage extends StatelessWidget {
  const WarehouseHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Scaffold(
      appBar: const UtenAppBar(title: '仓库管理', leading: UtenBackButton()),
      body: SafeArea(
        child: UtenContentContainer(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: UtenResponsiveGrid(
              itemCount: StockDocType.values.length,
              spacing: UtenSpacing.s12,
              columns: const UtenResponsiveColumns(compact: 2, medium: 4),
              itemBuilder: (context, i, _) {
                final t = StockDocType.values[i];
                return Material(
                  type: MaterialType.transparency,
                  borderRadius: UtenRadius.lgAll,
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => context.go(RoutePath.stockDocList(t.code)),
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
                            child: Icon(iconFor(t), color: color, size: 22),
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                          Text(t.label,
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
