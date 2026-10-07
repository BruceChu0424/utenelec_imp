// AI 用量趋势柱卡(ADR-164): 用量看板页与人员详情页共用。
//
// 口径照审计中心 _AuditTrendCard: FractionallySizedBox 定高柱、柱顶数值常显、
// 桶底短标签(服务端给), 峰值柱 primary、其余 primaryContainer; 窗口内没有数据时
// 显示空态文案; 每根柱带 Semantics 全值(点按/悬停 Tooltip 也可看全值)。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../components/cards/uten_card.dart';
import '../../../core/formatters/china_number_format.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/ai_usage_dashboard_models.dart';

/// 窗口的分段/标题文案(看板页与人员详情页共用同一组)。
String aiUsageWindowLabel(AppLocalizations l10n, AiUsageWindow window) =>
    switch (window) {
      AiUsageWindow.hour => l10n.aiUsageWindowHour,
      AiUsageWindow.day => l10n.aiUsageWindowDaily,
      AiUsageWindow.month => l10n.aiUsageWindowMonthly,
      AiUsageWindow.year => l10n.aiUsageWindowYearly,
    };

/// 数字就地表千分位(tokens/次数都很大, 不带小数)。
String formatAiUsageNumber(int value) =>
    formatChinaNumber(value, decimalDigits: 0);

class AiUsageTrendCard extends StatelessWidget {
  const AiUsageTrendCard({
    super.key,
    required this.points,
    required this.title,
  });

  final List<AiUsageSeriesPoint> points;

  /// 卡头标题(含窗口文案, 由调用方拼好)。
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    if (points.isEmpty) {
      return UtenCard(
        key: const ValueKey('ai-usage-trend-empty'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(theme),
            const SizedBox(height: UtenSpacing.s16),
            Text(
              l10n.aiUsageEmpty,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    final peak = points.fold<int>(
      0,
      (value, point) => math.max(value, point.tokens),
    );
    final totalTokens = points.fold<int>(
      0,
      (value, point) => value + point.tokens,
    );
    final totalCalls = points.fold<int>(
      0,
      (value, point) => value + point.calls,
    );
    return Semantics(
      label: l10n.aiUsageTrendSemantics(
        title,
        formatAiUsageNumber(totalTokens),
        formatAiUsageNumber(totalCalls),
      ),
      child: UtenCard(
        key: const ValueKey('ai-usage-trend'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(theme),
            const SizedBox(height: UtenSpacing.s16),
            SizedBox(
              height: 126,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final point in points)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: _TrendBar(
                          point: point,
                          peak: peak,
                          fullValue:
                              '${point.label}：${formatAiUsageNumber(point.tokens)} '
                              'tokens、${l10n.aiUsageColCalls(point.calls)}',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) => Row(
    children: [
      Icon(Icons.bar_chart_rounded, color: theme.colorScheme.primary),
      const SizedBox(width: UtenSpacing.s8),
      Expanded(
        child: Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ],
  );
}

class _TrendBar extends StatelessWidget {
  const _TrendBar({
    required this.point,
    required this.peak,
    required this.fullValue,
  });

  final AiUsageSeriesPoint point;
  final int peak;
  final String fullValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: fullValue,
      excludeSemantics: true,
      child: Tooltip(
        message: fullValue,
        child: InkWell(
          onTap: () {},
          borderRadius: UtenRadius.smAll,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                formatAiUsageNumber(point.tokens),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    // 全零序列 peak=0 会被 0/0 除成 NaN: 走最小高, 不算比例。
                    heightFactor: peak > 0
                        ? math.max(point.tokens / peak, 0.04)
                        : 0.04,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: point.tokens == peak && peak > 0
                            ? theme.colorScheme.primary
                            : theme.colorScheme.primaryContainer,
                        borderRadius: UtenRadius.smAll,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                point.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
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
