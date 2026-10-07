// 近 N 天 AI 用量卡片: 每个服务一行(调用次数 / 成功率 / 输入·输出 token / 平均耗时)。
import 'package:flutter/material.dart';

import '../../../components/cards/uten_card.dart';
import '../../../core/formatters/china_number_format.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/ai_provider_models.dart';

class AiUsageCard extends StatelessWidget {
  const AiUsageCard({
    super.key,
    required this.usage,
    required this.providers,
    required this.unavailable,
    this.onOpenUsage,
  });

  /// 读取中或失败时为 null。
  final AiUsageSummary? usage;
  final List<AiProviderConfig> providers;

  /// 用量接口读取失败(不影响配置本身)。
  final bool unavailable;

  /// 卡头右上「用量与额度」入口(跳 AI 用量看板, ADR-164); null 时不显示。
  final VoidCallback? onOpenUsage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final usage = this.usage;
    final rows = usage == null
        ? const <AiProviderUsage>[]
        : usage.providers.where((row) => row.calls > 0).toList();
    return UtenCard(
      key: const ValueKey('ai-usage-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.insights_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  l10n.aiSettingsUsageTitle(usage?.days ?? 30),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (onOpenUsage != null)
                TextButton(
                  key: const ValueKey('ai-usage-card-open'),
                  onPressed: onOpenUsage,
                  style: TextButton.styleFrom(
                    // 触达目标不小于 44。
                    minimumSize: const Size(44, 44),
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s8,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(l10n.aiUsageEntry),
                ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          if (unavailable)
            _Muted(l10n.aiSettingsUsageUnavailable)
          else if (usage == null)
            const LinearProgressIndicator(minHeight: 2)
          else if (rows.isEmpty)
            _Muted(l10n.aiSettingsUsageEmpty)
          else
            for (final row in rows) ...[
              _UsageRow(row: row, name: _nameOf(row)),
              if (row != rows.last)
                Divider(height: 20, color: theme.colorScheme.outlineVariant),
            ],
        ],
      ),
    );
  }

  /// 服务已被删除时用统计里记下的名称。
  String _nameOf(AiProviderUsage row) {
    for (final provider in providers) {
      if (provider.id == row.providerId) return provider.name;
    }
    return row.providerName.isEmpty ? '-' : row.providerName;
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({required this.row, required this.name});

  final AiProviderUsage row;
  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final rate = row.successRate;
    final metrics = <(String, String)>[
      (l10n.aiSettingsUsageCalls, _grouped(row.calls)),
      (
        l10n.aiSettingsUsageSuccessRate,
        rate == null
            ? '-'
            : '${(rate * 100).toStringAsFixed(rate == 1 ? 0 : 1)}%',
      ),
      (
        l10n.aiSettingsUsageTokens,
        '${_grouped(row.inputTokens)} / ${_grouped(row.outputTokens)}',
      ),
      (
        l10n.aiSettingsUsageLatency,
        row.avgLatencyMs == null
            ? '-'
            : l10n.aiSettingsUsageSeconds(
                (row.avgLatencyMs! / 1000).toStringAsFixed(1),
              ),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 560 ? 4 : 2;
            final width =
                (constraints.maxWidth - UtenSpacing.s12 * (columns - 1)) /
                columns;
            return Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s8,
              children: [
                for (final (label, value) in metrics)
                  SizedBox(
                    width: width,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s2),
                        Text(
                          value,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  static String _grouped(int value) =>
      formatChinaNumber(value, decimalDigits: 0);
}

class _Muted extends StatelessWidget {
  const _Muted(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
