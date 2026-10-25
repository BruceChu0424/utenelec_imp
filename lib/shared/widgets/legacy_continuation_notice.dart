import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

/// Historical facts remain visible; this notice does not grant workflow actions.
class LegacyContinuationNotice extends StatelessWidget {
  const LegacyContinuationNotice({super.key, required this.description});

  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Card(
      margin: const EdgeInsets.only(top: UtenSpacing.s12),
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.fact_check_outlined,
                  color: colors.primary,
                  size: UtenSpacing.s20,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    '待接续核对',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              '旧系统状态及累计量已保留。$description',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '请勿用撤销重审代替历史核对；单位未明确时，暂不计算物料需求。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
