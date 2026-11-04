import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../components/buttons/uten_button.dart';
import '../../finance/config/finance_requirement_names.dart';
import '../models/expense_claim.dart';

/// Native source and workflow share one explicit link and current-node action surface.
class ExpenseFinancialApplicationLinkButton extends StatelessWidget {
  const ExpenseFinancialApplicationLinkButton({super.key, required this.claim});
  final ExpenseClaim claim;
  @override
  Widget build(BuildContext context) {
    final link = claim.financialApplication;
    if (link == null || !link.canOpen || link.id.isEmpty) {
      return const SizedBox.shrink();
    }
    return UtenButton(
      type: UtenButtonType.secondary,
      onPressed: () => context.push('/finance/applications/${link.id}'),
      child: const Text(FinanceRequirementNames.financeApplications),
    );
  }
}
