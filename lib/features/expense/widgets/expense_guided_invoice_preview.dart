import 'package:flutter/material.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/ai/chat/ai_chat_l10n.dart';
import '../../../shared/ai/guided/ai_guided_file_plan.dart';

/// Original extracted values remain visible independently of editable expense
/// rows. Missing values and guesses are never substituted with zero or today.
class ExpenseGuidedInvoicePreview extends StatelessWidget {
  const ExpenseGuidedInvoicePreview({super.key, required this.plan});
  final AiGuidedFilePlan plan;
  @override
  Widget build(BuildContext context) => Card(
    key: const ValueKey('expense-guided-invoice-preview'),
    child: Padding(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            aiChatText(context, 'guidedInvoiceFields'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(plan.file.name),
          const SizedBox(height: UtenSpacing.s12),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 900
                  ? 3
                  : constraints.maxWidth >= 620
                  ? 2
                  : 1;
              final width =
                  (constraints.maxWidth - (columns - 1) * UtenSpacing.s24) /
                  columns;
              return Wrap(
                spacing: UtenSpacing.s24,
                runSpacing: UtenSpacing.s12,
                children: [
                  for (final entry in plan.result.fields.entries)
                    if (entry.value.trim().isNotEmpty)
                      SizedBox(
                        width: width,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              aiChatText(context, 'invoice_${entry.key}'),
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            SelectableText(
                              entry.key == 'invoiceType'
                                  ? aiChatText(
                                      context,
                                      'invoiceType_${const {'GENERAL', 'SPECIAL', 'DIGITAL', 'PAPER_GENERAL', 'PAPER_SPECIAL', 'OTHER'}.contains(entry.value) ? entry.value : 'OTHER'}',
                                    )
                                  : entry.value,
                            ),
                          ],
                        ),
                      ),
                ],
              );
            },
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text(
            aiChatText(context, 'guidedInvoiceReview'),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    ),
  );
}
