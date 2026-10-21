import 'package:flutter/material.dart';

import '../../../components/feedback/uten_dialog.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/production_sales_requirement.dart';

/// Keeps order-wide and product-specific instructions visibly distinct, including mixed sources.
class ProductionSalesRequirements extends StatelessWidget {
  const ProductionSalesRequirements({super.key, required this.requirements});

  final List<ProductionSalesRequirement> requirements;

  @override
  Widget build(BuildContext context) {
    final bySource = {
      for (final row in requirements)
        if (row.hasContent) row.salesOrderItemId: row,
    };
    final rows = bySource.values.toList();
    if (rows.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Container(
      key: const ValueKey('production-sales-requirements'),
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: .35),
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.productionSalesRequirements,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          for (var index = 0; index < rows.length; index++) ...[
            if (index > 0) const Divider(height: UtenSpacing.s24),
            const SizedBox(height: UtenSpacing.s8),
            SelectableText(
              [rows[index].salesOrderNo, rows[index].productName]
                  .whereType<String>()
                  .where((text) => text.trim().isNotEmpty)
                  .join(' · '),
              style: theme.textTheme.labelLarge,
            ),
            if (rows[index].orderRemark?.trim().isNotEmpty == true) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                l10n.productionOrderRequirement,
                style: theme.textTheme.labelMedium,
              ),
              SelectableText(
                rows[index].orderRemark!,
                style: theme.textTheme.bodyMedium,
              ),
            ],
            if (rows[index].itemRemark?.trim().isNotEmpty == true) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                l10n.productionProductRequirement,
                style: theme.textTheme.labelMedium,
              ),
              SelectableText(
                rows[index].itemRemark!,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class ProductionSalesRequirementsButton extends StatelessWidget {
  const ProductionSalesRequirementsButton({
    super.key,
    required this.requirements,
  });
  final List<ProductionSalesRequirement> requirements;

  @override
  Widget build(BuildContext context) {
    if (!requirements.any((row) => row.hasContent)) return const Text('—');
    final l10n = AppLocalizations.of(context);
    return TextButton.icon(
      icon: const Icon(Icons.assignment_outlined),
      label: Text(l10n.productionSalesRequirements),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (context) => UtenAlertDialog(
          maxWidth: 720,
          title: Text(l10n.productionSalesRequirements),
          content: ProductionSalesRequirements(requirements: requirements),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.productionRequirementsClose),
            ),
          ],
        ),
      ),
    );
  }
}
