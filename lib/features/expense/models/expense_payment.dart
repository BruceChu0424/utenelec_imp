class ExpensePaymentInput {
  const ExpensePaymentInput({
    required this.accountId,
    required this.expenseStyleId,
    required this.paymentDate,
  });

  final String accountId;
  final String expenseStyleId;
  final DateTime paymentDate;

  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'expenseStyleId': expenseStyleId,
    'paymentDate': _dateOnly(paymentDate),
  };
}

class ExpenseAccountOption {
  const ExpenseAccountOption({
    required this.id,
    required this.label,
    this.balanceCurrent,
  });

  final String id;
  final String label;
  final double? balanceCurrent;
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
