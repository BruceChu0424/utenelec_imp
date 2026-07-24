// 产量统计页（Phase 4）
// 文档：docs/03-页面/产量统计页.md
//
// 响应式：compact 由页面自套 UtenContentContainer（gutter 16）；
// medium+ 外壳（MainShellPage）已收敛内容区，页面不再重复套容器

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../components/buttons/click_guard.dart';
import '../models/production.dart';
import '../providers/production_providers.dart';

class ProductionOutputStatsPage extends ConsumerWidget {
  const ProductionOutputStatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(productionOutputListProvider);
    final wide = context.breakpoint.atLeastMedium;

    return Scaffold(
      appBar: UtenAppBar(
        title: '产量统计',
        subtitle: '本周 · 全公司',
        showBackButton: true,
        actions: [
          UtenActionButton(
            type: UtenActionButtonType.ghost,
            size: UtenActionButtonSize.small,
            icon: Icons.download_rounded,
            label: const Text('导出'),
            loadingLabel: const Text('导出中…'),
            onAction: () async {
              await Future<void>.delayed(const Duration(milliseconds: 600));
              if (context.mounted) context.appInfo('导出 Excel（Mock）');
            },
          ),
        ],
      ),
      body: async.when(
        loading: () => const UtenSkeletonList(itemCount: 4),
        error: (e, _) => UtenEmpty.error(message: '加载失败：$e'),
        data: (outputs) {
          if (outputs.isEmpty) return const UtenEmpty(message: '暂无产量数据');

          final totalQ = outputs.fold<int>(0, (s, o) => s + o.qualified);
          final totalUq = outputs.fold<int>(0, (s, o) => s + o.unqualified);
          final rate = totalQ + totalUq == 0
              ? 0.0
              : totalQ / (totalQ + totalUq) * 100;

          // 按产品汇总
          final byProduct = <String, int>{};
          for (final o in outputs) {
            byProduct[o.product] = (byProduct[o.product] ?? 0) + o.qualified;
          }
          final maxProd = byProduct.values.fold<int>(1, (a, b) => a > b ? a : b);

          // compact 自套容器补 gutter；medium+ 外壳已收敛，避免双层 gutter
          Widget content = SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenResponsiveGrid(
                  itemCount: 3,
                  columns: const UtenResponsiveColumns(
                      medium: 3, expanded: 3),
                  itemBuilder: (context, i, _) {
                    const items = [
                      ('总产量', null),
                      ('合格率', null),
                      ('不良数', null),
                    ];
                    return _Kpi(
                      label: items[i].$1,
                      value: switch (i) {
                        0 => '$totalQ',
                        1 => '${rate.toStringAsFixed(1)}%',
                        _ => '$totalUq',
                      },
                      color: i == 2 && totalUq > 0 ? UtenColors.error : null,
                    );
                  },
                ),
                const SizedBox(height: UtenSpacing.s24),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _ProductChart(byProduct: byProduct, max: maxProd)),
                      const SizedBox(width: UtenSpacing.s16),
                      Expanded(child: _DetailList(outputs: outputs)),
                    ],
                  )
                else ...[
                  _ProductChart(byProduct: byProduct, max: maxProd),
                  const SizedBox(height: UtenSpacing.s16),
                  _DetailList(outputs: outputs),
                ],
              ],
            ),
          );
          if (context.breakpoint.isCompact) {
            content = UtenContentContainer(child: content);
          }
          return content;
        },
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Text(value,
              style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

class _ProductChart extends StatelessWidget {
  const _ProductChart({required this.byProduct, required this.max});
  final Map<String, int> byProduct;
  final int max;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const UtenSectionHeader(title: '产品产量'),
          const SizedBox(height: 12),
          for (final e in byProduct.entries) ...[
            Row(
              children: [
                SizedBox(
                    width: 56, child: Text(e.key, style: theme.textTheme.bodySmall)),
                const SizedBox(width: 8),
                Expanded(
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: (e.value / max).clamp(0.02, 1),
                    child: Container(
                      height: 14,
                      decoration: BoxDecoration(
                        color: UtenColors.teal600,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 50,
                  child: Text('${e.value}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()])),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _DetailList extends StatelessWidget {
  const _DetailList({required this.outputs});
  final List<ProductionOutput> outputs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: UtenSectionHeader(title: '明细'),
          ),
          const Divider(),
          for (final o in outputs) ...[
            ListTile(
              dense: true,
              title: Text('${o.line} · ${o.product}'),
              subtitle: Text('${o.date.month}/${o.date.day} · ${o.operatorName}',
                  style: theme.textTheme.bodySmall),
              trailing: Text('合格 ${o.qualified} · 不良 ${o.unqualified}',
                  style: theme.textTheme.bodySmall),
            ),
            if (o != outputs.last)
              Divider(height: 1, color: theme.colorScheme.outlineVariant),
          ],
        ],
      ),
    );
  }
}
