import '../../../shared/models/accounting_expense_purpose.dart';

class ExpensePaymentInput {
  const ExpensePaymentInput({
    required this.accountId,
    required this.expenseStyleId,
    required this.paymentDate,
    this.postingPurpose = AccountingExpensePurpose.ordinaryExpense,
  });

  final String accountId;
  final String expenseStyleId;
  final DateTime paymentDate;
  final AccountingExpensePurpose postingPurpose;

  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'expenseStyleId': expenseStyleId,
    'paymentDate': _dateOnly(paymentDate),
    'postingPurpose': postingPurpose.apiValue,
  };
}

class ExpenseAccountOption {
  const ExpenseAccountOption({
    required this.id,
    required this.label,
    this.balanceCurrent,
    this.balanceCurrentText,
    this.currencyName,
    this.currencyCode,
  });

  final String id;
  final String label;
  final double? balanceCurrent;
  final String? balanceCurrentText, currencyName, currencyCode;
}

class ExpenseStyleOption {
  const ExpenseStyleOption({required this.id, required this.label});

  final String id;
  final String label;
}

class ExpensePaymentOptions {
  const ExpensePaymentOptions({required this.accounts, required this.styles});

  final List<ExpenseAccountOption> accounts;
  final List<ExpenseStyleOption> styles;
}

String _dateOnly(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
