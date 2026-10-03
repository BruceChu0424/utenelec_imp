import '../../../shared/ai/guided/ai_guided_file_plan.dart';
import 'expense_item.dart';

DateTime? guidedInvoiceDate(String? value) {
  if (value == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return null;
  }
  final date = DateTime.tryParse(value);
  return date != null &&
          '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}' ==
              value
      ? date
      : null;
}

ExpenseItem? guidedExpenseItem(AiGuidedFilePlan plan, String id) {
  final result = plan.result;
  if (!result.isHighConfidence('totalAmount') ||
      !result.isHighConfidence('issueDate')) {
    return null;
  }
  final raw = result.fields['totalAmount'] ?? '';
  if (!RegExp(r'^\d{1,12}(?:\.\d{1,2})?$').hasMatch(raw)) return null;
  final amount = double.tryParse(raw);
  final date = guidedInvoiceDate(result.fields['issueDate']);
  if (amount == null || !amount.isFinite || amount <= 0 || date == null) {
    return null;
  }
  final summary = result.isHighConfidence('itemSummary')
      ? result.fields['itemSummary']
      : null;
  return ExpenseItem(
    id: id,
    category: ExpenseCategory.other,
    amount: amount,
    date: date,
    description: summary?.substring(
      0,
      summary.length > 500 ? 500 : summary.length,
    ),
  );
}
